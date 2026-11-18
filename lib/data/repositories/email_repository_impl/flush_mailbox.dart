part of '../email_repository_impl.dart';

// Mailbox flush (SYNC-REDESIGN.md §7, phase 5a): sending the queued folder
// creates and renames to the server, before the account's email changes,
// and holding back the email changes that need a folder not created yet.

/// What the server confirmed for a mailbox op: the folder is at [path]
/// under [name].
typedef _MailboxDone = ({String path, String name});

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
          final done = jmap != null
              ? await _applyMailboxOpJmap(jmap, row, mailbox)
              : await _applyMailboxOpImap(client!, row, mailbox);
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
    final local = await _mailboxState.localPaths(accountId);
    if (local.isEmpty) return rows;
    final held = <String>{};
    final out = <PendingChangeRow>[];
    for (final row in rows) {
      if (held.contains(row.resourceId)) continue;
      final payload = _decodePayload(row);
      if (emailOpFolderKeys.any((k) => local.contains(payload?[k]))) {
        held.add(row.resourceId);
        continue;
      }
      out.add(row);
    }
    // A change failed just now is still in [out]; its claim finds it
    // failed and leaves it alone.
    return out;
  }

  // ── IMAP ──────────────────────────────────────────────────────────────

  /// Sends mailbox op [row] of [mailbox] over [client]. Null: it waits (the
  /// folder or its parent is not on the server yet).
  Future<_MailboxDone?> _applyMailboxOpImap(
    imap.ImapClient client,
    PendingChangeRow row,
    MailboxRow mailbox,
  ) async {
    final payload = _decodePayload(row) ?? const <String, dynamic>{};
    final name = payload[mailboxOpName] as String? ?? mailbox.name;
    switch (row.changeType) {
      case createMailboxOp:
        // Listed meanwhile (another client made it, or our earlier try
        // did): the intent is satisfied.
        if (!mailbox.isLocal) {
          return (path: mailbox.path, name: mailbox.srvName ?? name);
        }
        final parent = payload[mailboxOpParent] as String?;
        if (parent != null && await _isLocalFolder(row.accountId, parent)) {
          return null;
        }
        final folders = await client.listMailboxes(recursive: true);
        final separator = _separatorFor(parent, folders);
        final target = parent == null ? name : '$parent$separator$name';
        bool exists(List<imap.Mailbox> list) =>
            list.any((m) => m.path == target);
        // Our own earlier try may have created it (an answer lost on the
        // way); a role folder (Archive, Junk) that exists is the one meant.
        final mine = row.attempts > 0 || payload[mailboxOpRole] != null;
        if (exists(folders)) {
          if (mine) return (path: target, name: name);
          throw MailboxOpRefused('a folder named "$name" already exists');
        }
        try {
          await client.createMailbox(target);
        } catch (e) {
          if (!client.isConnected || isImapConnectionLost(e)) rethrow;
          if (exists(await client.listMailboxes(recursive: true))) {
            if (mine) return (path: target, name: name);
            throw MailboxOpRefused('a folder named "$name" already exists');
          }
          if (isImapPermanentRefusal(e)) {
            throw MailboxOpRefused('the server refused the folder: $e');
          }
          rethrow;
        }
        return (path: target, name: name);
      case renameMailboxOp:
        if (mailbox.isLocal) return null;
        final from = mailbox.path;
        final separator = await imapPathSeparator(client, from);
        final parts = from.split(separator);
        parts[parts.length - 1] = name;
        final to = parts.join(separator);
        if (to == from) return (path: from, name: name);
        Future<bool> done() async {
          final list = await client.listMailboxes(recursive: true);
          return list.any((m) => m.path == to) &&
              !list.any((m) => m.path == from);
        }

        if (row.attempts > 0 && await done()) return (path: to, name: name);
        try {
          // IMAP RENAME's second argument is the full destination path.
          await client.renameMailbox(imapMailboxFor(from), to);
        } catch (e) {
          if (!client.isConnected || isImapConnectionLost(e)) rethrow;
          final list = await client.listMailboxes(recursive: true);
          final hasFrom = list.any((m) => m.path == from);
          final hasTo = list.any((m) => m.path == to);
          if (hasTo && !hasFrom) return (path: to, name: name);
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
        return (path: to, name: name);
    }
    throw MailboxOpRefused('unknown folder change "${row.changeType}"');
  }

  /// The hierarchy separator below [parent]: from its path, else the
  /// server's (LIST answer [folders]).
  static String _separatorFor(String? parent, List<imap.Mailbox> folders) {
    if (parent != null) {
      if (parent.contains('/')) return '/';
      if (parent.contains('.')) return '.';
    }
    final listed = folders.firstOrNull?.pathSeparator;
    return listed == null || listed.isEmpty ? '/' : listed;
  }

  Future<bool> _isLocalFolder(String accountId, String path) async =>
      (await _mailboxState.rowByPath(accountId, path))?.isLocal ?? false;

  // ── JMAP ──────────────────────────────────────────────────────────────

  /// Sends mailbox op [row] of [mailbox] over [jmap]. Null: it waits.
  Future<_MailboxDone?> _applyMailboxOpJmap(
    JmapClient jmap,
    PendingChangeRow row,
    MailboxRow mailbox,
  ) async {
    final payload = _decodePayload(row) ?? const <String, dynamic>{};
    final name = payload[mailboxOpName] as String? ?? mailbox.name;
    switch (row.changeType) {
      case createMailboxOp:
        if (!mailbox.isLocal) {
          return (path: mailbox.path, name: mailbox.srvName ?? name);
        }
        final parent = payload[mailboxOpParent] as String?;
        if (parent != null && await _isLocalFolder(row.accountId, parent)) {
          return null;
        }
        if (parent != null && parent.startsWith(localJmapMailboxPrefix)) {
          throw MailboxOpRefused('its parent folder was not created');
        }
        final role = payload[mailboxOpRole] as String?;
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
        for (final withRole
            in role == null ? const [false] : const [true, false]) {
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
          if (id != null) return (path: id, name: name);
          final err = ((result['notCreated'] as Map<String, dynamic>?)?['c0']
                  as Map<String, dynamic>?) ??
              const {'type': 'serverFail'};
          if (withRole && err['type'] == 'invalidProperties') continue;
          throw MailboxOpRefused(jmapMailboxSetErrorText(err));
        }
        throw MailboxOpRefused('the server did not create the folder');
      case renameMailboxOp:
        if (mailbox.isLocal) return null;
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
        return (path: mailbox.path, name: name);
    }
    throw MailboxOpRefused('unknown folder change "${row.changeType}"');
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
    );
  }
}
