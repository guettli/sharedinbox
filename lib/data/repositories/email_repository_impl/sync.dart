part of '../email_repository_impl.dart';

// Sync entry points shared by IMAP and JMAP: sync dispatch, force-resync
// clearing and the address-header backfill.

extension _Sync on EmailRepositoryImpl {
  // ── Sync ───────────────────────────────────────────────────────────────────

  Future<model.SyncEmailsResult> _syncEmails(
    String accountId,
    String mailboxPath,
  ) async {
    // A folder created offline is not on the server yet: nothing to sync,
    // and a SELECT or Email/query of its stand-in path must not read as
    // "folder deleted on the server" (SYNC-REDESIGN.md §7).
    // A folder being deleted (phase 5b) is not synced either: it shows
    // nowhere, and its delete settles it.
    final folder = await _mailboxState.rowByPath(accountId, mailboxPath);
    if (folder != null && (folder.isLocal || folder.localHidden)) {
      return model.SyncEmailsResult.zero;
    }
    final account = (await _accounts.getAccount(accountId))!;
    final password = await _accounts.getPassword(accountId);
    final started = _now();
    // Before every read of this sync: a foreign move's source found gone
    // by an enumeration before it is one this sync could adopt.
    final startSeq = await _state.nextReadSeq();
    // One sync run: a change one of its reads contradicts is given up only
    // on a read of a later run (SYNC.md §6a).
    final result = await _state.inSyncRun(() async {
      switch (account.type) {
        case account_model.AccountType.imap:
          return _syncEmailsImap(account, password, mailboxPath);
        case account_model.AccountType.jmap:
          return _syncEmailsJmap(account, password, mailboxPath);
      }
    });
    await _afterFolderSync(
      accountId,
      mailboxPath,
      started,
      imapStartSeq:
          account.type == account_model.AccountType.imap ? startSeq : null,
    );
    // Sampled, at most every half hour per account (SYNC.md §6a). Awaited:
    // it is bounded (a few ms when due, one row read otherwise), and a
    // background isolate may end as soon as the sync returns.
    await _consistencySampler?.afterSyncRun(
      _state,
      accountId,
      onRepaired: _refreshThreadsOf,
      alsoCheck: () => _mailboxState.checkAndRepair(accountId),
    );
    return result;
  }

  /// What waits for [mailboxPath]'s sync, which started at [started] and
  /// succeeded (SYNC-REDESIGN.md §6, §4.5): an acked move into it whose
  /// mail that sync did not store gives up waiting (the mail is not there);
  /// one that waited [EmailStateWriter.awaitAppearWindow] gives up too; and
  /// the virtual rows and parked changes this folder's sync could have
  /// matched expire after [EmailStateWriter.parkedExpiry]. Never before the
  /// sync: a week offline must not drop a note whose copy the next sync
  /// stores.
  ///
  /// On IMAP ([imapStartSeq]: the read sequence taken before the sync's
  /// first read) the folder is recorded as synced since then, and the rows
  /// gone from another folder that waited for a foreign move's destination
  /// end their wait once no folder is left that could still adopt them
  /// ([_expireForeignMoveWaits]).
  Future<void> _afterFolderSync(
    String accountId,
    String mailboxPath,
    DateTime started, {
    int? imapStartSeq,
  }) async {
    if (imapStartSeq != null) {
      await _saveSyncState(
        accountId,
        '${EmailStateWriter.folderSyncedPrefix}$mailboxPath',
        '$imapStartSeq',
      );
    }
    await _expireForeignMoveWaits(accountId);
    final ended = {
      ...await _state.endAwaitedMoves(accountId, mailboxPath, started),
      ...await _state.expireAwaitedMoves(accountId),
    };
    for (final id in ended) {
      await _rethreadRow(id);
    }
    if (ended.isNotEmpty) await _state.cleanUpGone(accountId);
    await _expireParked(
      accountId,
      folder: mailboxPath,
      role: await _mailboxRole(accountId, mailboxPath),
    );
  }

