part of '../email_repository_impl.dart';

// Settling failed changes: recording errors, marking changes stuck or
// failed, and reverting the optimistic values of failed flag and location
// changes.

/// Sync-state key that makes the periodic flag reconcile of [folder] (an
/// IMAP path, or a JMAP mailbox id) run at its next chance. Separate from
/// the reconcile's own timestamp, so a reconcile already running cannot
/// overwrite it; see [_ChangeFailures._settleFlagReconcileDue] for when it is cleared.
String _flagReconcileDueKey(String folder, {required bool jmap}) =>
    jmap ? 'JMAP:ReconcileDue:$folder' : 'IMAP:FlagReconcileDue:$folder';

/// Change types that change where a mail is.
const _locationChangeTypes = ['move', 'snooze', 'unsnooze'];

/// Change types that change where a mail is, or whether it exists: a later
/// one of these depends on an earlier one for the same mail having applied.
const _placementChangeTypes = [..._locationChangeTypes, 'delete'];

extension _ChangeFailures on EmailRepositoryImpl {
  // ── Pending-change helpers ────────────────────────────────────────────────

  /// Records a failure that may pass for [row]: increments the attempt
  /// count and stores the error message. From [_maxChangeAttempts] attempts
  /// on the row is [_stuckState]: still protecting the user's local value,
  /// retried after [_stuckBackoff]. A refusal that retrying cannot fix goes
  /// through [_markChangeFailed] instead.
  Future<void> _recordChangeError(PendingChangeRow row, Object error) async {
    final next = row.attempts + 1;
    final gaveUp = next >= _maxChangeAttempts;
    final nextTry = gaveUp ? _now().add(_stuckBackoff(next)) : null;
    var owned = false;
    await _db.transaction(() async {
      final count = await (_db.update(_db.pendingChanges)
            ..where((t) => _ownsClaim(t, row)))
          .write(
        PendingChangesCompanion(
          attempts: Value(next),
          lastError: Value(error.toString()),
          state: Value(gaveUp ? _stuckState : _pendingState),
          leaseUntil: Value(nextTry),
          claimToken: const Value(null),
        ),
      );
      owned = count > 0;
    });
    if (!owned) {
      log('Pending change ${row.id}: claim lost meanwhile, outcome dropped');
      return;
    }

    // Mirror the failure into the App Log so a failed delete/move/flag is
    // discoverable in the per-message "Show Logs" view and in bug reports —
    // previously it was only written to `pending_changes.lastError` and stayed
    // silent (#579), unlike the outbox path (see [_outboxLogObserver]).
    final data = <String, Object?>{
      'changeType': row.changeType,
      'attempts': next,
      'maxAttempts': _maxChangeAttempts,
    };
    if (gaveUp) {
      unawaited(
        _appLogger?.warn(
          'pending_change.stuck',
          'Could not apply ${_describeChange(row)} after $next attempts; '
              'not synced yet, next try at ${_hhmm(nextTry!)}',
          accountId: row.accountId,
          emailId: row.resourceId,
          data: data,
          error: error,
        ),
      );
    } else {
      unawaited(
        _appLogger?.warn(
          'pending_change.retry',
          'Could not apply ${_describeChange(row)} — will retry '
              '(attempt $next of $_maxChangeAttempts)',
          accountId: row.accountId,
          emailId: row.resourceId,
          data: data,
          error: error,
        ),
      );
    }
  }

  /// Marks a claimed [row] [_failedState] at once, without further retries:
  /// the server refused it, or the message it names is gone. Keeps the row
  /// (with [error] and the claimed attempt) for the user to retry or discard.
  /// With [revert], a move's optimistic location is undone as well
  /// ([_revertFailedLocation]); pass false when the message is gone and there
  /// is nothing to go back to.
  Future<bool> _markChangeFailed(
    PendingChangeRow row,
    Object error, {
    bool revert = true,
  }) async {
    final dependents = await _db.transaction(
      () => _markChangeFailedInTransaction(row, error, revert: revert),
    );
    if (dependents == null) return false;
    _logDependentFailures(row, dependents);
    return true;
  }

