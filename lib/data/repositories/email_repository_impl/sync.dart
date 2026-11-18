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
    await _afterFolderSync(accountId, mailboxPath, started);
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
  Future<void> _afterFolderSync(
    String accountId,
    String mailboxPath,
    DateTime started,
  ) async {
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

  Future<void> _clearForResync(String accountId) async {
    // Disable FK constraints so EmailBodies rows survive the emails deletion.
    // When emails are re-inserted after the next sync with the same IDs, the
    // cached body content will be reused without a network round-trip.
    // The pragma is per connection: other statements that run until the
    // finally block are unchecked too.
    await _db.customStatement('PRAGMA foreign_keys = OFF');
    try {
      await _db.transaction(() async {
        // A row the user still has a change for stays (clean-up rule).
        await _state.deleteRowsOf(accountId);
        // NB: pending_changes are deliberately NOT deleted here. A queued
        // change (e.g. a just-starred mail whose \Flagged flag hasn't reached
        // the server yet) is un-pushed user intent — dropping it would let the
        // subsequent full re-fetch overwrite the local state with stale server
        // truth, losing the star (#558). The caller flushes pending changes
        // before clearing; anything still queued (offline) survives and is
        // retried on the next sync, its payload carrying the uid/id needed to
        // apply it even though the email row was deleted.
        await (_db.delete(
          _db.syncStates,
        )..where((t) => t.accountId.equals(accountId)))
            .go();
      });
    } finally {
      await _db.customStatement('PRAGMA foreign_keys = ON');
    }
  }

  Future<void> _clearMailboxForResync(
    String accountId,
    String mailboxPath,
  ) async {
    // Disable FK constraints so EmailBodies rows survive the emails deletion —
    // re-inserting emails with the same IDs after the next sync reuses the
    // cached body without a network round-trip. The pragma is per connection:
    // other statements that run until the finally block are unchecked too.
    await _db.customStatement('PRAGMA foreign_keys = OFF');
    try {
      await _db.transaction(() async {
        // NB: pending_changes are deliberately NOT deleted here. A queued
        // change (e.g. a just-starred mail whose \Flagged flag hasn't reached
        // the server yet) is un-pushed user intent — dropping it would let the
        // subsequent full re-fetch overwrite the local state with stale server
        // truth, losing the star (#558). The caller flushes pending changes
        // before clearing; anything still queued (offline) survives and is
        // retried on the next sync, its payload carrying the uid/id needed to
        // apply it even though the email row was deleted.
        // A row the user still has a change for stays (clean-up rule).
        await _state.deleteRowsOf(accountId, mailboxPath: mailboxPath);
        await (_db.delete(_db.threads)
              ..where(
                (t) =>
                    t.accountId.equals(accountId) &
                    t.mailboxPath.equals(mailboxPath),
              ))
            .go();
        // Reset this mailbox's sync checkpoint. Only the row matching the
        // account's protocol exists; deleting both variants is a no-op for the
        // other. The global 'Email' state is left intact.
        await (_db.delete(_db.syncStates)
              ..where(
                (t) =>
                    t.accountId.equals(accountId) &
                    (t.resourceType.equals('IMAP:$mailboxPath') |
                        t.resourceType.equals('JMAP:Email:$mailboxPath') |
                        t.resourceType.equals('JMAP:FullSync:$mailboxPath')),
              ))
            .go();
      });
    } finally {
      await _db.customStatement('PRAGMA foreign_keys = ON');
    }
  }
}
