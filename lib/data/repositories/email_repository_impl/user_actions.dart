part of '../email_repository_impl.dart';

// User actions: flags, mark all read, move, delete, snooze, wake up and
// restore. Each applies the optimistic local value and queues a change.

/// Zone key under which [EmailRepositoryImpl.deleteEmails] publishes its
/// [_BulkScope].
final _bulkScopeKey = Object();

/// State shared by every mutation running inside one bulk operation.
class _BulkScope {
  /// App Log writes deferred until the bulk transaction has committed.
  final logs = <Future<Object?>? Function()>[];

  /// Accounts that queued pending changes; each is kicked once at the end.
  final kickedAccounts = <String>{};

  /// Accounts already looked up during this operation.
  final accounts = <String, account_model.Account?>{};
}

/// Payload keys recording [row]'s snooze before a move/snooze/unsnooze
/// changes it, so [_ChangeFailures._revertFailedLocation] can bring it back if the change
/// fails. Empty when [row] is not snoozed.
Map<String, Object> _prevSnooze(Email row) {
  final until = row.snoozedUntil;
  if (until == null) return const {};
  final from = row.snoozedFromMailboxPath;
  return {
    'prevSnoozedUntil': until.toIso8601String(),
    if (from != null) 'prevSnoozedFrom': from,
  };
}

/// The Snoozed mailbox's name, and the stand-in path a snooze uses while
/// the folder is not known locally yet (the flush resolves or creates it).
const _snoozedPlaceholder = 'Snoozed';

/// Whether [mailboxPath] is the Snoozed folder at [snoozedPath], or the
/// literal `Snoozed` a snooze queued before that folder was known uses.
bool _isSnoozedPath(String mailboxPath, String snoozedPath) =>
    mailboxPath == snoozedPath || mailboxPath == _snoozedPlaceholder;

extension _UserActions on EmailRepositoryImpl {
  /// [setFlag] with an optional [source] recorded in the `email.flag` log
  /// entry (e.g. `sieve` when a local filter set the flag). Calls for the
  /// same [emailId] run one after another, in call order. Never call this
  /// inside `_db.transaction`: a queued outside call for the same id would
  /// wait on the transaction lock while the inner call waits on it.
  Future<void> _setFlag(
    String emailId, {
    bool? seen,
    bool? flagged,
    String? source,
  }) {
    final previous = _flagChains[emailId];
    final run = previous == null
        ? _setFlagNow(emailId, seen: seen, flagged: flagged, source: source)
        : previous.then(
            (_) => _setFlagNow(
              emailId,
              seen: seen,
              flagged: flagged,
              source: source,
            ),
          );
    // The chain tail swallows errors so one failed call does not fail the
    // next; the caller still gets this call's own error via [run].
    // Fire-and-forget callers (the auto-mark-read on open) no longer surface
    // the error to the zone because this handler is attached, so log it.
    final tail = run.then<void>(
      (_) {},
      onError: (Object e, StackTrace st) {
        log('setFlag($emailId) failed: $e');
        unawaited(
          _appLogger?.warn(
            'email.flag_failed',
            'Changing the read/star state failed',
            emailId: emailId,
            error: e,
            stack: st,
          ),
        );
      },
    );
    _flagChains[emailId] = tail;
    unawaited(
      tail.whenComplete(() {
        _flagChains.removeWhere((k, v) => k == emailId && identical(v, tail));
      }),
    );
    return run;
  }