  /// The database part of [_markChangeFailed], for a caller that runs it in
  /// its own transaction: returns the dependents, to log with
  /// [_logDependentFailures] once that transaction has committed, or null
  /// when the flush no longer owns the claim (nothing written then).
  Future<List<PendingChangeRow>?> _markChangeFailedInTransaction(
    PendingChangeRow row,
    Object error, {
    required bool revert,
  }) async {
    final count = await (_db.update(_db.pendingChanges)
          ..where((t) => _ownsClaim(t, row)))
        .write(
      PendingChangesCompanion(
        attempts: Value(row.attempts + 1),
        lastError: Value(error.toString()),
        state: const Value(_failedState),
        leaseUntil: const Value(null),
        claimToken: const Value(null),
      ),
    );
    if (count == 0) {
      log('Pending change ${row.id}: claim lost meanwhile, outcome dropped');
      return null;
    }
    await _afterFlagFailure(row, revert: revert);
    return _afterLocationFailure(row, revert: revert);
  }

  /// Called (inside the transaction that marked [row] failed) when a read or
  /// star change just became failed: it no longer protects the optimistic
  /// value (#1264), but an unchanged mail is read again only by the
  /// 15-minute flag reconcile (with IMAP CONDSTORE, and always with JMAP),
  /// so the app would show the user's value as if it had applied (#1270).
  ///
  /// Makes the flag reconcile of the mail's folder due, so the next sync
  /// reads server truth, and with [revert] also puts the flag back at once
  /// to its value before the change: the opposite of the requested one,
  /// queued only when the shown value differed. That guess is skipped when
  /// another change of the same flag exists (see below) or something else
  /// already changed the flag; the reconcile sets it right then. A failure
  /// here is logged and rolled back on its own, never taking the failed
  /// state with it.
  Future<void> _afterFlagFailure(
    PendingChangeRow row, {
    required bool revert,
  }) async {
    if (row.changeType != 'flag_seen' && row.changeType != 'flag_flagged') {
      return;
    }
    try {
      await _db.transaction(() => _revertFailedFlag(row, revert: revert));
    } catch (e) {
      log('Could not revert failed change ${row.id}: $e');
    }
  }

