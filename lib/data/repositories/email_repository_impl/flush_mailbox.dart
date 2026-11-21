part of '../email_repository_impl.dart';

// Mailbox flush (SYNC-REDESIGN.md §7, phase 5a): sending the queued folder
// creates and renames to the server, before the account's email changes,
// and holding back the email changes that need a folder not created yet.

/// What the server confirmed for a mailbox op: the folder is at [path]
/// under [name]; [read]: found in a read of the server (a create of a
/// folder that exists), not by our command's answer.
typedef _MailboxDone = ({String path, String name, bool read});

/// The refusal for an IMAP folder command that failed with [error], when
/// sending it again cannot help: a `NO` with a permanent code
/// ([isImapPermanentRefusal]) or a tagged `BAD` about the command
/// ([isImapPermanentBad]). [what] starts its message. Null when the error
/// may pass.
MailboxOpRefused? _imapFolderRefusal(Object error, String what) {
  if (isImapPermanentBad(error)) {
    return MailboxOpRefused('$what: $error', badAnswer: error);
  }
  if (isImapPermanentRefusal(error)) return MailboxOpRefused('$what: $error');
  return null;
}

extension _FlushMailbox on EmailRepositoryImpl {
  /// Sends [accountId]'s queued mailbox ops (pending, and stuck ones that
  /// are due) in queue order, before its email changes: a move into a
  /// folder created offline needs the folder first. Same claim, lease and
  /// outcomes as an email change (SYNC-REDESIGN.md §5): not sent (no
  /// connection: nothing charged), satisfied or applied (acked, with what
  /// the server confirmed: [MailboxStateWriter.ack]), refused (failed, with
  /// the changes that need the folder: [MailboxStateWriter.fail]),
  /// transient (retried, stuck after [_maxChangeAttempts]) and ambiguous
  /// (connection lost after sending: kept, and the next try looks first).
  /// An op whose folder or parent folder is not created yet waits. Returns
  /// how many were applied.
  ///
  /// With [onlyDeletes] (the pass after the mail changes) only deletes are
  /// sent: one that waited for the mail changes queued before it.
  Future<int> _flushMailboxOps(
    account_model.Account account,
    String password, {
    bool onlyDeletes = false,
  }) async {
    final now = _now();
    final rows = await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.accountId.equals(account.id) &
                t.resourceType.equals(mailboxResourceType) &
                (onlyDeletes
                    ? t.changeType.equals(deleteMailboxOp)
                    : const Constant(true)) &
                (t.state.equals(_pendingState) |
                    (t.state.equals(_stuckState) &
                        t.leaseUntil.isSmallerOrEqualValue(now))),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();
    if (rows.isEmpty) return 0;
    final jmapAccount = account.type == account_model.AccountType.jmap;
    imap.ImapClient? client;
    JmapClient? jmap;
    try {
      if (jmapAccount) {
        final jmapUrl = account.jmapUrl;
        if (jmapUrl == null || jmapUrl.isEmpty) return 0;
        jmap = await JmapClient.connect(
          httpClient: _httpClient,
          jmapUrl: Uri.parse(jmapUrl),
          username: _effectiveUsername(account),
          password: password,
        );
      } else {
        client = await _imapConnect(
          account,
          _effectiveUsername(account),
          password,
        );
      }
    } catch (e) {
      // Not sent: nothing is charged, the next cycle retries.
      log('Mailbox flush for ${account.id} skipped: connect failed ($e)');
      return 0;
    }
    var applied = 0;
    final blocked = await _mailsInFlightElsewhere(
      account.id,
      selected: {for (final r in rows) r.id},
    );
    try {
      for (final snapshot in rows) {
        if (blocked.contains(snapshot.resourceId)) continue;
        if (const [renameMailboxOp, moveMailboxOp, deleteMailboxOp]
            .contains(snapshot.changeType)) {
          // A mail change naming the folder (or a subfolder) is being sent
          // by another flush with the old path: the rename, move or delete
          // waits for it (nothing charged), or that change would name a
          // folder the server just renamed, moved or deleted.
          final folder = await _mailboxState.rowById(snapshot.resourceId);
          if (folder != null &&
              await _mailboxState.mailChangeInFlightFor(
                account.id,
                folder.path,
              )) {
            blocked.add(snapshot.resourceId);
            continue;
          }
        }
        final claimed = await _claimPendingChange(snapshot);
        if (claimed == null) {
          blocked.add(snapshot.resourceId);
          continue;
        }
        var row = claimed;
        if (row.changeType != createMailboxOp) {
          // Again after the claim: a mail flush that claimed a change
          // naming the folder in between backs off the same way (claim,
          // then check, on both sides), so the two are never sent at once.
          final folder = await _mailboxState.rowById(row.resourceId);
          if (folder != null &&
              await _mailboxState.mailChangeInFlightFor(
                account.id,
                folder.path,
              )) {
            await _unclaimPendingChange(row);
            blocked.add(row.resourceId);
            continue;
          }
        }
        // Read after the claim: an earlier op's ack may have moved it.
        final mailbox = await _mailboxState.rowById(row.resourceId);
        try {
          if (mailbox == null) {
            throw MailboxOpRefused('the folder no longer exists');
          }
          if (row.changeType == renameMailboxOp ||
              row.changeType == moveMailboxOp) {
            row = await _retargetFollowed(row, mailbox);
          }
          if (row.changeType == deleteMailboxOp) {
            final gone = await _applyMailboxDelete(
              row,
              mailbox,
              client: client,
              jmap: jmap,
            );
            if (!gone) {
              // Changes queued before it, or a subfolder's ops, go first.
              await _unclaimPendingChange(row);
              blocked.add(row.resourceId);
              continue;
            }
            final path = await _mailboxState.ackDelete(row);
            if (path == null) continue;
            applied++;
            // The folder is gone on the server: its cache goes, the
            // changes still naming it fail (listed), and its mail is
            // marked gone (kept while a change of it is unsettled).
            await removeLocalMailbox(
              _db,
              account.id,
              path,
              appLogger: _appLogger,
              deletedByUser: true,
            );
            continue;
          }
          if (row.changeType == moveMailboxOp) {
            final moved = await _applyMailboxMove(
              row,
              mailbox,
              client: client,
              jmap: jmap,
            );
            if (moved == null) {
              // Its folder or its new parent is not on the server yet.
              await _unclaimPendingChange(row);
              blocked.add(row.resourceId);
              continue;
            }
            if (await _mailboxState.ack(
              row,
              serverPath: moved.path,
              serverName: mailbox.srvName ?? mailbox.name,
              jmapParentConfirmed: jmap != null,
              serverParent: moved.parent,
            )) {
              applied++;
            }
            continue;
          }
          final done = await _applyMailboxOp(
            row,
            mailbox,
            client: client,
            jmap: jmap,
          );
          if (done == null) {
            // Its folder or parent folder is not on the server yet.
            await _unclaimPendingChange(row);
            blocked.add(row.resourceId);
            continue;
          }
          if (await _mailboxState.ack(
            row,
            serverPath: done.path,
            serverName: done.name,
            readConfirmed: done.read,
          )) {
            applied++;
          }
        } on MailboxOpRefused catch (e) {
          blocked.add(row.resourceId);
          if (e.goneAt case final gone? when mailbox != null) {
            if (await _waitForListing(account, row, mailbox, gone, e)) {
              continue;
            }
          }
          final dependents = await _mailboxState.fail(row, e.message);
          if (dependents == null) continue;
          _mailboxState.logDependents(row, dependents);
          if (e.badAnswer case final bad?) {
            _logImapBadFailure(row, bad, mailboxPath: mailbox?.path);
            continue;
          }
          unawaited(
            _appLogger?.error(
              'pending_change.rejected',
              'Server rejected ${_describeChange(row)} '
                  '"${mailbox?.name ?? row.resourceId}": ${e.message}; kept '
                  'on the Pending Changes screen',
              accountId: account.id,
              mailboxPath: mailbox?.path,
              data: {'changeType': row.changeType, 'changeId': row.id},
              error: e,
            ),
          );
        } catch (e) {
          final lost = jmap != null
              ? isJmapNetworkError(e)
              : !client!.isConnected || isImapConnectionLost(e);
          if (lost) {
            // Maybe sent: kept, and the next try looks before acting.
            await _keepClaimWithoutCharge(row, e);
            log('Mailbox flush for ${account.id} stopped: network ($e)');
            break;
          }
          await _recordChangeError(row, e);
          blocked.add(row.resourceId);
        }
      }
    } finally {
      if (client != null) await closeImapClient(client);
    }
    return applied;
  }