  /// [EmailStateWriter.expireForeignMoveWaits] for [accountId], then the
  /// clean-up rule, with an App Log line for each row it deleted
  /// (`email.foreign_move_wait_expired`; warn when its cached body or
  /// downloaded attachments go with it): no folder's sync stored its mail,
  /// so another client deleted it (or moved it where this app does not
  /// look, e.g. only All Mail on Gmail).
  Future<void> _expireForeignMoveWaits(String accountId) async {
    final expired = await _state.expireForeignMoveWaits(accountId);
    if (expired.isEmpty) return;
    final ids = [for (final row in expired) row.id];
    final withBody = {
      for (final b in await (_db.selectOnly(_db.emailBodies)
            ..addColumns([_db.emailBodies.emailId])
            ..where(_db.emailBodies.emailId.isIn(ids)))
          .get())
        b.read(_db.emailBodies.emailId)!,
    };
    final files = <String, int>{};
    for (final f in await (_db.select(_db.attachmentFiles)
          ..where((t) => t.emailId.isIn(ids)))
        .get()) {
      files[f.emailId] = (files[f.emailId] ?? 0) + 1;
    }
    final deleted = (await _state.cleanUpGone(accountId)).toSet();
    for (final row in expired) {
      if (!deleted.contains(row.id)) continue;
      _logForeignMoveWaitExpired(
        row,
        body: withBody.contains(row.id),
        attachments: files[row.id] ?? 0,
      );
    }
  }

  /// App Log line for [row], deleted when its wait for a foreign move's
  /// destination ended; warn when its cached [body] or [attachments] went
  /// with it.
  void _logForeignMoveWaitExpired(
    Email row, {
    required bool body,
    required int attachments,
  }) {
    final lost = [
      if (body) 'body',
      if (attachments > 0) '$attachments downloaded attachment(s)',
    ];
    final from = row.srvMailboxPath ?? '?';
    final message = 'Removed "${row.subject ?? '(no subject)'}", gone from '
        '$from on the server: no other folder received it within the wait'
        '${lost.isEmpty ? '' : ' (its cached ${lost.join(' and ')} went '
            'with it)'}';
    unawaited(
      _appLogger?.log(
        level: lost.isEmpty ? AppLogLevel.info : AppLogLevel.warn,
        event: 'email.foreign_move_wait_expired',
        message: message,
        accountId: row.accountId,
        mailboxPath: from,
        data: {
          'removedEmailId': row.id,
          'messageId': row.messageId,
          'from': from,
          'body': body,
          'attachments': attachments,
        },
      ),
    );
  }

  /// Refreshes the thread aggregates of the rows [emailIds] (the sampled
  /// consistency check repaired their shown read/star/snooze state).
  Future<void> _refreshThreadsOf(Set<String> emailIds) async {
    final rows =
        await (_db.select(_db.emails)..where((t) => t.id.isIn(emailIds))).get();
    for (final row in rows) {
      await _updateThread(
        row.accountId,
        row.mailboxPath,
        row.threadId ?? row.id,
      );
    }
  }