  Future<void> _setFlagNow(
    String emailId, {
    bool? seen,
    bool? flagged,
    String? source,
  }) async {
    final row = await (_db.select(
      _db.emails,
    )..where((t) => t.id.equals(emailId)))
        .getSingleOrNull();
    if (row == null) return;

    // Reduce the request to only the flags that actually change. Callers such
    // as the detail-screen auto-mark-on-open (`lib/di.dart`) fire
    // `setFlag(id, seen: true)` on every open; without this guard an
    // already-read message would re-enqueue a `flag_seen` change (re-STORE on
    // the server) and re-emit an `email.flag` log entry on every open (#644).
    seen = (seen != null && seen != row.isSeen) ? seen : null;
    flagged = (flagged != null && flagged != row.isFlagged) ? flagged : null;
    if (seen == null && flagged == null) return;

    final account = (await _accounts.getAccount(row.accountId))!;

    if (account.type == account_model.AccountType.jmap) {
      if (seen != null) {
        await _enqueueChange(
          account.id,
          emailId,
          'flag_seen',
          jsonEncode({'seen': seen}),
        );
      }
      if (flagged != null) {
        await _enqueueChange(
          account.id,
          emailId,
          'flag_flagged',
          jsonEncode({'flagged': flagged}),
        );
      }
      // Optimistic local update.
      await (_db.update(_db.emails)..where((t) => t.id.equals(emailId))).write(
        EmailsCompanion(
          isSeen: seen != null ? Value(seen) : const Value.absent(),
          isFlagged: flagged != null ? Value(flagged) : const Value.absent(),
        ),
      );
      await _updateThread(
        row.accountId,
        row.mailboxPath,
        row.threadId ?? emailId,
      );
      _logFlag(row, account, seen: seen, flagged: flagged, source: source);
      return;
    }

    if (seen != null) {
      await _enqueueChange(
        account.id,
        emailId,
        'flag_seen',
        jsonEncode({
          'uid': row.uid,
          'mailboxPath': row.mailboxPath,
          'seen': seen,
        }),
      );
    }
    if (flagged != null) {
      await _enqueueChange(
        account.id,
        emailId,
        'flag_flagged',
        jsonEncode({
          'uid': row.uid,
          'mailboxPath': row.mailboxPath,
          'flagged': flagged,
        }),
      );
    }
    await (_db.update(_db.emails)..where((t) => t.id.equals(emailId))).write(
      EmailsCompanion(
        isSeen: seen != null ? Value(seen) : const Value.absent(),
        isFlagged: flagged != null ? Value(flagged) : const Value.absent(),
      ),
    );
    await _updateThread(
      row.accountId,
      row.mailboxPath,
      row.threadId ?? emailId,
    );
    _logFlag(row, account, seen: seen, flagged: flagged, source: source);
  }

  /// Writes a per-message `email.flag` log row so the read/unread/star change
  /// is discoverable in that message's "Show Logs" view (#562). No-op when
  /// neither flag was touched.
  void _logFlag(
    Email row,
    account_model.Account account, {
    bool? seen,
    bool? flagged,
    String? source,
  }) {
    if (seen == null && flagged == null) return;
    final parts = <String>[
      if (seen != null) seen ? 'read' : 'unread',
      if (flagged != null) flagged ? 'starred' : 'unstarred',
    ];
    unawaited(
      _appLogger?.info(
        'email.flag',
        'Marked "${row.subject ?? '(no subject)'}" ${parts.join(', ')}',
        emailId: row.id,
        accountId: row.accountId,
        mailboxPath: row.mailboxPath,
        data: {
          if (seen != null) 'seen': seen,
          if (flagged != null) 'flagged': flagged,
          'protocol': account.type.name,
          if (source != null) 'source': source,
        },
      ),
    );
  }