  /// Rename or move [row] of [mailbox] that waited for a folder listing,
  /// as its folder (or the folder it moves into) was not at its path on the
  /// server (#1329, [MailboxStateWriter.waitForListing]): when the listing
  /// followed that folder to another path (another client renamed or moved
  /// it), the op loses its mark and is sent there now (App Log warn
  /// `pending_change.folder_followed`). Returns the op as stored.
  Future<PendingChangeRow> _retargetFollowed(
    PendingChangeRow row,
    MailboxRow mailbox,
  ) async {
    final parent = row.changeType == moveMailboxOp
        ? (_decodePayload(row)?[mailboxOpParent] as String?)
        : null;
    final (:from, row: stored) = await _mailboxState.clearFollowedGoneAt(
      row,
      path: mailbox.path,
      parent: parent,
    );
    if (from == null) return stored;
    unawaited(
      _appLogger?.warn(
        'pending_change.folder_followed',
        'The ${_describeChange(row)} of "${mailbox.name}" waited because '
            '"$from" was not on the server; the folder list found it '
            'renamed or moved by another client, and the change is sent to '
            'the folder at "${mailbox.path}"'
            '${parent == null ? '' : ' (into "$parent")'} now',
        accountId: row.accountId,
        mailboxPath: mailbox.path,
        data: {
          'changeId': row.id,
          'changeType': row.changeType,
          'from': from,
          'path': mailbox.path,
          if (parent != null) 'parent': parent,
        },
      ),
    );
    return stored;
  }