  /// Refreshes the thread aggregate of row [emailId] in the folder it shows
  /// now.
  Future<void> _rethreadRow(String emailId) async {
    final row = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(emailId)))
        .getSingleOrNull();
    if (row == null) return;
    await _updateThread(row.accountId, row.mailboxPath, row.threadId ?? row.id);
  }

  /// After a read marked the rows [marked] (of [rows], as read before) gone
  /// on the server ([KeywordRead.markGone]): applies the clean-up rule
  /// ([EmailStateWriter.cleanUpGone], which deletes every gone row of
  /// [accountId] without a change left), refreshes the threads of the
  /// folders they were shown in, and logs each row kept because the user
  /// still has a change queued for it (App Log warn
  /// `email.server_gone_with_changes`): sync no longer deletes such a row,
  /// so the change stays visible until it applies or fails (#1239).
  Future<void> _settleGoneRows(
    String accountId,
    List<Email> rows,
    Set<String> marked,
  ) async {
    // A row whose acked move now waits for its destination copy, while
    // sync already stored that copy (the destination synced first): it
    // carries over at once instead of showing the mail twice.
    for (final row in rows) {
      if (!marked.contains(row.id)) continue;
      final dest = await _state.waitingDestinationOf(row.id);
      final mid = normaliseMessageId(row.messageId);
      if (dest == null || mid == null) continue;
      final copy =
          await _state.storedCopyIn(accountId, dest, mid, exceptId: row.id);
      if (copy != null) await _matchInPlace(row, copy.id, kind: 'moved');
    }
    final deleted = (await _state.cleanUpGone(accountId)).toSet();
    final kept = <(Email, List<PendingChangeRow>)>[];
    for (final row in rows) {
      if (!marked.contains(row.id)) continue;
      await _updateThread(accountId, row.mailboxPath, row.threadId ?? row.id);
      if (deleted.contains(row.id)) continue;
      final live = await _liveChanges(row.id);
      // The user's own delete for good: nothing to warn about.
      if (live.every((c) => c.changeType == 'delete')) continue;
      kept.add((row, live));
    }
    for (final (row, live) in kept) {
      unawaited(
        _appLogger?.warn(
          'email.server_gone_with_changes',
          'The server no longer has "${row.subject ?? '(no subject)'}" '
              '(was in ${row.srvMailboxPath ?? row.mailboxPath}); kept here '
              'while ${live.length} queued change(s) of it are applied or '
              'fail',
          accountId: accountId,
          emailId: row.id,
          mailboxPath: row.mailboxPath,
          data: {
            'changes': [for (final c in live) '#${c.id} ${c.changeType}'],
          },
        ),
      );
    }
  }

  /// Opportunistic backfill for address headers stored only since a later
  /// schema: Reply-To (#919), so mail cached before replies to the right
  /// address, and Bcc (#1097). Fills only empty columns, from the body's
  /// [headers] already at hand (fresh fetch or cache), so it costs no network
  /// round trip. [row] saves the lookup when the caller has it.
  Future<void> _backfillAddressHeaders(
    String emailId,
    List<model.EmailHeader> headers, {
    Email? row,
  }) async {
    const names = {'reply-to', 'bcc'};
    final relevant = [
      for (final h in headers)
        if (names.contains(h.name.toLowerCase())) h,
    ];
    if (relevant.isEmpty) return;
    final emailRow = row ??
        await (_db.select(_db.emails)..where((t) => t.id.equals(emailId)))
            .getSingleOrNull();
    if (emailRow == null) return;
    bool isEmpty(String stored) => stored.isEmpty || stored == '[]';
    if (!isEmpty(emailRow.replyToJson) && !isEmpty(emailRow.bccJson)) return;

    // Let enough_mail parse and RFC 2047-decode the raw header values.
    final msg = imap.MimeMessage.parseFromText(
      '${relevant.map((h) => '${h.name}: ${h.value}').join('\r\n')}\r\n\r\n',
    );
    String? decode(String stored, String header) {
      if (!isEmpty(stored)) return null;
      final addresses = msg.decodeHeaderMailAddressValue(header);
      if (addresses == null || addresses.isEmpty) return null;
      return _encodeAddresses(addresses);
    }

    final replyTo = decode(emailRow.replyToJson, 'Reply-To');
    final bcc = decode(emailRow.bccJson, 'Bcc');
    if (replyTo == null && bcc == null) return;
    await _state.writeHeaders(emailId, replyToJson: replyTo, bccJson: bcc);
  }

  /// Records the first time a server message is stored locally, so the
  /// per-message "Show Logs" view starts with the mail's own fetch (#920).
  void _logEmailFetched({
    required String emailId,
    required String accountId,
    required String mailboxPath,
    required String protocol,
    String? subject,
    int? bytes,
  }) {
    unawaited(
      _appLogger?.info(
        'email.fetched',
        'Fetched "${subject ?? '(no subject)'}" from the server '
            '(${protocol.toUpperCase()})',
        data: {
          'protocol': protocol,
          if (bytes != null) 'bytes': bytes,
        },
        accountId: accountId,
        mailboxPath: mailboxPath,
        emailId: emailId,
      ),
    );
  }

  /// Force resync of [accountId] (#1236), the mark of a mark-and-sweep
  /// (SYNC-REDESIGN.md §6 "Force resync"): nothing is deleted up front, so
  /// rows keep their ids, bodies, attachments and the references to them
  /// (Undo, notifications, drafts). The account's sync checkpoints are
  /// forgotten, except that each IMAP folder keeps its UIDVALIDITY with a
  /// "full fetch" mark ([_forceFullImapCheckpoints]: a changed UIDVALIDITY
  /// must still be seen), and on JMAP each folder gets a full sync due
  /// ([_markJmapFullSyncDue]). So the next sync of each folder is a
  /// complete refetch: it writes every row it finds through the
  /// server-write gate and then sweeps the folder, marking gone what its
  /// enumeration did not list (IMAP: the full fetch's
  /// [_SyncImap._reconcileDeletedImap]; JMAP: the prune after a complete
  /// full sync, else the periodic reconcile), and the clean-up rule deletes
  /// those without a change of the user's. Rows recorded in a folder the
  /// account no longer has are swept by [_sweepRowsOutsideFolders], once
  /// the folder list was read again.
  Future<void> _clearForResync(String accountId) async {
    // A queued change is un-pushed user intent and is never deleted here
    // (#558): it keeps folding over the refetched state.
    final account = await _accounts.getAccount(accountId);
    await _db.transaction(() async {
      final kept = await _forceFullImapCheckpoints(accountId);
      await (_db.delete(_db.syncStates)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) & t.resourceType.isNotIn(kept),
            ))
          .go();
      if (account?.type == account_model.AccountType.jmap) {
        await _markJmapFullSyncDue(accountId);
      }
    });
  }

  /// [_clearForResync] for one folder: its next sync is a complete refetch
  /// with the sweep. On JMAP a full sync is marked due: without a folder
  /// state, sync would otherwise adopt the account's global `Email` state
  /// and only ask for changes since then.
  Future<void> _clearMailboxForResync(
    String accountId,
    String mailboxPath,
  ) async {
    final account = await _accounts.getAccount(accountId);
    await _db.transaction(() async {
      await _forceFullImapCheckpoints(accountId, mailboxPath: mailboxPath);
      await (_db.delete(_db.syncStates)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  (t.resourceType.equals('JMAP:Email:$mailboxPath') |
                      t.resourceType.equals('JMAP:FullSync:$mailboxPath')),
            ))
          .go();
      if (account?.type == account_model.AccountType.jmap) {
        await _markJmapFullSyncDue(accountId, mailboxPath: mailboxPath);
      }
    });
  }

  /// Rewrites the IMAP checkpoints of [accountId] (of [mailboxPath] only,
  /// when given) to "full fetch due", keeping only their UIDVALIDITY: the
  /// next sync fetches the folder in full, and a UIDVALIDITY the server
  /// changed meanwhile still marks the folder's rows gone. A checkpoint
  /// without a UIDVALIDITY is dropped (the full fetch then marks gone the
  /// rows stamped with another one than the server's). Returns the
  /// resource types of the checkpoints kept.
  Future<Set<String>> _forceFullImapCheckpoints(
    String accountId, {
    String? mailboxPath,
  }) async {
    final rows = await (_db.select(_db.syncStates)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                (mailboxPath == null
                    ? t.resourceType.like('IMAP:%')
                    : t.resourceType.equals('IMAP:$mailboxPath')),
          ))
        .get();
    final kept = <String>{};
    for (final row in rows) {
      final Object? decoded;
      try {
        decoded = jsonDecode(row.state);
      } catch (_) {
        continue;
      }
      // Only the folder checkpoints (`IMAP:<path>`), not the flag
      // reconcile markers, which are no JSON objects.
      if (decoded is! Map<String, dynamic> ||
          !decoded.containsKey('uidValidity')) {
        continue;
      }
      final validity = decoded['uidValidity'];
      if (validity is! int || validity == 0) {
        await _clearSyncState(accountId, row.resourceType);
        continue;
      }
      await _saveSyncState(
        accountId,
        row.resourceType,
        jsonEncode({'uidValidity': validity, _forceFullKey: true}),
      );
      kept.add(row.resourceType);
    }
    return kept;
  }

  /// Marks a full sync due for every cached folder of JMAP account
  /// [accountId] ([mailboxPath] only, when given): an empty resume point,
  /// which keeps the folder on the full-sync path even when another
  /// folder's sync stores a state it could adopt.
  Future<void> _markJmapFullSyncDue(
    String accountId, {
    String? mailboxPath,
  }) async {
    final paths = mailboxPath != null
        ? [mailboxPath]
        : [
            for (final m in await (_db.select(_db.mailboxes)
                  ..where(
                    (t) =>
                        t.accountId.equals(accountId) & t.isLocal.equals(false),
                  ))
                .get())
              m.path,
          ];
    for (final path in paths) {
      await _saveSyncState(accountId, _jmapFullSyncKey(path), '{}');
    }
  }

  /// After a force resync of [accountId] read the folder list again: the
  /// rows recorded in a folder the account no longer has (not a mailbox
  /// row of it) are swept, as no folder's refetch reaches them. Skipped,
  /// with an App Log info line, when the account has no folder from the
  /// server at all: that is no listing, not an account without folders.
  Future<void> _sweepRowsOutsideFolders(String accountId) async {
    final anyFolder = await (_db.selectOnly(_db.mailboxes)
          ..addColumns([_db.mailboxes.id])
          ..where(
            _db.mailboxes.accountId.equals(accountId) &
                _db.mailboxes.isLocal.equals(false),
          )
          ..limit(1))
        .getSingleOrNull();
    if (anyFolder == null) {
      unawaited(
        _appLogger?.info(
          'sync.resync_sweep_skipped',
          'Force resync: no folder of this account is known from the '
              'server, so mail outside the known folders was not swept',
          accountId: accountId,
        ),
      );
      return;
    }
    final read = await _state.beginRead(accountId);
    final ids = [
      for (final r in await _db.customSelect(
        'SELECT id FROM emails WHERE account_id = ?1 AND is_local = 0 '
        'AND srv_gone = 0 AND srv_mailbox_path NOT IN '
        '(SELECT path FROM mailboxes WHERE account_id = ?1)',
        variables: [Variable.withString(accountId)],
        readsFrom: {_db.emails, _db.mailboxes},
      ).get())
        r.read<String>('id'),
    ];
    if (ids.isEmpty) return;
    final rows =
        await (_db.select(_db.emails)..where((t) => t.id.isIn(ids))).get();
    final marked = await read.markGone(ids);
    await _settleGoneRows(accountId, rows, marked);
    _logSwept(
      accountId,
      null,
      [
        for (final row in rows)
          if (marked.contains(row.id)) row,
      ],
    );
  }

  /// App Log warn `sync.resync_swept` for the rows [swept] a complete
  /// refetch of [mailboxPath] (a force resync, a UIDVALIDITY change, a JMAP
  /// full sync; null: of the account, for rows outside any folder) did not
  /// find: they vanish from the list, deleted at once or, with a change of
  /// the user's left, once it settles (`email.server_gone_with_changes`).
  void _logSwept(String accountId, String? mailboxPath, List<Email> swept) {
    if (swept.isEmpty) return;
    unawaited(
      _appLogger?.warn(
        'sync.resync_swept',
        '${swept.length} cached mail(s) '
            '${mailboxPath == null ? 'in folders this account no longer has' : 'of $mailboxPath'} '
            'were not found by a complete refetch and are removed (a mail '
            'with a queued change stays until the change is applied or '
            'fails)',
        accountId: accountId,
        mailboxPath: mailboxPath,
        data: {
          'emailIds': [for (final row in swept.take(100)) row.id],
          'subjects': [
            for (final row in swept.take(20)) row.subject ?? '(no subject)',
          ],
        },
      ),
    );
  }
}
