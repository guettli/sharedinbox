part of '../email_repository_impl.dart';

// The pending-change queue (op table): enqueue, claim, lease, release,
// Undo capture and cancel, retry and discard, observe.

/// Zone key under which [EmailRepositoryImpl.captureOps] collects the ids of
/// the changes queued meanwhile, per email id.
final _captureOpsKey = Object();

/// Zone key under which [EmailRepositoryImpl.flushPendingChanges] publishes
/// its claim token, which every change it claims carries, so it can release
/// exactly those if it ends without settling one.
final _flushTokenKey = Object();

/// The JMAP Email id of [row], for a server call about it.
String _requireJmapId(Email row) {
  final id = row.srvJmapId;
  if (id == null) {
    throw StateError('No server id is recorded for this message yet.');
  }
  return id;
}

/// A pending change that has failed this many attempts is marked
/// [_failedState] and no longer retried, so a permanent server error does
/// not retry forever. It is kept until the user retries or discards it.
const _maxChangeAttempts = model.maxPendingChangeAttempts;

/// `pending_changes.state` of a change that is queued or still retrying.
/// Only these rows are flushed.
const _pendingState = 'pending';

/// `pending_changes.state` of a change a flush claimed and may be sending
/// right now ([_ChangeQueue._claimPendingChange]), until [PendingChangeRow.leaseUntil].
/// It cannot be cancelled (Undo queues a reverse change instead) and is
/// not claimed by another flush while the lease holds.
const _inflightState = 'inflight';

/// States of a change that still protects its local value from sync and
/// that later changes of the mail depend on: queued, retrying or being
/// sent.
const _liveStates = [_pendingState, _inflightState, _stuckState];

/// `pending_changes.state` of a change that kept failing in a way that may
/// pass ([_maxChangeAttempts] tries): it keeps protecting the user's
/// local value and is retried with a growing backoff ([_stuckBackoff];
/// `lease_until` holds the next try). Shown as "not synced yet"; only the
/// user's Retry (now) or Discard (undone locally) ends it early.
const _stuckState = 'stuck';

/// [t] as local `HH:MM`, for log lines.
String _hhmm(DateTime t) {
  final l = t.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:'
      '${l.minute.toString().padLeft(2, '0')}';
}

/// Wait before the next try of a stuck change that has failed [attempts]
/// times: 15 minutes at the limit, doubling, at most 6 hours.
Duration _stuckBackoff(int attempts) {
  final steps = math.max(0, attempts - _maxChangeAttempts);
  final minutes = 15 * math.pow(2, math.min(steps, 5)).toInt();
  return Duration(minutes: math.min(minutes, 6 * 60));
}

/// How long a claim holds. Longer than any single apply: a claim is taken
/// right before its apply, and a batch's one-by-one fallback renews it
/// ([_ChangeQueue._renewClaim]), so a second process flushing the same database does
/// not take over a change being sent. An expired lease means the app died
/// mid-send ([_ChangeQueue._recoverExpiredLeases]); short enough that a change killed
/// with the app is sent again soon after the restart.
const _leaseDuration = Duration(minutes: 5);

/// `pending_changes.state` of a change the server applied that changes
/// read/star/snooze state: it keeps folding into the row until a later read
/// confirms it ([EmailStateWriter.ack], SYNC-REDESIGN.md §4.4–§4.5). Not
/// flushed, not shown as pending, and protects nothing else (the location
/// guards count only [_liveStates]).
const _ackedState = 'acked';

/// `pending_changes.state` of a change the app gave up on (retry limit or
/// a permanent refusal). Never flushed and protects nothing, so the next
/// server read shows server truth again; listed on the Pending Changes
/// screen.
const _failedState = 'failed';

/// `pending_changes.state` of a change of a mail that has no server copy
/// yet (a virtual row; a JMAP mail whose server id is unknown,
/// SYNC-REDESIGN.md §6): it folds like a pending one, but is not flushed
/// until the server copy is matched in place ([_ChangeQueue._unparkOps]
/// makes it pending), and expires after
/// [EmailStateWriter.parkedExpiry] ([EmailStateWriter.expireParked]).
const _parkedState = 'parked';

/// `pending_changes.state` of a counterpart's shadow change
/// (`origin = counterpart:<id>`, SYNC-REDESIGN.md §6): the effect of the
/// primary change `<id>` on the twin row of a counterpart account. Folds,
/// is never flushed or listed, and follows its primary: acked with it,
/// dropped when it is cancelled, superseded, failed or discarded
/// ([EmailStateWriter.dropOrphanedShadows]).
const _shadowState = 'shadow';

/// States of a change nothing was sent for yet that a newer change of the
/// same intent may replace, and Undo may cancel.
const _unsentStates = [_pendingState, _parkedState];

/// Zone key under which [_ChangeQueue._enqueueChange] queues shadows of
/// the change with this id instead of real changes ([_Counterparts]).
final _shadowOfKey = Object();

/// Payload key of a parked change: the folder its row showed when it was
/// queued. It marks the payload as built for a row without a server copy
/// (rewritten by [_ChangeQueue._unparkOps], which removes it), and tells
/// where a delete for good was meant.
const _parkedShownInKey = 'parkedShownIn';

/// [payload] of a change parked on a row shown in [shownIn].
String _markParked(String payload, String shownIn) {
  final Map<String, dynamic> map;
  try {
    map = jsonDecode(payload) as Map<String, dynamic>;
  } catch (_) {
    return payload;
  }
  map[_parkedShownInKey] = shownIn;
  return jsonEncode(map);
}

/// What [_ChangeQueue._unparkOps] did.
class _Unparked {
  const _Unparked({
    required this.sent,
    required this.deletedForGood,
    this.refusedDelete,
  });

  static const none = _Unparked(sent: 0, deletedForGood: false);

  /// Changes that became pending.
  final int sent;

  /// One of them deletes the mail for good.
  final bool deletedForGood;