  /// Rename or move [row] (claimed) of [mailbox] was refused with [e]
  /// because [gone] is not on the server (#1329): the folder, or the one
  /// it moves into, may have been renamed or moved by another client, and
  /// the folder listing after this flush follows it by its MAILBOXID (or
  /// the fallback rules). Returns true when the op waits for that listing
  /// (put back uncharged; the first time App Log info
  /// `mailbox.op_waits_for_listing`, and a kick so that the next cycle
  /// sends it to where the listing found the folder); false when the op
  /// may have reached the server before, once a listing started after the
  /// op was first put back finished without following the folder, or at
  /// the cap ([MailboxStateWriter.waitForListing]): the caller fails the op
  /// visibly.
  Future<bool> _waitForListing(
    account_model.Account account,
    PendingChangeRow row,
    MailboxRow mailbox,
    String gone,
    MailboxOpRefused e,
  ) async {
    final (:waits, :first) = await _mailboxState.waitForListing(row, gone);
    if (!waits) return false;
    await _unclaimPendingChange(row);
    if (!first) return true;
    // After the release: a listing that started while the op was claimed
    // took it for moving and followed nothing, so it must not count.
    await _mailboxState.markGoneAt(row.id, gone);
    unawaited(
      _appLogger?.info(
        'mailbox.op_waits_for_listing',
        'The ${_describeChange(row)} of "${mailbox.name}" waits: "$gone" is '
            'not on the server (${e.message}). Another client may have '
            'renamed or moved it; the folder list is read first, and the '
            'change is refused only if the folder is not found there',
        accountId: account.id,
        mailboxPath: mailbox.path,
        data: {
          'changeId': row.id,
          'changeType': row.changeType,
          'gone': gone,
        },
      ),
    );
    _changeCtrl.add(account.id);
    return true;
  }

  /// Whether claimed mail change [row] names a folder (or, on IMAP, a
  /// subfolder of one) whose rename, move or delete another flush is
  /// sending: the change is released and waits.
  Future<bool> _namesFolderBeingChanged(PendingChangeRow row) async {
    final busy = await _mailboxState.pathsBeingRenamed(row.accountId);
    if (busy.isEmpty) return false;
    final payload = _decodePayload(row);
    return emailOpFolderKeys.any((k) => busy.contains(payload?[k]));
  }