  Future<void> _revertFailedFlag(
    PendingChangeRow row, {
    required bool revert,
  }) async {
    final key = row.changeType == 'flag_seen' ? 'seen' : 'flagged';
    final payload = _decodePayload(row);
    final email = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(row.resourceId)))
        .getSingleOrNull();
    final account = await _accounts.getAccount(row.accountId);
    if (account == null) return;
    final jmap = account.type == account_model.AccountType.jmap;
    // The folder the mail is shown in, and for IMAP the one the change
    // addressed (they differ behind a queued move).
    final addressed = jmap ? null : payload?['mailboxPath'];
    for (final folder in {
      if (email != null) email.mailboxPath,
      if (addressed is String) addressed,
    }) {
      await _makeFlagReconcileDue(row.accountId, folder, jmap: jmap);
    }
    if (!revert || email == null || !_sameMessage(row, email.messageId)) {
      return;
    }
    final wanted = payload?[key];
    if (wanted is! bool) return;
    // The value before [row] is known only when no other change of this
    // flag is queued: a later pending one owns the local value, and after
    // an earlier one (pending or failed) the shown value was never server
    // truth.
    final other = await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.resourceId.equals(row.resourceId) &
                t.id.equals(row.id).not() &
                t.changeType.equals(row.changeType) &
                (t.id.isSmallerThanValue(row.id) | t.state.isIn(_liveStates)),
          )
          ..limit(1))
        .getSingleOrNull();
    if (other != null) return;
    final current = key == 'seen' ? email.isSeen : email.isFlagged;
    if (current != wanted) return;
    await (_db.update(_db.emails)..where((t) => t.id.equals(email.id))).write(
      EmailsCompanion(
        isSeen: key == 'seen' ? Value(!wanted) : const Value.absent(),
        isFlagged: key == 'flagged' ? Value(!wanted) : const Value.absent(),
      ),
    );
    await _updateThread(
      email.accountId,
      email.mailboxPath,
      email.threadId ?? email.id,
    );
  }

  Future<void> _makeFlagReconcileDue(
    String accountId,
    String folder, {
    required bool jmap,
  }) =>
      _saveSyncState(
        accountId,
        _flagReconcileDueKey(folder, jmap: jmap),
        DateTime.now().toIso8601String(),
      );

  /// Called after a flag reconcile of [folder] that ran to the end, with
  /// [dueValue], the due marker as it was when the pass started. Clears the
  /// marker unless it was set again since (a change failed during the pass),
  /// or the pass had to skip a mail with a failed read/star change because
  /// another change of that mail is still queued: then the next sync tries
  /// again. A pass that throws leaves the marker alone.
  Future<void> _settleFlagReconcileDue(
    String accountId,
    String folder, {
    required bool jmap,
    required String? dueValue,
  }) async {
    if (dueValue == null) return;
    final inFlight = await _inFlightFlagResourceIds(accountId);
    if (inFlight.isNotEmpty) {
      final failedFlags = await (_db.select(_db.pendingChanges)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.state.equals(_failedState) &
                  t.changeType.isIn(const ['flag_seen', 'flag_flagged']) &
                  t.resourceId.isIn(inFlight),
            ))
          .get();
      if (failedFlags.isNotEmpty) {
        final skipped = await (_db.select(_db.emails)
              ..where(
                (t) =>
                    t.id.isIn([for (final c in failedFlags) c.resourceId]) &
                    t.mailboxPath.equals(folder),
              )
              ..limit(1))
            .getSingleOrNull();
        if (skipped != null) return;
      }
    }
    await (_db.delete(_db.syncStates)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.resourceType
                    .equals(_flagReconcileDueKey(folder, jmap: jmap)) &
                t.state.equals(dueValue),
          ))
        .go();
  }

  /// Called (inside the transaction that marked [row] failed) when a change
  /// just became failed. If [row] moves or deletes the mail, the mail's later
  /// queued moves/snoozes/unsnoozes/deletes depended on it — they address the
  /// mail where [row] would have put it — so they are marked failed too
  /// (`depends on failed change #id`, nothing reverted for them). Then, with
  /// [revert], [row]'s optimistic location is undone
  /// ([_revertFailedLocation]); a revert that throws is logged and rolled
  /// back on its own, never taking the failed state with it. Returns the
  /// dependents, for [_logDependentFailures] once the transaction is done.
  Future<List<PendingChangeRow>> _afterLocationFailure(
    PendingChangeRow row, {
    required bool revert,
  }) async {
    if (!_placementChangeTypes.contains(row.changeType)) return const [];
    final dependents = await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.resourceId.equals(row.resourceId) &
                t.state.isIn(const [_pendingState, _stuckState]) &
                t.id.isBiggerThanValue(row.id) &
                t.changeType.isIn(_placementChangeTypes),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();
    for (final dependent in dependents) {
      await (_db.update(_db.pendingChanges)
            ..where((t) => t.id.equals(dependent.id)))
          .write(
        PendingChangesCompanion(
          lastError: Value('depends on failed change #${row.id}'),
          state: const Value(_failedState),
        ),
      );
    }
    if (!revert) return dependents;
    try {
      await _db.transaction(() => _revertFailedLocation(row, dependents));
    } catch (e) {
      log('Could not revert failed change ${row.id}: $e');
    }
    return dependents;
  }

  /// Drops the local row of [failed], a move whose message is in neither
  /// its source nor its destination folder (another client deleted it or
  /// moved it elsewhere), or whose source folder is gone. The row sits in the destination with its source
  /// UID, so there it would name whichever mail has that UID: sync would
  /// copy that mail's flags onto it, and the user's changes would act on
  /// it (#1268). If the mail is in a third folder, sync shows it there.
  /// The failed change itself stays on the Pending Changes screen; changes
  /// queued behind it find no mail and fail there too. Returns the dropped
  /// row, or null; the caller logs it with [_logGoneRowDropped] once the
  /// transaction has committed.
  Future<Email?> _dropGoneRow(PendingChangeRow failed) async {
    if (!_locationChangeTypes.contains(failed.changeType)) return null;
    final email = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(failed.resourceId)))
        .getSingleOrNull();
    if (email == null || !_sameMessage(failed, email.messageId)) return null;
    await (_db.delete(_db.emails)..where((t) => t.id.equals(email.id))).go();
    await _updateThread(
      email.accountId,
      email.mailboxPath,
      email.threadId ?? email.id,
    );
    return email;
  }

  /// App Log line for a row [_dropGoneRow] removed: the mail vanishes from
  /// the list, so the user must be able to find out why.
  /// [why] says what happened, e.g. "a failed move: the message is in
  /// neither its source nor its destination folder on the server".
  void _logGoneRowDropped(
    PendingChangeRow failed,
    Email? dropped, {
    required String why,
  }) {
    if (dropped == null) return;
    unawaited(
      _appLogger?.warn(
        'pending_change.local_row_removed',
        'Removed "${dropped.subject ?? '(no subject)'}" from '
            '${dropped.mailboxPath} on this device after $why; if another '
            'client moved it, it shows up there on the next sync',
        accountId: dropped.accountId,
        mailboxPath: dropped.mailboxPath,
        // The row is gone; a log row must not reference it.
        data: {
          'changeType': failed.changeType,
          'removedEmailId': dropped.id,
          'messageId': dropped.messageId,
        },
      ),
    );
  }

  /// App Log warnings for the [dependents] failed together with [row].
  void _logDependentFailures(
    PendingChangeRow row,
    List<PendingChangeRow> dependents,
  ) {
    for (final dependent in dependents) {
      unawaited(
        _appLogger?.warn(
          'pending_change.dependent_failed',
          'Could not apply ${_describeChange(dependent)} — it depends on a '
              'failed ${_describeChange(row)}; kept on the Pending Changes '
              'screen',
          accountId: dependent.accountId,
          emailId: dependent.resourceId,
          data: {'changeType': dependent.changeType, 'dependsOn': row.id},
        ),
      );
    }
  }

  /// Undoes the optimistic local part of [row], a move/snooze/unsnooze that
  /// just failed, together with its [dependents] (the later location changes
  /// for the mail that were failed with it): the mail goes back to [row]'s
  /// source folder with its earlier snooze state, so the app shows where it
  /// really is on the server. IMAP changes queued after it for the same mail
  /// that address it where those changes put it are pointed back at the
  /// source too ([_pointLaterChangesAtSource]).
  ///
  /// Does nothing when the mail is no longer where the last of these changes
  /// put it (e.g. a dependent delete removed the row), when the IMAP row does
  /// not name [row]'s source UID, or when the source folder was renumbered
  /// since [row] was queued.
  Future<void> _revertFailedLocation(
    PendingChangeRow row,
    List<PendingChangeRow> dependents,
  ) async {
    if (!_locationChangeTypes.contains(row.changeType)) return;
    final payload = _decodePayload(row);
    if (payload == null) return;
    final src = payload['mailboxPath'] ?? payload['src'];
    final dest = payload['dest'];
    if (src is! String || dest is! String) return;
    // Every place the mail was shown in along the way, the last one being
    // where it should be now.
    final shownIn = [dest];
    for (final dependent in dependents) {
      if (dependent.changeType == 'delete') return;
      final later = _decodePayload(dependent)?['dest'];
      if (later is String) shownIn.add(later);
    }
    final email = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(row.resourceId)))
        .getSingleOrNull();
    if (email == null) return;
    if (!await _isAtLocation(email, shownIn.last)) return;
    final account = await _accounts.getAccount(row.accountId);
    if (account == null) return;
    final isImap = account.type == account_model.AccountType.imap;
    final uid = payload['uid'];
    if (isImap &&
        (email.uid != uid ||
            email.srvMailboxPath != src ||
            email.srvUid != uid)) {
      return;
    }
    if (isImap && !await _stampStillValid(row.accountId, src, payload)) return;

    // A snooze is undone to the snooze state from before it (none, or the
    // earlier one of a re-snooze); a move or unsnooze that ended a snooze
    // brings that snooze back.
    final prevUntil = DateTime.tryParse(
      payload['prevSnoozedUntil'] as String? ?? '',
    );
    final prevFrom = payload['prevSnoozedFrom'] as String?;
    final target = await _resolveSnoozedPlaceholder(row.accountId, src);
    await (_db.update(_db.emails)..where((t) => t.id.equals(email.id))).write(
      EmailsCompanion(
        mailboxPath: Value(target),
        snoozedUntil: Value(prevUntil),
        snoozedFromMailboxPath: Value(prevUntil == null ? null : prevFrom),
      ),
    );
    if (isImap) {
      await _pointLaterChangesAtSource(
        row,
        payload: payload,
        email: email,
        src: src,
        shownIn: shownIn,
      );
    }
    final threadId = email.threadId ?? email.id;
    await _reconcileSourceThreads(
      row.accountId,
      email.mailboxPath,
      email.id,
      threadId,
    );
    await _updateThread(row.accountId, target, threadId);
    // Read/star changes made while the mail was shown elsewhere may have
    // failed as well, and the reconcile they made due was for that folder.
    await _makeFlagReconcileDue(row.accountId, target, jmap: !isImap);
    log(
      'Pending change ${row.id} failed: ${email.id} back in $target '
      '(was shown in ${email.mailboxPath})',
    );
  }

  /// Whether the UIDVALIDITY stamped on an IMAP change [payload] for [src]
  /// still matches [src]'s sync checkpoint: only then does its UID still name
  /// the same message there. True when either is unknown.
  Future<bool> _stampStillValid(
    String accountId,
    String src,
    Map<String, dynamic> payload,
  ) async {
    final stamped = payload['uidValidity'];
    if (stamped is! int) return true;
    final checkpoint = await _loadImapCheckpoint(accountId, 'IMAP:$src');
    final current = checkpoint?['uidValidity'];
    if (current is! int || current == 0) return true;
    return current == stamped;
  }

  /// [path], with the `Snoozed` placeholder a snooze queued before the
  /// folder was known replaced by [accountId]'s real Snoozed folder.
  Future<String> _resolveSnoozedPlaceholder(
    String accountId,
    String path,
  ) async {
    if (path != _snoozedPlaceholder) return path;
    return _snoozedMailboxPath(accountId);
  }

  /// Whether [email] is in [mailboxPath], counting the Snoozed folder and the
  /// `Snoozed` placeholder a snooze queued before it was known as the same.
  Future<bool> _isAtLocation(Email email, String mailboxPath) async {
    if (email.mailboxPath == mailboxPath) return true;
    final snoozedPath = await _snoozedMailboxPath(email.accountId);
    return _isSnoozedPath(email.mailboxPath, snoozedPath) &&
        _isSnoozedPath(mailboxPath, snoozedPath);
  }

  /// Points the IMAP payloads of the other changes queued after [failed] for
  /// [email] that address it in one of the folders it was [shownIn] back at
  /// [src], after [failed] was undone. They get [failed]'s own UIDVALIDITY
  /// stamp and Message-ID ([payload]): its source UID is valid only under
  /// that stamp, so a change is left as it is when [src] was renumbered
  /// since ([_stampStillValid]; the caller checks this before reverting).
  Future<void> _pointLaterChangesAtSource(
    PendingChangeRow failed, {
    required Map<String, dynamic> payload,
    required Email email,
    required String src,
    required List<String> shownIn,
  }) async {
    final later = await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.resourceId.equals(failed.resourceId) &
                t.state.isIn(_liveStates) &
                t.id.isBiggerThanValue(failed.id) &
                t.changeType.isNotIn(_placementChangeTypes),
          ))
        .get();
    final paths = {email.mailboxPath, ...shownIn};
    for (final row in later) {
      final changed = _decodePayload(row);
      if (changed == null) continue;
      if (!paths.contains(changed['mailboxPath'])) continue;
      if (changed['uid'] != email.uid) continue;
      // Back where its UID came from: the UID is right again.
      changed
        ..['mailboxPath'] = src
        ..remove('uidValidity')
        ..remove(_uidAfterMoveKey);
      if (payload['uidValidity'] case final int validity) {
        changed['uidValidity'] = validity;
      }
      if (payload['messageId'] case final String messageId) {
        changed['messageId'] = messageId;
      }
      await (_db.update(_db.pendingChanges)..where((t) => t.id.equals(row.id)))
          .write(PendingChangesCompanion(payload: Value(jsonEncode(changed))));
    }
  }
}
