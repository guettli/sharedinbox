part of '../email_repository_impl.dart';

// Mailbox flush (SYNC-REDESIGN.md §7, phase 5a): sending the queued folder
// creates and renames to the server, before the account's email changes,
// and holding back the email changes that need a folder not created yet.

/// What the server confirmed for a mailbox op: the folder is at [path]
/// under [name]; [read]: found in a read of the server (a create of a
/// folder that exists), not by our command's answer.
typedef _MailboxDone = ({String path, String name, bool read});

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
  Future<int> _flushMailboxOps(
    account_model.Account account,
    String password,
  ) async {
    final now = _now();
    final rows = await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.accountId.equals(account.id) &
                t.resourceType.equals(mailboxResourceType) &
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
        if (snapshot.changeType == renameMailboxOp) {
          // A mail change naming the folder is being sent by another flush
          // with the old path: the rename waits for it (nothing charged),
          // or that change would name a folder the server just renamed.
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
        final row = await _claimPendingChange(snapshot);
        if (row == null) {
          blocked.add(snapshot.resourceId);
          continue;
        }
        // Read after the claim: an earlier op's ack may have moved it.
        final mailbox = await _mailboxState.rowById(row.resourceId);
        try {
          if (mailbox == null) {
            throw MailboxOpRefused('the folder no longer exists');
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
          final dependents = await _mailboxState.fail(row, e.message);
          if (dependents == null) continue;
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
          _mailboxState.logDependents(row, dependents);
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
    // Folders not to name now: not created yet, or being renamed by
    // another flush.
    final waitFor = {
      ...await _mailboxState.localPaths(accountId),
      ...await _mailboxState.pathsBeingRenamed(accountId),
    };
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
      if (isImapPermanentRefusal(e)) {
        throw MailboxOpRefused('the server refused the folder: $e');
      }
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
    Future<bool> done() async {
      final list = await client.listMailboxes(recursive: true);
      return list.any((m) => m.path == to) && !list.any((m) => m.path == from);
    }

    if (row.attempts > 0 && await done()) {
      return (path: to, name: name, read: false);
    }
    try {
      // IMAP RENAME's second argument is the full destination path.
      await client.renameMailbox(imapMailboxFor(from, separator), to);
    } catch (e) {
      if (!client.isConnected || isImapConnectionLost(e)) rethrow;
      final list = await client.listMailboxes(recursive: true);
      final hasFrom = list.any((m) => m.path == from);
      final hasTo = list.any((m) => m.path == to);
      if (hasTo && !hasFrom) return (path: to, name: name, read: false);
      if (hasTo) {
        throw MailboxOpRefused('a folder named "$name" already exists');
      }
      if (!hasFrom) {
        throw MailboxOpRefused(
          'the folder no longer exists on the server',
        );
      }
      if (isImapPermanentRefusal(e)) {
        throw MailboxOpRefused('the server refused the new name: $e');
      }
      rethrow;
    }
    return (path: to, name: name, read: false);
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