  /// [rows], the email changes a flush selected, without the ones that
  /// name a folder created offline that is not on the server yet
  /// ([MailboxStateWriter.localPaths]), nor any later change of their
  /// mails (a mail's changes reach the server in order). They wait, like a
  /// parked change, uncharged, for the folder's create; its ack names the
  /// server's folder in them ([MailboxStateWriter.serverPathChanged]), and
  /// its failure fails them. A change waiting for a folder whose create
  /// failed or is gone fails now ([MailboxStateWriter.failOrphanedWaiting]).
  Future<List<PendingChangeRow>> _holdForLocalFolders(
    String accountId,
    List<PendingChangeRow> rows,
  ) async {
    for (final (:cause, :dependents)
        in await _mailboxState.failOrphanedWaiting(accountId)) {
      _mailboxState.logDependents(cause, dependents);
    }
    // Folders not to name now: not created yet, being renamed by another
    // flush, or not at their path on the server while a rename or move of
    // theirs waits for the listing that may follow them (#1329).
    final waitFor = {
      ...await _mailboxState.localPaths(accountId),
      ...await _mailboxState.pathsBeingRenamed(accountId),
      ...await _mailboxState.pathsWaitingForListing(accountId),
    };
    // Folders being deleted: a change queued after the delete that names
    // one waits for it (phase 5b); one queued before goes first (the
    // delete waits for it instead).
    final deleting = await _mailboxState.pathsBeingDeleted(accountId);
    final held = <String>{};
    final out = <PendingChangeRow>[];
    for (final row in rows) {
      if (held.contains(row.resourceId)) continue;
      final payload = await _resolveStandIns(row);
      if (payload == null) {
        held.add(row.resourceId);
        continue;
      }
      if (emailOpFolderKeys.any((k) => waitFor.contains(payload[k]))) {
        held.add(row.resourceId);
        continue;
      }
      // Only a change that puts mail INTO the folder waits; one that takes
      // mail out of it (a move found by search, an Undo's move back) goes
      // first, and the delete waits for it.
      final deleteSeq = deleting[payload['dest']];
      if (deleteSeq != null && deleteSeq < row.id) {
        held.add(row.resourceId);
        continue;
      }
      out.add(row);
    }
    // A change failed just now is still in [out]; its claim finds it
    // failed and leaves it alone.
    return out;
  }

  /// The payload of mail change [row] with every folder it names that no
  /// mailbox has any more resolved to the folder's path now
  /// ([MailboxStateWriter.resolveStandIn]: a JMAP `~new:` stand-in, or an
  /// IMAP path guessed before the create's ack corrected it, still named by
  /// a screen opened before the ack), written back. A `~new:` stand-in no
  /// folder had fails the change (it would be sent as a mailbox id the
  /// server never gave): null then.
  Future<Map<String, dynamic>?> _resolveStandIns(PendingChangeRow row) async {
    final payload = _decodePayload(row);
    if (payload == null) return const {};
    var changed = false;
    for (final key in emailOpFolderKeys) {
      final path = payload[key];
      if (path is! String) continue;
      final resolved = await _mailboxState.resolveStandIn(row.accountId, path);
      if (resolved == path) continue;
      if (resolved == null) {
        if (!path.startsWith(localJmapMailboxPrefix)) continue;
        await _mailboxState.failStandIn(row, path);
        return null;
      }
      payload[key] = resolved;
      changed = true;
    }
    if (changed) {
      await (_db.update(_db.pendingChanges)
            ..where(
              (t) =>
                  t.id.equals(row.id) &
                  t.state.isIn(const ['pending', 'stuck', 'parked']),
            ))
          .write(PendingChangesCompanion(payload: Value(jsonEncode(payload))));
      await _refoldAndRethread(row.resourceId);
    }
    return payload;
  }

  /// Sends mailbox op [row] of [mailbox] over [client] (IMAP) or [jmap].
  /// Null: it waits (the folder or its parent is not on the server yet).
  Future<_MailboxDone?> _applyMailboxOp(
    PendingChangeRow row,
    MailboxRow mailbox, {
    required imap.ImapClient? client,
    required JmapClient? jmap,
  }) async {
    final payload = _decodePayload(row) ?? const <String, dynamic>{};
    final name = payload[mailboxOpName] as String? ?? mailbox.name;
    switch (row.changeType) {
      case createMailboxOp:
        final parent = payload[mailboxOpParent] as String?;
        final early = await _createWithoutCall(row, mailbox, parent, name);
        if (early != null) return early.path.isEmpty ? null : early;
        final role = payload[mailboxOpRole] as String?;
        return jmap != null
            ? _createJmap(jmap, row, parent, name, role)
            : _createImap(client!, row, parent, name, role);
      case renameMailboxOp:
        if (mailbox.isLocal) return null;
        return jmap != null
            ? _renameJmap(jmap, mailbox, name)
            : _renameImap(client!, row, mailbox, name);
    }
    throw MailboxOpRefused('unknown folder change "${row.changeType}"');
  }