  Future<void> _markAllAsRead(String accountId, String mailboxPath) async {
    final account = (await _accounts.getAccount(accountId))!;
    final unread = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.mailboxPath.equals(mailboxPath) &
                t.isSeen.equals(false),
          ))
        .get();
    if (unread.isEmpty) return;

    await _db.transaction(() async {
      for (final row in unread) {
        if (account.type == account_model.AccountType.jmap) {
          await _enqueueChange(
            accountId,
            row.id,
            'flag_seen',
            jsonEncode({'seen': true}),
          );
        } else {
          await _enqueueChange(
            accountId,
            row.id,
            'flag_seen',
            jsonEncode({
              'uid': row.uid,
              'mailboxPath': row.mailboxPath,
              'seen': true,
            }),
          );
        }
      }

      // Bulk mark all unread emails in this mailbox as seen.
      await (_db.update(_db.emails)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.mailboxPath.equals(mailboxPath) &
                  t.isSeen.equals(false),
            ))
          .write(const EmailsCompanion(isSeen: Value(true)));

      // Update all threads in this mailbox to reflect no unread.
      await (_db.update(_db.threads)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.mailboxPath.equals(mailboxPath),
            ))
          .write(const ThreadsCompanion(hasUnread: Value(false)));
    });

    // Log per message (outside the transaction) so each affected mail shows the
    // read change in its own "Show Logs" view (#562).
    for (final row in unread) {
      unawaited(
        _appLogger?.info(
          'email.mark_read',
          'Marked "${row.subject ?? '(no subject)'}" read',
          emailId: row.id,
          accountId: accountId,
          mailboxPath: mailboxPath,
          data: {
            'seen': true,
            'bulk': true,
            'protocol': account.type.name,
          },
        ),
      );
    }
  }

  Future<void> _moveEmail(String emailId, String destMailboxPath) async {
    final row = await (_db.select(
      _db.emails,
    )..where((t) => t.id.equals(emailId)))
        .getSingleOrNull();
    if (row == null) return;
    if (row.mailboxPath == destMailboxPath) return;

    await _moveRow(row, destMailboxPath);
    await _mirrorMoveToCounterparts(
      row.accountId,
      row.messageId,
      destMailboxPath,
    );
  }

  /// Moves a single [row] to [destMailboxPath] on its own account: enqueues the
  /// protocol change and applies the optimistic local update. Does not mirror
  /// to counterpart accounts (see [_Counterparts._mirrorMoveToCounterparts]).
  Future<void> _moveRow(
    Email row,
    String destMailboxPath, {
    String event = 'email.move',
  }) async {
    if (row.mailboxPath == destMailboxPath) return;
    final emailId = row.id;
    final srcMailboxPath = row.mailboxPath;
    final account = (await _bulkAccount(row.accountId))!;
    // Filing a snoozed mail by hand ends the snooze: otherwise the wake-up
    // later pulls it back to the Inbox from wherever the user put it. The
    // flush also strips the server-side `snz:` keyword, which sync would
    // otherwise read back into `snoozedUntil`.
    final clearSnooze = row.snoozedUntil != null;

    if (account.type == account_model.AccountType.jmap) {
      await _enqueueChange(
        account.id,
        emailId,
        'move',
        jsonEncode({
          'src': srcMailboxPath,
          'dest': destMailboxPath,
          if (clearSnooze) 'clearSnooze': true,
          ..._prevSnooze(row),
        }),
      );
      // Optimistic: move the cached row so it disappears from the current
      // mailbox immediately and is visible in the destination mailbox.
      await _applyLocalMove(row, destMailboxPath);
    } else {
      await _enqueueChange(
        account.id,
        emailId,
        'move',
        jsonEncode({
          'uid': row.uid,
          'mailboxPath': srcMailboxPath,
          'dest': destMailboxPath,
          // Lets the flush re-resolve a stale UID (see
          // [_retryImapMoveByMessageId]) instead of silently no-op'ing (#1048).
          if (row.messageId != null) 'messageId': row.messageId,
          if (clearSnooze) 'clearSnooze': true,
          ..._prevSnooze(row),
        }),
      );
      // Optimistic: move the cached row locally instead of hard-deleting.
      await _applyLocalMove(row, destMailboxPath);
      // Destination UID will be updated when synced (IMAP move = delete + copy).
    }

    // Per-message log so the move (or trash/archive/spam, which are all moves)
    // shows up in this mail's "Show Logs" view (#562). The row keeps its id
    // when the MOVE is flushed (see [_remapEmailAfterImapMove]).
    _logAfterBulk(
      () => _appLogger?.info(
        event,
        'Moved "${row.subject ?? '(no subject)'}" '
        'from $srcMailboxPath to $destMailboxPath',
        emailId: emailId,
        accountId: row.accountId,
        mailboxPath: destMailboxPath,
        data: {
          'src': srcMailboxPath,
          'dest': destMailboxPath,
          'protocol': account.type.name,
          if (row.messageId != null) 'messageId': row.messageId,
        },
      ),
    );
  }

  /// The optimistic local part of a move of [row] to [destMailboxPath]: the
  /// row shows in the destination at once, its snooze ended. No change is
  /// queued here (see [_moveRow]).
  Future<void> _applyLocalMove(Email row, String destMailboxPath) async {
    await (_db.update(_db.emails)..where((t) => t.id.equals(row.id))).write(
      EmailsCompanion(
        mailboxPath: Value(destMailboxPath),
        snoozedUntil: const Value(null),
        snoozedFromMailboxPath: const Value(null),
      ),
    );
    await _reconcileSourceThreads(
      row.accountId,
      row.mailboxPath,
      row.id,
      row.threadId ?? row.id,
    );
    await _updateThread(row.accountId, destMailboxPath, row.threadId ?? row.id);
  }

  Future<String?> _deleteEmail(String emailId) async {
    final row = await (_db.select(
      _db.emails,
    )..where((t) => t.id.equals(emailId)))
        .getSingleOrNull();
    if (row == null) return null;

    final dest = await _deleteRow(row);
    await _mirrorDeleteToCounterparts(row.accountId, row.messageId);
    return dest;
  }

  Future<String?> _deleteEmails(List<String> emailIds) async {
    if (emailIds.isEmpty) return null;
    final fetched =
        await (_db.select(_db.emails)..where((t) => t.id.isIn(emailIds))).get();
    final byId = {for (final r in fetched) r.id: r};
    final rows = [
      for (final id in emailIds)
        if (byId[id] case final row?) row,
    ];
    if (rows.isEmpty) return null;

    // Resolve the counterpart accounts once per source account instead of
    // opening an `observeAccounts()` stream per message. This also has to
    // happen outside the transaction below: a `.watch()` query started inside
    // it would wait for the transaction to finish.
    final counterparts = <String, List<account_model.Account>>{};
    if (rows.any((r) => normaliseMessageId(r.messageId) != null)) {
      final all = await _accounts.observeAccounts().first;
      for (final source in all) {
        if (!rows.any((r) => r.accountId == source.id)) continue;
        counterparts[source.id] = AccountComparison.counterpartsOf(source, all);
      }
    }

    // Deleting one message used to cost a dozen separate implicit write
    // transactions, a sync-loop kick and a re-run of every live query; times
    // 80 that kept a bulk delete busy for a long time with no feedback (#917).
    // One transaction collapses all of it into a single commit, while the
    // bulk scope defers the per-message App Log rows and the sync kick until
    // after it.
    // Per-email-id mailbox each message was selected from, when the caller
    // provides it. A row that has since moved out of that mailbox is a stale
    // (duplicate) delete — e.g. an accidental second delete of a selection the
    // first call already moved to Trash — so skip it rather than hard-delete
    // it from Trash (#1010).
    final expectedMailbox =
        Zone.current[deleteExpectedMailboxZoneKey] as Map<String, String>?;
    final scope = _BulkScope();
    String? dest;
    await runZoned(
      () => _db.transaction(() async {
        // Ids already deleted in this batch — a selection can contain both
        // twins of a counterpart pair, and the second must not be deleted
        // again from its (now stale) source folder.
        final handled = <String>{};
        for (final row in rows) {
          if (!handled.add(row.id)) continue;
          final expected = expectedMailbox?[row.id];
          if (expected != null && expected != row.mailboxPath) continue;
          dest = await _deleteRow(row);
          final mid = normaliseMessageId(row.messageId);
          if (mid == null) continue;
          for (final counterpart in counterparts[row.accountId] ??
              const <account_model.Account>[]) {
            final twin = await _findEmailRowByNormalisedMessageId(
              counterpart.id,
              mid,
            );
            if (twin == null || !handled.add(twin.id)) continue;
            await _deleteRow(twin);
          }
        }
      }),
      zoneValues: {_bulkScopeKey: scope},
    );
    for (final write in scope.logs) {
      unawaited(write());
    }
    scope.kickedAccounts.forEach(_changeCtrl.add);
    return dest;
  }

  /// The [_BulkScope] of the [deleteEmails] call currently running in this
  /// zone, or null outside a bulk operation.
  _BulkScope? get _bulkScope => Zone.current[_bulkScopeKey] as _BulkScope?;

  /// [AccountRepository.getAccount], memoised for the duration of a bulk
  /// operation so a batch looks each account up once, not once per message.
  Future<account_model.Account?> _bulkAccount(String accountId) async {
    final bulk = _bulkScope;
    if (bulk == null) return _accounts.getAccount(accountId);
    if (bulk.accounts.containsKey(accountId)) return bulk.accounts[accountId];
    return bulk.accounts[accountId] = await _accounts.getAccount(accountId);
  }

  /// Writes an App Log row now, or — inside a bulk operation — once its
  /// transaction has committed. The logger writes to the same database, so an
  /// unawaited insert issued inside the transaction could outlive it.
  void _logAfterBulk(Future<Object?>? Function() write) {
    final bulk = _bulkScope;
    if (bulk != null) {
      bulk.logs.add(write);
      return;
    }
    unawaited(write());
  }

  /// Deletes a single [row] on its own account: moves it to that account's
  /// Trash when one exists (so the user can recover it), otherwise hard-deletes.
  /// Returns the Trash path when moved, or null when hard-deleted. Does not
  /// mirror to counterpart accounts (see [_Counterparts._mirrorDeleteToCounterparts]).
  Future<String?> _deleteRow(Email row) async {
    final emailId = row.id;
    final account = (await _bulkAccount(row.accountId))!;

    // Move to Trash when possible so the user can recover the message.
    final trashRow = await (_db.select(_db.mailboxes)
          ..where(
            (t) => t.accountId.equals(account.id) & t.role.equals('trash'),
          )
          ..limit(1))
        .getSingleOrNull();

    if (trashRow != null && trashRow.path != row.mailboxPath) {
      await _moveRow(row, trashRow.path, event: 'email.trash');
      return trashRow.path;
    }

    // Already in Trash or no Trash folder — hard delete. Record it so the
    // deletion still shows up in the global App Log even though the message
    // row (and any per-message view of it) is about to disappear (#562).
    _logAfterBulk(
      () => _appLogger?.info(
        'email.delete',
        'Permanently deleted "${row.subject ?? '(no subject)'}" '
            'from ${row.mailboxPath}',
        emailId: emailId,
        accountId: row.accountId,
        mailboxPath: row.mailboxPath,
        data: {
          'permanent': true,
          // The row's delete sets this entry's email_id to null (foreign
          // key), so keep which mail it was in the data.
          'emailId': emailId,
          'mailboxPath': row.mailboxPath,
          'protocol': account.type.name,
          if (row.messageId != null) 'messageId': row.messageId,
        },
      ),
    );

    if (account.type == account_model.AccountType.jmap) {
      await _enqueueChange(
        account.id,
        emailId,
        'delete',
        jsonEncode(<String, dynamic>{}),
      );
      await (_db.delete(_db.emails)..where((t) => t.id.equals(emailId))).go();
      await _updateThread(
        row.accountId,
        row.mailboxPath,
        row.threadId ?? emailId,
      );
      return null;
    }

    await _enqueueChange(
      account.id,
      emailId,
      'delete',
      jsonEncode({'uid': row.uid, 'mailboxPath': row.mailboxPath}),
    );
    await (_db.delete(_db.emails)..where((t) => t.id.equals(emailId))).go();
    await _updateThread(
      row.accountId,
      row.mailboxPath,
      row.threadId ?? emailId,
    );
    return null;
  }

  Future<void> _snoozeEmail(String emailId, DateTime until) async {
    final row = await (_db.select(
      _db.emails,
    )..where((t) => t.id.equals(emailId)))
        .getSingleOrNull();
    if (row == null) {
      // The row can disappear between opening the snooze picker and
      // confirming (concurrent sync move/delete, optimistic move that
      // reassigned the id). Degrade to a no-op instead of crashing.
      log('snoozeEmail: email $emailId no longer exists; skipping');
      return;
    }
    await _snoozeRow(row, until);
    await _mirrorSnoozeToCounterparts(
      row.accountId,
      row.messageId,
      until: until,
    );
  }

  /// Snoozes a single [row] on its own account: moves it to that account's
  /// Snoozed mailbox, records [until] locally and enqueues the protocol change.
  Future<void> _snoozeRow(Email row, DateTime until) async {
    final accountId = row.accountId;
    final destPath = await _snoozedMailboxPath(accountId);

    // A queued keyword cleanup from an earlier stale snooze would strip the
    // keyword this snooze is about to add.
    await (_db.delete(_db.pendingChanges)
          ..where(
            (t) =>
                t.resourceId.equals(row.id) &
                t.changeType.equals('clear_snooze'),
          ))
        .go();

    // Optimistic local update.
    await _applyLocalSnooze(row, destPath, until);

    await _enqueueChange(
      accountId,
      row.id,
      'snooze',
      jsonEncode({
        'uid': row.uid,
        'src': row.mailboxPath,
        'dest': destPath,
        'until': until.toIso8601String(),
        // Lets the IMAP flush re-find a stale UID by Message-ID, as a move
        // does (#1048).
        if (row.messageId != null) 'messageId': row.messageId,
        ..._prevSnooze(row),
      }),
    );

    unawaited(
      _appLogger?.info(
        'email.snooze',
        'Snoozed "${row.subject ?? '(no subject)'}" until '
            '${until.toIso8601String()}',
        emailId: row.id,
        accountId: accountId,
        mailboxPath: destPath,
        data: {
          'src': row.mailboxPath,
          'dest': destPath,
          'until': until.toIso8601String(),
          if (row.messageId != null) 'messageId': row.messageId,
        },
      ),
    );
  }

  /// The optimistic local part of snoozing [row] into [destPath] until
  /// [until]. No change is queued here (see [_snoozeRow]).
  Future<void> _applyLocalSnooze(
    Email row,
    String destPath,
    DateTime until,
  ) async {
    await (_db.update(_db.emails)..where((t) => t.id.equals(row.id))).write(
      EmailsCompanion(
        mailboxPath: Value(destPath),
        snoozedUntil: Value(until),
        snoozedFromMailboxPath: Value(row.mailboxPath),
      ),
    );
    await _updateThread(
      row.accountId,
      row.mailboxPath,
      row.threadId ?? row.id,
    );
    await _updateThread(row.accountId, destPath, row.threadId ?? row.id);
  }

  /// The path of [accountId]'s Snoozed mailbox (by role, then by name), or
  /// the literal `Snoozed` when it is not known locally yet — the snooze flush
  /// creates it on the server.
  Future<String> _snoozedMailboxPath(String accountId) async {
    var snoozedMailbox = await (_db.select(_db.mailboxes)
          ..where(
            (t) => t.accountId.equals(accountId) & t.role.equals('snoozed'),
          )
          ..limit(1))
        .getSingleOrNull();

    snoozedMailbox ??= await (_db.select(_db.mailboxes)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.name.equals(_snoozedPlaceholder),
          )
          ..limit(1))
        .getSingleOrNull();

    return snoozedMailbox?.path ?? _snoozedPlaceholder;
  }

  Future<int> _wakeUpEmails(String accountId) async {
    final now = DateTime.now();
    final expired = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.snoozedUntil.isSmallerOrEqualValue(now),
          ))
        .get();

    if (expired.isEmpty) return 0;

    final snoozedPath = await _snoozedMailboxPath(accountId);
    // A mail whose move/snooze/unsnooze failed waits for the user's Retry or
    // Discard: waking it would queue a change that fails the same way on
    // every cycle.
    final failedIds = (await (_db.selectOnly(_db.pendingChanges)
              ..addColumns([_db.pendingChanges.resourceId])
              ..where(
                _db.pendingChanges.accountId.equals(accountId) &
                    _db.pendingChanges.state.equals(_failedState) &
                    _db.pendingChanges.changeType.isIn(_locationChangeTypes),
              ))
            .map((r) => r.read(_db.pendingChanges.resourceId)!)
            .get())
        .toSet();
    var woken = 0;
    for (final row in expired) {
      if (failedIds.contains(row.id)) continue;
      // Only a mail still waiting in the Snoozed folder goes back to the
      // Inbox. One the user (or another client) filed elsewhere since keeps
      // its place; its stale snooze is dropped, and so is the server-side
      // `snz:` keyword sync would otherwise keep reading back.
      if (!_isSnoozedPath(row.mailboxPath, snoozedPath)) {
        await (_db.update(_db.emails)..where((t) => t.id.equals(row.id))).write(
          const EmailsCompanion(
            snoozedUntil: Value(null),
            snoozedFromMailboxPath: Value(null),
          ),
        );
        await _enqueueChange(
          accountId,
          row.id,
          'clear_snooze',
          jsonEncode({'uid': row.uid, 'mailboxPath': row.mailboxPath}),
        );
        continue;
      }
      await _unsnoozeRow(row);
      await _mirrorSnoozeToCounterparts(
        row.accountId,
        row.messageId,
        until: null,
      );
      woken++;
    }
    return woken;
  }

  Future<void> _restoreLocalSnooze(
    String emailId, {
    required DateTime until,
    String? fromMailboxPath,
  }) async {
    await (_db.update(_db.emails)..where((t) => t.id.equals(emailId))).write(
      EmailsCompanion(
        snoozedUntil: Value(until),
        snoozedFromMailboxPath: Value(fromMailboxPath),
      ),
    );
  }

  /// Un-snoozes a single [row] on its own account: moves it back to that
  /// account's Inbox, clears the snooze columns and enqueues the change.
  Future<void> _unsnoozeRow(Email row) async {
    final accountId = row.accountId;

    // Per instructions: "get to inbox moved by app".
    final inbox = await (_db.select(_db.mailboxes)
          ..where(
            (t) => t.accountId.equals(accountId) & t.role.equals('inbox'),
          )
          ..limit(1))
        .getSingleOrNull();
    final dest = inbox?.path ?? 'INBOX';

    await _enqueueChange(
      accountId,
      row.id,
      'unsnooze',
      jsonEncode({
        'uid': row.uid,
        'src': row.mailboxPath,
        'dest': dest,
        ..._prevSnooze(row),
      }),
    );

    // Optimistic local update.
    await _applyLocalUnsnooze(row, dest);

    unawaited(
      _appLogger?.info(
        'email.unsnooze',
        'Un-snoozed "${row.subject ?? '(no subject)'}" back to $dest',
        emailId: row.id,
        accountId: accountId,
        mailboxPath: dest,
        data: {
          'src': row.mailboxPath,
          'dest': dest,
          if (row.messageId != null) 'messageId': row.messageId,
        },
      ),
    );
  }

  /// The optimistic local part of un-snoozing [row] back to [dest]. No change
  /// is queued here (see [_unsnoozeRow]).
  Future<void> _applyLocalUnsnooze(Email row, String dest) async {
    await (_db.update(_db.emails)..where((t) => t.id.equals(row.id))).write(
      EmailsCompanion(
        mailboxPath: Value(dest),
        snoozedUntil: const Value(null),
        snoozedFromMailboxPath: const Value(null),
      ),
    );
    await _updateThread(
      row.accountId,
      row.mailboxPath,
      row.threadId ?? row.id,
    );
    await _updateThread(row.accountId, dest, row.threadId ?? row.id);
  }

  Future<void> _restoreEmails(List<model.Email> emails) async {
    for (final e in emails) {
      // One transaction: a sync storing the mail meanwhile must not take
      // the location between the check and the write.
      await _db.transaction(() => _restoreEmail(e));
    }
  }

  /// [restoreEmails] for one row, with the snapshot's server location
  /// unless another row holds it by now (a sync stored the mail again
  /// meanwhile): one location, one row. Schema v71 completed the snapshots
  /// taken before v70, which had none.
  Future<void> _restoreEmail(model.Email e) async {
    var srvPath = e.srvMailboxPath;
    var srvUid = e.srvUid;
    final srvJmapId = e.srvJmapId;
    if (srvPath != null && srvUid != null) {
      final path = srvPath;
      final uid = srvUid;
      final validity = e.srvUidValidity;
      // A snapshot without a UIDVALIDITY yields to a row at that folder
      // and UID under any UIDVALIDITY: which one is newer is unknown.
      final holder = validity == null
          ? await (_db.select(_db.emails)
                ..where(
                  (t) =>
                      t.accountId.equals(e.accountId) &
                      t.srvMailboxPath.equals(path) &
                      t.srvUid.equals(uid) &
                      t.id.equals(e.id).not(),
                )
                ..limit(1))
              .getSingleOrNull()
          : await _rowAtImapLocation(
              e.accountId,
              path,
              uid,
              uidValidity: validity,
              exceptId: e.id,
            );
      if (holder != null) {
        srvPath = null;
        srvUid = null;
      }
    }
    if (srvJmapId != null) {
      final holder = await _rowByJmapId(e.accountId, srvJmapId);
      // A JMAP id names one mail of the account: sync stored it again
      // meanwhile, so it is back already. A second row without a server id
      // could never be synced or changed on the server.
      if (holder != null && holder.id != e.id) {
        log('restoreEmails: ${e.id} is back as ${holder.id} already');
        return;
      }
    }
    final imapKnown = srvPath != null && srvUid != null;
    await _db.into(_db.emails).insertOnConflictUpdate(
          EmailsCompanion.insert(
            id: e.id,
            accountId: e.accountId,
            mailboxPath: e.mailboxPath,
            uid: e.uid,
            subject: Value(e.subject),
            sentAt: Value(e.sentAt),
            receivedAt: e.receivedAt,
            fromJson: Value(jsonEncode(e.from)),
            toAddresses: Value(jsonEncode(e.to)),
            ccJson: Value(jsonEncode(e.cc)),
            replyToJson: Value(jsonEncode(e.replyTo)),
            bccJson: Value(jsonEncode(e.bcc)),
            sizeBytes: Value(e.size),
            preview: Value(e.preview),
            isSeen: Value(e.isSeen),
            isFlagged: Value(e.isFlagged),
            hasAttachment: Value(e.hasAttachment),
            threadId: Value(e.threadId),
            messageId: Value(e.messageId),
            inReplyTo: Value(e.inReplyTo),
            references: Value(e.references),
            snoozedUntil: Value(e.snoozedUntil),
            snoozedFromMailboxPath: Value(e.snoozedFromMailboxPath),
            isLocal: Value(e.isLocal),
            isVirtualSentCopy: Value(e.isVirtualSentCopy),
            srvMailboxPath: imapKnown ? Value(srvPath) : const Value.absent(),
            srvUid: imapKnown ? Value(srvUid) : const Value.absent(),
            srvUidValidity:
                imapKnown ? Value(e.srvUidValidity) : const Value.absent(),
            srvJmapId:
                srvJmapId != null ? Value(srvJmapId) : const Value.absent(),
          ),
        );
    await _updateThread(e.accountId, e.mailboxPath, e.threadId ?? e.id);
  }
}