  /// A delete for good that failed instead: the mail arrived elsewhere
  /// than where the user deleted it.
  final PendingChangeRow? refusedDelete;
}

/// [row]'s JSON payload, or null when it is not a JSON object.
Map<String, dynamic>? _decodePayload(PendingChangeRow row) {
  try {
    return jsonDecode(row.payload) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

// ── pending_changes queue ──────────────────────────────────────────────────

/// Zone key marking changes the app queues on its own (snooze wake-up and
/// local Sieve filters), not as a direct user action; see
/// [_ChangeQueue._asAutomaticChange].
final _automaticChangeKey = Object();

/// Whether [row] was queued for the mail with [messageId]: true unless its
/// payload carries a different Message-ID stamp.
bool _sameMessage(PendingChangeRow row, String? messageId) {
  final stamped = _decodePayload(row)?['messageId'];
  if (stamped is! String) return true;
  return stamped == messageId;
}

List<String> _supersededBy(String changeType) {
  if (changeType == 'flag_seen' || changeType == 'flag_flagged') {
    return [changeType];
  }
  if (_placementChangeTypes.contains(changeType)) {
    return _placementChangeTypes;
  }
  return const [];
}

/// Payload key set by [_ChangeQueue._markUidAfterQueuedMove].
const _uidAfterMoveKey = 'uidAfterMove';

/// Stamps the JMAP Email id [jmapId] of the mail on a change [payload],
/// so the flush finds the mail on the server even when its row is gone
/// by then.
String _stampJmapId(String payload, String? jmapId) {
  if (jmapId == null) return payload;
  final Map<String, dynamic> map;
  try {
    map = jsonDecode(payload) as Map<String, dynamic>;
  } catch (_) {
    return payload;
  }
  map['jmapId'] = jmapId;
  return jsonEncode(map);
}

/// This flush's claim token (set by [EmailRepositoryImpl.flushPendingChanges] under
/// [_flushTokenKey]); a fresh one outside a flush.
String _flushToken() =>
    Zone.current[_flushTokenKey] as String? ?? _newClaimToken();

final _claimRandom = math.Random.secure();

String _newClaimToken() => List.generate(
      16,
      (_) => _claimRandom.nextInt(16).toRadixString(16),
    ).join();

model.PendingChange _toPendingChange(PendingChangeRow r) => model.PendingChange(
      id: r.id,
      accountId: r.accountId,
      kind: r.changeType,
      resourceType: r.resourceType,
      resourceId: r.resourceId,
      payload: r.payload,
      createdAt: r.createdAt,
      attempts: r.attempts,
      lastError: r.lastError,
      failed: r.state == _failedState,
      sending: r.state == _inflightState,
      stuck: r.state == _stuckState,
      nextTry: r.state == _stuckState ? r.leaseUntil : null,
      parked: r.state == _parkedState,
    );

extension _ChangeQueue on EmailRepositoryImpl {
  /// The JMAP Email id a queued change of [row] addresses: the one stamped
  /// on it when it was queued (schema v71 stamped the older ones), else the
  /// mail's recorded server id.
  Future<String> _jmapIdOfChange(PendingChangeRow row) async {
    if (_decodePayload(row)?['jmapId'] case final String stamped) {
      return stamped;
    }
    final email = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(row.resourceId)))
        .getSingleOrNull();
    final recorded = email?.srvJmapId;
    if (recorded != null) return recorded;
    throw StateError('No server id is recorded for this message.');
  }

  /// The state for a claimed change put back in the queue without an
  /// outcome (not sent, maybe sent, released, lease expired) after
  /// [attempts]: `stuck` from the retry limit on (with its backoff, or due
  /// at once with [dueNow] for one that was not sent), so it stays among
  /// the stuck changes, else `pending`.
  PendingChangesCompanion _requeued(int attempts, {bool dueNow = false}) =>
      attempts >= _maxChangeAttempts
          ? PendingChangesCompanion(
              state: const Value(_stuckState),
              leaseUntil:
                  Value(dueNow ? _now() : _now().add(_stuckBackoff(attempts))),
              claimToken: const Value(null),
              attempts: Value(attempts),
            )
          : PendingChangesCompanion(
              state: const Value(_pendingState),
              leaseUntil: const Value(null),
              claimToken: const Value(null),
              attempts: Value(attempts),
            );

  /// Short human-readable label for a queued change, used in App Log messages.
  String _describeChange(PendingChangeRow row) {
    switch (row.changeType) {
      case 'move':
        return 'move';
      case 'delete':
        return 'delete';
      case 'flag_seen':
        return 'read/unread change';
      case 'flag_flagged':
        return 'flag change';
      case 'add_keywords':
        return 'keyword change';
      case 'snooze':
        return 'snooze';
      case 'unsnooze':
        return 'unsnooze';
      case 'clear_snooze':
        return 'snooze cleanup';
      default:
        return '"${row.changeType}" change';
    }
  }

  /// Runs [action] so that the changes it queues do not replace the user's
  /// failed changes ([_deleteSupersededFailures]): only the user's own action
  /// may settle one of their failures.
  Future<T> _asAutomaticChange<T>(Future<T> Function() action) =>
      runZoned(action, zoneValues: {_automaticChangeKey: true});

  /// Queues a change and folds it into the row's read/star/snooze state
  /// ([EmailStateWriter.refold]) in the same transaction. A user action
  /// ([supersedeFailures], the default unless run via [_asAutomaticChange])
  /// also deletes the failed changes it replaces. A newer read or star
  /// change replaces (supersedes) a queued one of the same flag that was not
  /// claimed by a flush (SYNC-REDESIGN.md §3). With [fold] false the caller
  /// folds itself (the bulk form of `markAllAsRead`).
  ///
  /// Returns whether a change of this intent is queued now. A row with no
  /// server copy to change (a local virtual row, a JMAP mail whose server
  /// id is unknown) gets a `parked` one ([_parkedState]): it folds, and is
  /// sent once the server copy is matched in place ([_unparkOps]). Inside
  /// [_asShadowOf] the change is queued as a shadow of that primary
  /// ([_shadowState]): folded, never sent. False only for a JMAP mail
  /// whose row is gone.
  Future<bool> _enqueueChange(
    String accountId,
    String resourceId,
    String changeType,
    String payload, {
    bool? supersedeFailures,
    bool fold = true,
  }) async {
    final email = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(resourceId)))
        .getSingleOrNull();
    final shadowOf = Zone.current[_shadowOfKey] as int?;
    if (email == null &&
        (await _bulkAccount(accountId))?.type ==
            account_model.AccountType.jmap) {
      // No row, so no server id to send it for: queued, it would fail at
      // every flush.
      unawaited(
        _appLogger?.warn(
          'pending_change.no_server_id',
          'Did not queue $changeType: this message is no longer stored, so '
              'its server id is not known.',
          accountId: accountId,
          data: {'emailId': resourceId, 'changeType': changeType},
        ),
      );
      return false;
    }
    // A local self-sent "virtual" message (#545), or a JMAP mail whose
    // server id is not known, has no server copy to change yet: the change
    // is parked, folds like any other and is sent once the server copy is
    // matched in place (SYNC-REDESIGN.md §6).
    final parked = email != null && await _hasNoServerCopy(email);
    if (!parked) {
      payload = _stampJmapId(payload, email?.srvJmapId);
      payload = await _stampUidValidity(accountId, resourceId, payload);
      payload = await _markUidAfterQueuedMove(resourceId, payload);
    } else if (shadowOf == null) {
      payload = _markParked(payload, email.mailboxPath);
    }
    final supersede = shadowOf == null &&
        (supersedeFailures ?? Zone.current[_automaticChangeKey] != true);
    final flag = changeType == 'flag_seen' || changeType == 'flag_flagged';

    final seq = await _db.transaction(() async {
      if (supersede) await _deleteSupersededFailures(resourceId, changeType);
      if (shadowOf != null) {
        // One shadow per primary and row.
        final known = await (_db.select(_db.pendingChanges)
              ..where(
                (t) =>
                    t.resourceId.equals(resourceId) &
                    t.origin.equals(EmailStateWriter.shadowOrigin(shadowOf)),
              )
              ..limit(1))
            .getSingleOrNull();
        if (known != null) return null;
        final seq = await _db.into(_db.pendingChanges).insert(
              PendingChangesCompanion.insert(
                accountId: accountId,
                resourceType: 'Email',
                resourceId: resourceId,
                changeType: changeType,
                payload: payload,
                createdAt: DateTime.now(),
                state: const Value(_shadowState),
                origin: Value(EmailStateWriter.shadowOrigin(shadowOf)),
              ),
            );
        if (fold) await _state.refold(resourceId);
        return seq;
      }

      // Collapse redundant changes: if an un-attempted `flag_seen` /
      // `flag_flagged` / `clear_snooze` for this message with the same
      // payload is already queued, don't append a duplicate (the wake-up
      // queues a `clear_snooze` for a stale snooze). Only these are de-duped
      // — move / delete / snooze carry ordering semantics and must not be
      // collapsed here (#644).
      if (flag ||
          changeType == 'add_keywords' ||
          changeType == 'clear_snooze') {
        // Compare against the latest queued change of this type only: with
        // `[seen:true, seen:false]` queued, a new `seen:true` is not
        // redundant and must be appended, or the server would end up
        // unread (#1186). A failed change is not queued work: the new one
        // must be appended.
        final latest = await (_db.select(_db.pendingChanges)
              ..where(
                (t) =>
                    t.resourceId.equals(resourceId) &
                    t.state.isIn(_unsentStates) &
                    t.changeType.equals(changeType),
              )
              ..orderBy([(t) => OrderingTerm.desc(t.id)])
              ..limit(1))
            .getSingleOrNull();
        if (latest != null &&
            latest.payload == payload &&
            latest.attempts == 0) {
          return null;
        }
      }
      // Supersede: the new read/star change carries the user's latest value
      // of the flag, so a queued one no flush has claimed is not sent any
      // more. One being sent stays; this one follows it. Latent: Undo
      // records the ids it captured ([_captureOps]) only in its own action,
      // not here, so a superseded one can be among them. Undo queues no
      // read/star changes today; if it ever does, a cancel of the gone id
      // falls through to queueing the inverse (SYNC-REDESIGN.md §3).
      if (flag) {
        final superseded = await (_db.delete(_db.pendingChanges)
              ..where(
                (t) =>
                    t.resourceId.equals(resourceId) &
                    t.changeType.equals(changeType) &
                    t.state.isIn(_unsentStates),
              ))
            .go();
        // Its shadows on a counterpart go with it.
        if (superseded > 0) {
          await _rethreadRefolds(await _state.dropOrphanedShadows());
        }
      }

      final seq = await _db.into(_db.pendingChanges).insert(
            PendingChangesCompanion.insert(
              accountId: accountId,
              resourceType: 'Email',
              resourceId: resourceId,
              changeType: changeType,
              payload: payload,
              createdAt: DateTime.now(),
              state: parked ? const Value(_parkedState) : const Value.absent(),
            ),
          );
      if (fold) await _state.refold(resourceId);
      return seq;
    });
    if (seq == null) return true;
    // A shadow is not the user's change: Undo cancels its primary, which
    // takes it along.
    if (shadowOf != null) return true;
    (Zone.current[_captureOpsKey] as Map<String, List<int>>?)
        ?.putIfAbsent(resourceId, () => [])
        .add(seq);
    // Nothing to send before the server copy is there.
    if (parked) return true;
    final bulk = _bulkScope;
    if (bulk != null) {
      bulk.kickedAccounts.add(accountId);
      return true;
    }
    _changeCtrl.add(accountId);
    return true;
  }

  /// Whether [row] has no server copy a change could be sent for: a local
  /// virtual row, or a JMAP mail whose server id is not known. Its changes
  /// are parked ([_parkedState]).
  Future<bool> _hasNoServerCopy(Email row) async {
    if (row.isLocal) return true;
    if (row.srvJmapId != null || row.srvUid != null) return false;
    return (await _bulkAccount(row.accountId))?.type ==
        account_model.AccountType.jmap;
  }

  /// Runs [action] so that the changes it queues are shadows of change
  /// [primaryId] ([_shadowState]) on the counterpart rows it acts on.
  Future<T> _asShadowOf<T>(int primaryId, Future<T> Function() action) =>
      runZoned(action, zoneValues: {_shadowOfKey: primaryId});

  /// The parked changes of row [emailId], whose server copy was just
  /// matched in place ([_Counterparts._matchArrival]), become pending: in
  /// queue order, each payload addresses the mail where it is when that
  /// change runs (the server's folder, UID and UIDVALIDITY for the first,
  /// the destination of the change before it for the later ones, which
  /// then find the mail by Message-ID, [_markUidAfterQueuedMove]), and
  /// carries the server id, as one queued now would. They keep their ids
  /// (their order, and Undo's references).
  ///
  /// A move into the folder the mail is in already is dropped (nothing to
  /// send). A delete for good is sent only when the mail arrived in the
  /// inbox or is in the folder the user deleted it from ([_parkedShownInKey]):
  /// a server-side filter may have filed it elsewhere (Junk, Gmail's All
  /// Mail, where an expunge removes every label), and deleting that for
  /// good was not what the user saw. Such a delete fails instead, so the
  /// mail shows again and stays listed with the change.
  Future<_Unparked> _unparkOps(String emailId) => _db.transaction(() async {
        final row = await (_db.select(_db.emails)
              ..where((t) => t.id.equals(emailId)))
            .getSingleOrNull();
        if (row == null || await _hasNoServerCopy(row)) return _Unparked.none;
        final parked = await (_db.select(_db.pendingChanges)
              ..where(
                (t) =>
                    t.resourceId.equals(emailId) & t.state.equals(_parkedState),
              )
              ..orderBy([(t) => OrderingTerm.asc(t.id)]))
            .get();
        final arrival = row.srvMailboxPath ?? row.mailboxPath;
        final arrivalIsInbox =
            await _mailboxRole(row.accountId, arrival) == 'inbox';
        var at = arrival;
        var sent = 0;
        var deletedForGood = false;
        PendingChangeRow? refusedDelete;
        for (final op in parked) {
          final payload = _decodePayload(op) ?? <String, dynamic>{};
          final shownIn = payload.remove(_parkedShownInKey);
          if (op.changeType == 'move' &&
              payload['dest'] == at &&
              payload['clearSnooze'] != true) {
            await (_db.delete(_db.pendingChanges)
                  ..where((t) => t.id.equals(op.id)))
                .go();
            continue;
          }
          if (op.changeType == 'delete' && !arrivalIsInbox && shownIn != at) {
            await (_db.update(_db.pendingChanges)
                  ..where((t) => t.id.equals(op.id)))
                .write(
              PendingChangesCompanion(
                state: const Value(_failedState),
                lastError: Value(
                  'the delivered mail arrived in $arrival, not where it was '
                  'deleted: not deleted for good',
                ),
              ),
            );
            refusedDelete = op;
            continue;
          }
          if (payload.containsKey('uid')) payload['uid'] = row.srvUid ?? 0;
          for (final key in const ['mailboxPath', 'src']) {
            if (payload.containsKey(key)) payload[key] = at;
          }
          payload.remove('uidValidity');
          payload.remove(_uidAfterMoveKey);
          if (row.messageId != null) payload['messageId'] = row.messageId;
          var stamped = _stampJmapId(jsonEncode(payload), row.srvJmapId);
          stamped = await _stampUidValidity(row.accountId, emailId, stamped);
          stamped = await _markUidAfterQueuedMove(emailId, stamped);
          await (_db.update(_db.pendingChanges)
                ..where(
                  (t) => t.id.equals(op.id) & t.state.equals(_parkedState),
                ))
              .write(
            PendingChangesCompanion(
              state: const Value(_pendingState),
              payload: Value(stamped),
            ),
          );
          sent++;
          if (op.changeType == 'delete') deletedForGood = true;
          if (payload['dest'] case final String dest
              when _locationChangeTypes.contains(op.changeType)) {
            at = dest;
          }
        }
        return _Unparked(
          sent: sent,
          deletedForGood: deletedForGood,
          refusedDelete: refusedDelete,
        );
      });

  /// Deletes failed changes of [resourceId] that a new [changeType] change
  /// replaces: the same flag change, or for a move/snooze/unsnooze/delete any
  /// failed location change. Redoing the action (or an Undo) clears the stale
  /// failure instead of piling up next to it.
  Future<void> _deleteSupersededFailures(
    String resourceId,
    String changeType,
  ) async {
    final superseded = _supersededBy(changeType);
    if (superseded.isEmpty) return;
    // A stuck read/star change is replaced too: the new one carries the
    // user's newer value. A stuck move/delete is not: later location
    // changes address the mail where it would put it.
    final flag = changeType == 'flag_seen' || changeType == 'flag_flagged';
    final failed = await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.resourceId.equals(resourceId) &
                (flag
                    ? t.state.isIn(const [_failedState, _stuckState])
                    : t.state.equals(_failedState)) &
                t.changeType.isIn(superseded),
          ))
        .get();
    if (failed.isEmpty) return;
    final messageId = await _messageIdOf(resourceId);
    for (final row in failed) {
      // After a UIDVALIDITY reset the same row id can name another mail: a
      // failure stamped with a different Message-ID is not this mail's.
      if (!_sameMessage(row, messageId)) continue;
      // Not one a flush has claimed meanwhile: that one is being sent.
      await (_db.delete(_db.pendingChanges)
            ..where(
              (t) =>
                  t.id.equals(row.id) &
                  t.state.isIn(const [_failedState, _stuckState]),
            ))
          .go();
    }
  }

  /// Adds the source folder's UIDVALIDITY to an IMAP change [payload] (one
  /// with a `uid` and a `mailboxPath`/`src`), as known from that folder's
  /// sync checkpoint. A UID only names a message under one UIDVALIDITY: if
  /// the server resets it before the flush, the same UID can belong to a
  /// different message, and a queued delete would expunge the wrong mail.
  /// The flush compares the stamp with what SELECT reports
  /// ([_FlushImap._currentImapUid]). The row's Message-ID is stamped too, while
  /// [resourceId] still names this message: after a reset, sync re-inserts
  /// the folder under new UIDs and the same row id can then belong to
  /// another message. JMAP payloads and folders never synced (no
  /// checkpoint yet, e.g. during the first full sync) are left as they are.
  /// The stamp is the folder's UIDVALIDITY at enqueue time, not proof of
  /// where the UID was learned: an optimistically moved row still carries
  /// its source UID, as before.
  Future<String> _stampUidValidity(
    String accountId,
    String resourceId,
    String payload,
  ) async {
    final Map<String, dynamic> map;
    try {
      map = jsonDecode(payload) as Map<String, dynamic>;
    } catch (_) {
      return payload;
    }
    if (map['uid'] is! int || map.containsKey('uidValidity')) return payload;
    final path = map['mailboxPath'] ?? map['src'];
    if (path is! String) return payload;
    final checkpoint = await _loadImapCheckpoint(accountId, 'IMAP:$path');
    final validity = checkpoint?['uidValidity'];
    // 0 is no valid UIDVALIDITY (RFC 3501): the checkpoint's fallback for a
    // server that reported none.
    if (validity is! int || validity == 0) return payload;
    map['uidValidity'] = validity;
    if (map['messageId'] == null) {
      final messageId = await _messageIdOf(resourceId);
      if (messageId != null) map['messageId'] = messageId;
    }
    return jsonEncode(map);
  }

  /// Marks an IMAP change [payload] whose UID is not the mail's UID in the
  /// payload's folder yet: a move of the same mail to that folder is still
  /// queued, so the local row and this UID are the pre-move ones (#1266).
  /// There the UID may name another mail. The move's answer replaces it
  /// ([_FlushImap._repointQueuedChanges]); a change still marked when it is applied
  /// finds its mail by Message-ID instead, or fails ([_FlushImap._currentImapUid]).
  ///
  /// Since phase 4b the rule is the location overlay's: the payload's
  /// folder is not where the server has the row's mail as last read
  /// (`srv_mailbox_path`). That covers a queued move, a counterpart twin
  /// shown in a folder through a shadow and an acked move whose new UID
  /// was never learnt (all keep the source's UID; acting on it in the
  /// shown folder would hit another mail), and leaves alone an acked move
  /// whose new location is recorded. Only a row without a recorded server
  /// folder falls back to the queued moves into the payload's folder.
  Future<String> _markUidAfterQueuedMove(
    String resourceId,
    String payload,
  ) async {
    final Map<String, dynamic> map;
    try {
      map = jsonDecode(payload) as Map<String, dynamic>;
    } catch (_) {
      return payload;
    }
    if (map['uid'] is! int) return payload;
    final path = map['mailboxPath'] ?? map['src'];
    if (path is! String) return payload;
    final srv = await (_db.selectOnly(_db.emails)
          ..addColumns([_db.emails.srvMailboxPath])
          ..where(_db.emails.id.equals(resourceId)))
        .getSingleOrNull();
    final srvPath = srv?.read(_db.emails.srvMailboxPath);
    if (srvPath != null) {
      if (srvPath == path) return payload;
    } else {
      final moves = await (_db.select(_db.pendingChanges)
            ..where(
              (t) =>
                  t.resourceId.equals(resourceId) &
                  t.state.isIn(_liveStates) &
                  t.changeType.isIn(_locationChangeTypes),
            ))
          .get();
      if (!moves.any((m) => _decodePayload(m)?['dest'] == path)) {
        return payload;
      }
    }
    map[_uidAfterMoveKey] = true;
    if (map['messageId'] == null) {
      final messageId = await _messageIdOf(resourceId);
      if (messageId != null) map['messageId'] = messageId;
    }
    return jsonEncode(map);
  }

  /// Atomically claims [snapshot] for a flush: `inflight` with a lease
  /// ([_leaseDuration]), so [cancelPendingChange] (which only removes
  /// `pending` rows nothing was sent for) can no longer delete a change that
  /// is being applied, and no other flush (another isolate or process on
  /// the same database) takes it. Otherwise an Undo racing the flush would
  /// "cancel" a MOVE that still lands on the server and skip its reverse
  /// move (#1048). Every outcome then settles the row: deleted when applied,
  /// back to `pending` ([_unclaimPendingChange], [_keepClaimWithoutCharge],
  /// [_ChangeFailures._recordChangeError]) or `failed`.
  ///
  /// Returns null when the row was cancelled, claimed by another flush or
  /// marked failed since the flush took its snapshot — the caller must then
  /// skip it.
  /// Otherwise returns the row as currently stored: an earlier change in the
  /// same flush may have relocated its mail ([_RowIdentity._relocateEmailRow] rewrites
  /// the payload UID). Claiming charges no attempt; [_ChangeFailures._recordChangeError]
  /// does, from the row's attempts.
  Future<PendingChangeRow?> _claimPendingChange(
    PendingChangeRow snapshot,
  ) async {
    final count = await (_db.update(_db.pendingChanges)
          ..where(
            (t) =>
                t.id.equals(snapshot.id) &
                t.state.equals(snapshot.state) &
                t.attempts.equals(snapshot.attempts) &
                (snapshot.state == _stuckState
                    ? t.leaseUntil.isSmallerOrEqualValue(_now())
                    : const Constant(true)),
          ))
        .write(
      PendingChangesCompanion(
        state: const Value(_inflightState),
        leaseUntil: Value(_now().add(_leaseDuration)),
        claimToken: Value(_flushToken()),
      ),
    );
    if (count == 0) return null;
    return (_db.select(_db.pendingChanges)
          ..where((t) => t.id.equals(snapshot.id)))
        .getSingleOrNull();
  }

  /// Whether the stored row of [row], a change claimed by a flush, is still
  /// that flush's claim: `inflight` under the claim token [row] was claimed
  /// with. Every outcome write checks it, so a flush whose lease ran out
  /// (e.g. suspended by laptop sleep) and was taken over cannot overwrite
  /// the new claim.
  Expression<bool> _ownsClaim($PendingChangesTable t, PendingChangeRow row) {
    final token = row.claimToken;
    return t.id.equals(row.id) &
        t.state.equals(_inflightState) &
        (token == null ? t.claimToken.isNull() : t.claimToken.equals(token));
  }

  /// Extends the claim of [row] before a slow apply (the one-by-one
  /// fallback of a batch claimed up front). Null when the claim was lost.
  Future<PendingChangeRow?> _renewClaim(PendingChangeRow row) async {
    final count = await (_db.update(_db.pendingChanges)
          ..where((t) => _ownsClaim(t, row)))
        .write(
      PendingChangesCompanion(leaseUntil: Value(_now().add(_leaseDuration))),
    );
    if (count == 0) return null;
    return (_db.select(_db.pendingChanges)..where((t) => t.id.equals(row.id)))
        .getSingleOrNull();
  }

  /// Settles the changes this flush claimed (claim token [token]) but left
  /// `inflight` (an unexpected error between claim and outcome): back to
  /// `pending`, one attempt charged, since they may have reached the server.
  Future<void> _releaseUnsettledClaims(String accountId, String token) async {
    final left = await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.state.equals(_inflightState) &
                t.claimToken.equals(token),
          ))
        .get();
    for (final row in left) {
      final count = await (_db.update(_db.pendingChanges)
            ..where((t) => _ownsClaim(t, row)))
          .write(_requeued(row.attempts + 1));
      if (count > 0) {
        log('Pending change ${row.id} left in flight by its flush; released');
      }
    }
  }

  /// Changes of [accountId] still `inflight` after their lease ran out: the
  /// app (or a second process) died while sending them, so they may or may
  /// not have reached the server. Each goes back to `pending` with one
  /// attempt charged, as the old claim marker did, and is sent again; the
  /// retry limit is applied by that resend, not here, so a change that
  /// probably landed is not given up on unseen. Every apply path first
  /// checks whether the change is already done (a move finds the mail in its
  /// destination, a flag STORE is idempotent, a delete of a gone mail counts
  /// as applied). Compare-and-set, so two flushes recovering at once charge
  /// it once.
  Future<void> _recoverExpiredLeases(String accountId) async {
    final expired = await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.state.equals(_inflightState) &
                (t.leaseUntil.isNull() |
                    t.leaseUntil.isSmallerOrEqualValue(_now())),
          ))
        .get();
    for (final row in expired) {
      final count = await (_db.update(_db.pendingChanges)
            ..where((t) => _ownsClaim(t, row)))
          .write(
        _requeued(row.attempts + 1).copyWith(
          lastError: const Value('interrupted while sending (app closed?)'),
        ),
      );
      if (count > 0) {
        log('Pending change ${row.id}: lease expired, will be sent again');
      }
    }
  }

  /// Whether change [id] is still queued (pending or stuck), i.e. will be
  /// retried.
  Future<bool> _stillQueued(int id) async =>
      await (_db.select(_db.pendingChanges)
            ..where(
              (t) =>
                  t.id.equals(id) &
                  t.state.isIn(const [_pendingState, _stuckState]),
            ))
          .getSingleOrNull() !=
      null;

  /// Mails with a change some other flush is sending now, or a stuck change
  /// this flush did not select (not due when it took its snapshot of
  /// [selected] ids): this flush leaves all their changes alone, so a mail's
  /// changes reach the server in order.
  Future<Set<String>> _mailsInFlightElsewhere(
    String accountId, {
    required Set<int> selected,
  }) async {
    final ids = await (_db.selectOnly(_db.pendingChanges)
          ..addColumns([_db.pendingChanges.resourceId])
          ..where(
            _db.pendingChanges.accountId.equals(accountId) &
                (_db.pendingChanges.state.equals(_inflightState) |
                    (_db.pendingChanges.state.equals(_stuckState) &
                        _db.pendingChanges.id.isNotIn(selected))),
          ))
        .map((r) => r.read(_db.pendingChanges.resourceId)!)
        .get();
    return ids.toSet();
  }

  Future<(T, Map<String, List<int>>)> _captureOps<T>(
    Future<T> Function() apply,
  ) async {
    final ops = <String, List<int>>{};
    final result = await runZoned(apply, zoneValues: {_captureOpsKey: ops});
    // A copy: work [apply] left running must not add to it later.
    final copy = {
      for (final e in ops.entries) e.key: [...e.value],
    };
    return (result, copy);
  }

  Future<Set<int>> _cancelOps(Iterable<int> ids) async {
    final cancelled = <int>{};
    // Latest first, as an Undo of several steps would cancel them.
    for (final id in ids.toSet().toList()..sort((a, b) => b.compareTo(a))) {
      // One transaction per change: its delete and the row's fold.
      final done = await _db.transaction(() async {
        final row = await (_db.select(_db.pendingChanges)
              ..where((t) => t.id.equals(id)))
            .getSingleOrNull();
        // Only one nothing was sent for (see [_claimPendingChange]).
        if (row == null) return false;
        final count = await (_db.delete(_db.pendingChanges)
              ..where(
                (t) =>
                    t.id.equals(id) &
                    t.state.isIn(_unsentStates) &
                    t.attempts.equals(0),
              ))
            .go();
        if (count == 0) return false;
        if (_locationChangeTypes.contains(row.changeType)) {
          await _unmarkAfterCancelledMove(row);
          await _restoreSnoozedFromAfterCancel(row);
        }
        await _refoldAndRethread(row.resourceId);
        return true;
      });
      if (done) cancelled.add(id);
    }
    return cancelled;
  }

  Future<bool> _cancelPendingChange(String emailId, String changeType) =>
      // One transaction: the delete and the row's fold.
      _db.transaction(() => _cancelLatestPendingChange(emailId, changeType));

  Future<bool> _cancelLatestPendingChange(
    String emailId,
    String changeType,
  ) async {
    // Find the latest pending change for this email/type that no flush has
    // picked up yet (see [_claimPendingChange]).
    final query = _db.select(_db.pendingChanges)
      ..where(
        (t) =>
            t.resourceId.equals(emailId) &
            t.changeType.equals(changeType) &
            t.state.isIn(_unsentStates) &
            t.attempts.equals(0),
      )
      ..orderBy([(t) => OrderingTerm.desc(t.id)])
      ..limit(1);

    final row = await query.getSingleOrNull();
    if (row == null) return false;
    final count = await (_db.delete(
      _db.pendingChanges,
    )..where((t) => t.id.equals(row.id)))
        .go();
    if (count == 0) return false;
    if (_locationChangeTypes.contains(changeType)) {
      await _unmarkAfterCancelledMove(row);
      await _restoreSnoozedFromAfterCancel(row);
    }
    await _refoldAndRethread(emailId);
    return true;
  }

  /// After [cancelled], a queued move, snooze or unsnooze, was cancelled
  /// (Undo): its fold is gone, so the row shows its earlier folder and
  /// snooze again; the local-only folder it was snoozed from comes back
  /// from the payload (none when it was not snoozed before).
  Future<void> _restoreSnoozedFromAfterCancel(
    PendingChangeRow cancelled,
  ) async {
    final payload = _decodePayload(cancelled);
    if (payload == null) return;
    final prevFrom = payload['prevSnoozedFrom'];
    await _state.writeSnoozedFrom(
      cancelled.resourceId,
      payload['prevSnoozedUntil'] != null && prevFrom is String
          ? prevFrom
          : null,
    );
  }

  /// After [cancelled], a queued move, was cancelled (Undo), the changes
  /// queued behind it for the mail in its destination
  /// ([_markUidAfterQueuedMove]) act in its source again: the mail stays
  /// there, under the UID they carry. They stay marked when another move
  /// queued before them still brings the mail to that source.
  Future<void> _unmarkAfterCancelledMove(PendingChangeRow cancelled) async {
    final moved = _decodePayload(cancelled);
    final src = moved?['mailboxPath'] ?? moved?['src'];
    final dest = moved?['dest'];
    if (src is! String || dest is! String) return;
    final queued = await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.resourceId.equals(cancelled.resourceId) &
                t.state.isIn(_liveStates),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();
    for (final change in queued) {
      if (change.id < cancelled.id) continue;
      final payload = _decodePayload(change);
      if (payload == null || payload[_uidAfterMoveKey] != true) continue;
      final key = payload.containsKey('mailboxPath') ? 'mailboxPath' : 'src';
      if (payload[key] != dest) continue;
      final stillMoved = queued.any(
        (m) =>
            m.id < change.id &&
            _locationChangeTypes.contains(m.changeType) &&
            _decodePayload(m)?['dest'] == src,
      );
      // The cancelled move's stamp is the source's UIDVALIDITY.
      payload
        ..[key] = src
        ..remove('uidValidity');
      if (moved?['uidValidity'] case final int validity) {
        payload['uidValidity'] = validity;
      }
      if (!stillMoved) payload.remove(_uidAfterMoveKey);
      await (_db.update(_db.pendingChanges)
            ..where((t) => t.id.equals(change.id)))
          .write(PendingChangesCompanion(payload: Value(jsonEncode(payload))));
    }
  }

  /// Settles a claimed [row] whose request got no answer: back to
  /// `pending`, marked as maybe sent (attempts at least 1, so
  /// [cancelPendingChange] leaves it alone) but charged nothing beyond
  /// that, with [error] recorded.
  Future<void> _keepClaimWithoutCharge(PendingChangeRow row, Object error) =>
      (_db.update(_db.pendingChanges)..where((t) => _ownsClaim(t, row))).write(
        _requeued(math.max(row.attempts, 1))
            .copyWith(lastError: Value(error.toString())),
      );

  /// Returns a row claimed by [_claimPendingChange] to `pending`, for a
  /// change the flush never sent: no attempt charged, so Undo can still
  /// cancel it.
  Future<void> _unclaimPendingChange(PendingChangeRow claimed) =>
      (_db.update(_db.pendingChanges)..where((t) => _ownsClaim(t, claimed)))
          .write(_requeued(claimed.attempts, dueNow: true));

  Future<void> _deletePendingChange(PendingChangeRow row) =>
      (_db.delete(_db.pendingChanges)..where((t) => t.id.equals(row.id))).go();

  /// Settles a claimed [row] the server applied: `acked` when it changes
  /// read/star/snooze state or the folder, so it keeps showing until a
  /// later read confirms it ([EmailStateWriter.ack], which also records what
  /// the server confirmed: [confirmedMailboxPath], [confirmedGone]); deleted
  /// otherwise, as before.
  Future<void> _settleApplied(
    PendingChangeRow row, {
    String? confirmedMailboxPath,
    bool confirmedGone = false,
  }) async {
    if (await _state.ack(
      row,
      confirmedMailboxPath: confirmedMailboxPath,
      confirmedGone: confirmedGone,
    )) {
      return;
    }
    await _deletePendingChange(row);
  }

  // ── Failed mutations (offline compose queue) ─────────────────────────────

  Stream<List<model.FailedMutation>> _observeFailedMutations(String accountId) {
    return (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.lastError.isNotNull() &
                t.state.isIn(const [_ackedState, _shadowState]).not(),
          )
          ..orderBy([
            (t) => OrderingTerm.asc(t.createdAt),
            (t) => OrderingTerm.asc(t.id),
          ]))
        .watch()
        .map(
          (rows) => rows
              .map(
                (r) => model.FailedMutation(
                  id: r.id,
                  accountId: r.accountId,
                  changeType: r.changeType,
                  resourceId: r.resourceId,
                  lastError: r.lastError!,
                  attempts: r.attempts,
                  createdAt: r.createdAt,
                  failed: r.state == _failedState,
                  stuck: r.state == _stuckState,
                ),
              )
              .toList(),
        );
  }

  Future<void> _discardMutation(int id) async {
    final discarded = await _db.transaction(() async {
      final row = await (_db.select(_db.pendingChanges)
            ..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      // An in-flight change may be reaching the server right now: the
      // flush settles it (the screen offers no Discard for it).
      if (row == null || row.state == _inflightState) return null;
      await (_db.delete(_db.pendingChanges)..where((t) => t.id.equals(id)))
          .go();
      // A failed change no longer shows locally (it does not fold).
      if (row.state == _failedState) return null;
      // Pending or stuck: the mail still shows the user's intent. Give that
      // up as a failure would, so it does not vanish or keep a value the
      // server never gets; the mail's later moves and deletes depend on it.
      await _afterFlagFailure(row);
      final dependents = await _afterLocationFailure(row, revert: true);
      await _refoldAndRethread(row.resourceId);
      return (row: row, dependents: dependents);
    });
    if (discarded != null) {
      _logDependentFailures(discarded.row, discarded.dependents);
    }
  }

  Future<void> _retryMutation(int id) async {
    final row = await (_db.select(_db.pendingChanges)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return;
    if (row.state == _stuckState) {
      // Not synced yet: try it at the next flush instead of after its
      // backoff. It keeps its place in the queue.
      await (_db.update(_db.pendingChanges)
            ..where((t) => t.id.equals(id) & t.state.equals(_stuckState)))
          .write(PendingChangesCompanion(leaseUntil: Value(_now())));
      _changeCtrl.add(row.accountId);
      return;
    }
    if (row.state != _failedState) {
      // Still queued: it keeps its place, so newer changes stay newer and a
      // change being flushed right now is not queued twice. Just flush soon.
      _changeCtrl.add(row.accountId);
      return;
    }
    await _db.transaction(() async {
      final current = await (_db.select(_db.pendingChanges)
            ..where((t) => t.id.equals(id) & t.state.equals(_failedState)))
          .getSingleOrNull();
      if (current == null) return;
      // The failure showed the server's state again; show the user's
      // intent again while it is retried.
      await _reapplyRetriedChange(current);
      // A mail that still has no server copy (an expired parked change of
      // a JMAP mail without a known id) waits for it again.
      final email = await (_db.select(_db.emails)
            ..where((t) => t.id.equals(current.resourceId)))
          .getSingleOrNull();
      final wasParked =
          _decodePayload(current)?.containsKey(_parkedShownInKey) ?? false;
      // A change that was parked (built for a row without a server copy:
      // UID 0, the row's own folder) is never sent as it is: its row is
      // gone, so it stays failed; or it waits again for the server copy;
      // or, the copy being there by now, it is rewritten for it below.
      if (wasParked && email == null) return;
      final parked =
          email != null && (wasParked || await _hasNoServerCopy(email));
      // A fresh row at the end of the queue (new autoincrement id): the
      // retried change must not jump ahead of changes queued after it, or it
      // could undo the user's newer intent for the same mail.
      await _db.into(_db.pendingChanges).insert(
            PendingChangesCompanion.insert(
              accountId: current.accountId,
              resourceType: current.resourceType,
              resourceId: current.resourceId,
              changeType: current.changeType,
              payload: current.payload,
              createdAt: DateTime.now(),
              state: parked ? const Value(_parkedState) : const Value.absent(),
            ),
          );
      await _deletePendingChange(current);
      if (parked && !await _hasNoServerCopy(email)) {
        await _unparkOps(email.id);
      }
      // The retried change folds again: the folder, read/star and snooze.
      await _refoldAndRethread(current.resourceId);
    });
    _changeCtrl.add(row.accountId);
  }

  /// Re-applies the local-only part of a failed [row] that is being
  /// retried, without queueing or mirroring anything: the folder a snooze
  /// came from, when the mail is (again) at the change's source. The folder
  /// and the read/star/snooze values come back with the fold of the
  /// retried change.
  Future<void> _reapplyRetriedChange(PendingChangeRow row) async {
    final Map<String, dynamic> payload;
    try {
      payload = jsonDecode(row.payload) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final email = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(row.resourceId)))
        .getSingleOrNull();
    if (email == null) return;
    if (!_sameMessage(row, email.messageId)) return;
    if (!_locationChangeTypes.contains(row.changeType)) return;
    final src = payload['mailboxPath'] ?? payload['src'];
    final dest = payload['dest'];
    if (src is! String || dest is! String) return;
    if (!await _isAtLocation(email, src)) return;
    await _state.writeSnoozedFrom(
      email.id,
      row.changeType == 'snooze' ? email.mailboxPath : null,
    );
  }

  Stream<List<model.PendingChange>> _observePendingChanges(String accountId) {
    return (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.state.isIn(const [_ackedState, _shadowState]).not(),
          )
          ..orderBy([
            (t) => OrderingTerm.asc(t.createdAt),
            (t) => OrderingTerm.asc(t.id),
          ]))
        .watch()
        .map((rows) => rows.map(_toPendingChange).toList());
  }

  Stream<List<model.PendingChange>> _observeAllPendingChanges() {
    return (_db.select(_db.pendingChanges)
          ..where((t) => t.state.isIn(const [_ackedState, _shadowState]).not())
          ..orderBy([
            (t) => OrderingTerm.asc(t.createdAt),
            (t) => OrderingTerm.asc(t.id),
          ]))
        .watch()
        .map((rows) => rows.map(_toPendingChange).toList());
  }
}