  // ── IMAP ──────────────────────────────────────────────────────────────

  Future<_MailboxDone> _createImap(
    imap.ImapClient client,
    PendingChangeRow row,
    String? parent,
    String name,
    String? role,
  ) async {
    final folders = await client.listMailboxes(recursive: true);
    final separator = imapSeparatorOf(folders);
    await _mailboxState.recordImapSeparator(row.accountId, separator);
    final target = parent == null ? name : '$parent$separator$name';
    bool exists(List<imap.Mailbox> list) => list.any((m) => m.path == target);
    // Our own earlier try may have created it (an answer lost on the
    // way); a role folder (Archive, Junk) that exists is the one meant.
    final mine = row.attempts > 0 || role != null;
    if (exists(folders)) {
      if (mine) return (path: target, name: name, read: true);
      throw MailboxOpRefused('a folder named "$name" already exists');
    }
    try {
      await client.createMailbox(target);
    } catch (e) {
      if (!client.isConnected || isImapConnectionLost(e)) rethrow;
      if (exists(await client.listMailboxes(recursive: true))) {
        if (mine) return (path: target, name: name, read: true);
        throw MailboxOpRefused('a folder named "$name" already exists');
      }
      final refused = _imapFolderRefusal(e, 'the server refused the folder');
      if (refused != null) throw refused;
      rethrow;
    }
    return (path: target, name: name, read: false);
  }

  Future<_MailboxDone> _renameImap(
    imap.ImapClient client,
    PendingChangeRow row,
    MailboxRow mailbox,
    String name,
  ) async {
    final from = mailbox.path;
    final separator = await imapPathSeparator(client);
    await _mailboxState.recordImapSeparator(row.accountId, separator);
    final parts = from.split(separator);
    parts[parts.length - 1] = name;
    final to = parts.join(separator);
    if (to == from) return (path: from, name: name, read: false);
    await _renameImapTo(client, row, from, to, name, separator);
    return (path: to, name: name, read: false);
  }

  /// IMAP `RENAME` of folder [from] (with its subfolders) to [to], for a
  /// rename or a move ([row]): a try after one that may have been sent
  /// looks first; after a refusal the listing tells a clash, a folder gone
  /// and a rename found done apart.
  Future<void> _renameImapTo(
    imap.ImapClient client,
    PendingChangeRow row,
    String from,
    String to,
    String name,
    String separator,
  ) async {
    Future<bool> done() async {
      final list = await client.listMailboxes(recursive: true);
      return list.any((m) => m.path == to) && !list.any((m) => m.path == from);
    }

    if (row.attempts > 0 && await done()) return;
    try {
      // IMAP RENAME's second argument is the full destination path.
      await client.renameMailbox(imapMailboxFor(from, separator), to);
    } catch (e) {
      if (!client.isConnected || isImapConnectionLost(e)) rethrow;
      final list = await client.listMailboxes(recursive: true);
      final hasFrom = list.any((m) => m.path == from);
      final hasTo = list.any((m) => m.path == to);
      if (hasTo && !hasFrom) return;
      if (hasTo) {
        throw MailboxOpRefused('a folder named "$name" already exists');
      }
      if (!hasFrom) {
        // Deleted, or renamed or moved by another client: the op waits for
        // a folder listing that may follow it (#1329).
        throw MailboxOpRefused(
          'the folder no longer exists on the server',
          goneAt: from,
        );
      }
      final refused = _imapFolderRefusal(e, 'the server refused it');
      if (refused != null) throw refused;
      rethrow;
    }
  }

  /// Sends folder move [row] of [mailbox] over [client] (IMAP: `RENAME` to
  /// the new parent's path and the leaf, its subfolders follow) or [jmap]
  /// (`Mailbox/set` `parentId`). Returns the folder's server path and its
  /// new parent's path (null: top level), or null when it waits: the
  /// folder, or the folder it moves into, is not on the server yet.
  Future<({String path, String? parent})?> _applyMailboxMove(
    PendingChangeRow row,
    MailboxRow mailbox, {
    required imap.ImapClient? client,
    required JmapClient? jmap,
  }) async {
    if (mailbox.isLocal) return null;
    final payload = _decodePayload(row) ?? const <String, dynamic>{};
    var parent = payload[mailboxOpParent] as String?;
    if (parent != null) {
      final resolved =
          await _mailboxState.resolveStandIn(row.accountId, parent);
      if (resolved == null &&
          (jmap != null || parent.startsWith(localJmapMailboxPrefix))) {
        throw MailboxOpRefused(
          'the folder it is moved into does not exist any more',
        );
      }
      // IMAP: a parent path no folder is cached for (a namespace prefix)
      // is the server's to judge.
      parent = resolved ?? parent;
      final target = await _mailboxState.rowByPath(row.accountId, parent);
      if (target != null && target.isLocal) return null;
      // Its parent's own rename or move may have reached the server: its
      // path may be gone (an IMAP RENAME into it would create it again).
      if (target != null && await _mailboxState.mayBeMoving(target.id)) {
        return null;
      }
      if (target != null && target.localHidden) {
        throw MailboxOpRefused('the folder it is moved into is being deleted');
      }
    }
    if (jmap != null) {
      final responses = await jmap.call([
        [
          'Mailbox/set',
          {
            'accountId': jmap.accountId,
            'update': {
              mailbox.path: {'parentId': parent},
            },
          },
          '0',
        ],
      ]);
      final result = _responseArgs(responses, 0, 'Mailbox/set');
      final notUpdated = result['notUpdated'] as Map<String, dynamic>?;
      final err = notUpdated?[mailbox.path] as Map<String, dynamic>?;
      if (err != null) throw MailboxOpRefused(jmapMailboxSetErrorText(err));
      return (path: mailbox.path, parent: parent);
    }
    final imapClient = client!;
    final from = mailbox.path;
    final folders = await imapClient.listMailboxes(recursive: true);
    final separator = imapSeparatorOf(folders);
    await _mailboxState.recordImapSeparator(row.accountId, separator);
    // An IMAP RENAME SHOULD create missing parents: a parent the server
    // does not list (deleted elsewhere since, an Undo's old parent) would
    // come back. Refused instead.
    if (parent != null && !folders.any((m) => m.path == parent)) {
      throw MailboxOpRefused(
        'the folder it is moved into does not exist on the server',
        // A cached folder may have been renamed or moved by another
        // client: the move waits for a listing that may follow it (#1329).
        goneAt: await _mailboxState.rowByPath(row.accountId, parent) != null
            ? parent
            : null,
      );
    }
    final cut = from.lastIndexOf(separator);
    final leaf = cut < 0 ? from : from.substring(cut + separator.length);
    final to = parent == null ? leaf : '$parent$separator$leaf';
    if (to == from) return (path: from, parent: parent);
    if (parent != null &&
        (parent == from || parent.startsWith('$from$separator'))) {
      throw MailboxOpRefused('a folder cannot be moved into itself');
    }
    await _renameImapTo(imapClient, row, from, to, leaf, separator);
    return (path: to, parent: parent);
  }

  /// Sends folder delete [row] of [mailbox] over [client] (IMAP `DELETE`)
  /// or [jmap] (`Mailbox/set` `destroy`). With the payload's
  /// `removeEmails` the mail it has goes with it (the user confirmed);
  /// without, a folder that has mail on the server is refused, so mail
  /// that arrived (or was moved in) after the user's look is never deleted
  /// silently. A folder already gone counts as done (§5 "satisfied").
  /// Returns false when it waits: a change queued before it names the
  /// folder or a subfolder (its mail is moved out or in first), or an op of
  /// a subfolder queued before it is not done yet.
  Future<bool> _applyMailboxDelete(
    PendingChangeRow row,
    MailboxRow mailbox, {
    required imap.ImapClient? client,
    required JmapClient? jmap,
  }) async {
    if (mailbox.isLocal) return false;
    // A counterpart's shadow counts while its primary is not done: the
    // other account's move of the shared mail out of the folder must reach
    // the server first.
    const unsettled = [
      _pendingState,
      _inflightState,
      _stuckState,
      _shadowState,
    ];
    if (await _mailboxState.mailChangeQueuedFor(
          row.accountId,
          mailbox.path,
          states: unsettled,
          before: row.id,
        ) ||
        await _mailboxState.mailLeavingQueuedFor(
          row.accountId,
          mailbox.path,
          states: unsettled,
        ) ||
        await _mailboxState.subfolderOpQueued(mailbox, before: row.id)) {
      return false;
    }
    final payload = _decodePayload(row) ?? const <String, dynamic>{};
    final removeEmails = payload[mailboxOpRemoveEmails] == true;
    // How many mails the user agreed to delete with it: more on the server
    // (arrived, or moved in elsewhere, since) refuses the delete.
    final confirmed = payload[mailboxOpConfirmedMessages] as int?;
    if (jmap != null) {
      if (removeEmails && confirmed != null) {
        final got = await jmap.call([
          [
            'Mailbox/get',
            {
              'accountId': jmap.accountId,
              'ids': [mailbox.path],
              'properties': ['totalEmails'],
            },
            '0',
          ],
        ]);
        final list = _responseArgs(got, 0, 'Mailbox/get')['list'];
        final found = list is List
            ? list
                .whereType<Map<String, dynamic>>()
                .where((m) => m['id'] == mailbox.path)
                .firstOrNull
            : null;
        final total = found?['totalEmails'];
        if (total is int) _refuseNewMail(row, mailbox, total, confirmed);
      }
      final responses = await jmap.call([
        [
          'Mailbox/set',
          {
            'accountId': jmap.accountId,
            'destroy': [mailbox.path],
            if (removeEmails) 'onDestroyRemoveEmails': true,
          },
          '0',
        ],
      ]);
      final result = _responseArgs(responses, 0, 'Mailbox/set');
      final err = (result['notDestroyed']
          as Map<String, dynamic>?)?[mailbox.path] as Map<String, dynamic>?;
      if (err == null || err['type'] == 'notFound') return true;
      throw MailboxOpRefused(jmapMailboxSetErrorText(err));
    }
    final imapClient = client!;
    final path = mailbox.path;
    final folders = await imapClient.listMailboxes(recursive: true);
    final separator = imapSeparatorOf(folders);
    await _mailboxState.recordImapSeparator(row.accountId, separator);
    if (!folders.any((m) => m.path == path)) return true;
    if (folders.any((m) => m.path.startsWith('$path$separator'))) {
      // IMAP DELETE would leave them (or the server refuses): the app
      // deletes a folder only once its subfolders are gone.
      throw MailboxOpRefused('the folder still has subfolders on the server');
    }
    final box = imapMailboxFor(path, separator);
    try {
      if (!removeEmails || confirmed != null) {
        final status =
            await imapClient.statusMailbox(box, [imap.StatusFlags.messages]);
        if (!removeEmails && status.messagesExists > 0) {
          throw MailboxOpRefused(folderHasMailText);
        }
        if (removeEmails && confirmed != null) {
          _refuseNewMail(row, mailbox, status.messagesExists, confirmed);
        }
      }
      await imapClient.deleteMailbox(box);
    } on MailboxOpRefused {
      rethrow;
    } catch (e) {
      if (!imapClient.isConnected || isImapConnectionLost(e)) rethrow;
      final list = await imapClient.listMailboxes(recursive: true);
      if (!list.any((m) => m.path == path)) return true;
      final refused = _imapFolderRefusal(e, 'the server refused it');
      if (refused != null) throw refused;
      rethrow;
    }
    return true;
  }

  /// Refuses delete [row] of [mailbox] when the server has more mail in it
  /// ([onServer]) than the user agreed to delete with it ([confirmed]): it
  /// arrived, or was moved in, after the user's look (App Log warn
  /// `mailbox.delete_new_mail`); the folder shows again.
  void _refuseNewMail(
    PendingChangeRow row,
    MailboxRow mailbox,
    int onServer,
    int confirmed,
  ) {
    if (onServer <= confirmed) return;
    unawaited(
      _appLogger?.warn(
        'mailbox.delete_new_mail',
        'Did not delete the folder "${mailbox.name}": it has $onServer '
            'mail(s) on the server, more than the $confirmed the delete was '
            'confirmed for',
        accountId: row.accountId,
        mailboxPath: mailbox.path,
        data: {
          'changeId': row.id,
          'onServer': onServer,
          'confirmed': confirmed,
        },
      ),
    );
    throw MailboxOpRefused(
      'the folder has ${onServer - confirmed} more mail(s) on the server '
      'than when it was deleted; delete it again to delete them too',
    );
  }

  /// The outcome of create [row] of [mailbox] that needs no server call:
  /// done when a listing has the folder already (another client made it,
  /// or our earlier try did, §5 satisfied), or one with an empty path when
  /// its [parent] has no server copy yet (the create waits); null to send
  /// it.
  Future<_MailboxDone?> _createWithoutCall(
    PendingChangeRow row,
    MailboxRow mailbox,
    String? parent,
    String name,
  ) async {
    if (!mailbox.isLocal) {
      return (path: mailbox.path, name: mailbox.srvName ?? name, read: true);
    }
    if (parent != null && await _isLocalFolder(row.accountId, parent)) {
      return (path: '', name: name, read: false);
    }
    return null;
  }

  Future<bool> _isLocalFolder(String accountId, String path) async =>
      (await _mailboxState.rowByPath(accountId, path))?.isLocal ?? false;

  // ── JMAP ──────────────────────────────────────────────────────────────

  Future<_MailboxDone> _createJmap(
    JmapClient jmap,
    PendingChangeRow row,
    String? parent,
    String name,
    String? role,
  ) async {
    if (parent != null && parent.startsWith(localJmapMailboxPrefix)) {
      throw MailboxOpRefused('its parent folder was not created');
    }
    // A role folder the server has is the one meant (the Snoozed folder
    // another device made); our own earlier try may have created it.
    if (role != null || row.attempts > 0) {
      final found = await _findJmapMailbox(
        jmap,
        name: name,
        parentId: parent,
        role: role,
      );
      if (found != null) return found;
    }
    // The `snoozed` role is not in the IANA registry and servers such
    // as Stalwart reject it: a role the server refuses is left out.
    for (final withRole in role == null ? const [false] : const [true, false]) {
      final responses = await jmap.call([
        [
          'Mailbox/set',
          {
            'accountId': jmap.accountId,
            'create': {
              'c0': {
                'name': name,
                if (parent != null) 'parentId': parent,
                if (withRole) 'role': role,
              },
            },
          },
          '0',
        ],
      ]);
      final result = _responseArgs(responses, 0, 'Mailbox/set');
      final created = (result['created'] as Map<String, dynamic>?)?['c0']
          as Map<String, dynamic>?;
      final id = created?['id'] as String?;
      if (id != null) return (path: id, name: name, read: false);
      final err = ((result['notCreated'] as Map<String, dynamic>?)?['c0']
              as Map<String, dynamic>?) ??
          const {'type': 'serverFail'};
      if (withRole && err['type'] == 'invalidProperties') continue;
      throw MailboxOpRefused(jmapMailboxSetErrorText(err));
    }
    throw MailboxOpRefused('the server did not create the folder');
  }

  Future<_MailboxDone> _renameJmap(
    JmapClient jmap,
    MailboxRow mailbox,
    String name,
  ) async {
    final responses = await jmap.call([
      [
        'Mailbox/set',
        {
          'accountId': jmap.accountId,
          'update': {
            mailbox.path: {'name': name},
          },
        },
        '0',
      ],
    ]);
    final result = _responseArgs(responses, 0, 'Mailbox/set');
    final notUpdated = result['notUpdated'] as Map<String, dynamic>?;
    final err = notUpdated?[mailbox.path] as Map<String, dynamic>?;
    if (err != null) throw MailboxOpRefused(jmapMailboxSetErrorText(err));
    return (path: mailbox.path, name: name, read: false);
  }

  /// The server's mailbox with [role] (when given), else the one called
  /// [name] below [parentId] (top level when null), or null.
  Future<_MailboxDone?> _findJmapMailbox(
    JmapClient jmap, {
    required String name,
    required String? parentId,
    required String? role,
  }) async {
    final responses = await jmap.call([
      [
        'Mailbox/get',
        {
          'accountId': jmap.accountId,
          'ids': null,
          'properties': ['name', 'role', 'parentId'],
        },
        '0',
      ],
    ]);
    final list =
        (_responseArgs(responses, 0, 'Mailbox/get')['list'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
    final match = (role == null
            ? null
            : list.where((m) => m['role'] == role).firstOrNull) ??
        list
            .where((m) => m['name'] == name && m['parentId'] == parentId)
            .firstOrNull;
    if (match == null) return null;
    return (
      path: match['id'] as String,
      name: match['name'] as String? ?? name,
      read: true,
    );
  }
}
