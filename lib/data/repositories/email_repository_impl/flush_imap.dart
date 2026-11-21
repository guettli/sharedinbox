part of '../email_repository_impl.dart';

// IMAP flush: draining the queue to an IMAP server (batched moves, STORE,
// EXPUNGE, snooze), settling each change and remapping moved rows.

/// A queued IMAP change whose message is gone: a move's message is in
/// neither its source nor its destination mailbox (another client deleted or
/// moved it), or a change queued behind a move cannot find its message
/// after that move. The flush marks the change failed.
class _ImapMessageGoneException implements Exception {
  _ImapMessageGoneException(this.message, {this.inNeitherMailbox = false});

  final String message;

  /// A move's message was searched for in its source and its destination
  /// and found in neither: the local row names no message any more.
  final bool inNeitherMailbox;

  @override
  String toString() => message;
}

/// A flag `UID STORE` of a queued IMAP change hit no mail: the UID it was
/// queued with is gone from its folder (another client moved or expunged
/// the mail), and the server answered OK without changing anything
/// (#1326). The change is not acked: it stays queued, marked
/// ([_srcVanishedKey]), until the sync finds where the mail went and
/// points it there (the foreign-move carry-over), or fails visibly when the
/// mail is gone ([_FlushImap._keepForForeignMove]).
class _ImapTargetVanishedException implements Exception {
  _ImapTargetVanishedException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The folder a queued IMAP change acts in could not be selected because it
/// no longer exists: the change is moot (see `_settleImapChange`).
class _ImapSourceMailboxGoneException implements Exception {
  _ImapSourceMailboxGoneException(this.cause);

  final Object cause;

  @override
  String toString() => cause.toString();
}

/// The folder a queued IMAP change acts in could not be selected with an
/// error that reads like "no such folder", but the server did not say
/// `NONEXISTENT` and a LIST did not confirm it ([confirmImapMailboxGone]):
/// the change is retried, never dropped as moot (#1312).
class _ImapSourceSelectFailedException implements Exception {
  _ImapSourceSelectFailedException(this.cause, {required this.repeat});

  final Object cause;

  /// The folder's SELECT failed so earlier in this pass (same connection):
  /// not sent again, and not logged again.
  final bool repeat;

  @override
  String toString() => cause.toString();
}

/// Per connection (one flush pass): the folders whose SELECT failed with an
/// error that only reads like "no such folder", with that error. The
/// pass's later changes of the folder fail the same way without a SELECT.
final _vagueSelectFailures = Expando<Map<String, Object>>('vagueSelect');

/// A queued IMAP change whose folder's UIDVALIDITY changed, and whose
/// message is not found exactly once again by Message-ID.
class _ImapUidValidityChangedException implements Exception {
  _ImapUidValidityChangedException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The flag edits one queued IMAP change made in its source folder [path]
/// before a later command of it (MOVE, EXPUNGE) was sent, each with the
/// command that takes it back: run when that later command is refused for
/// good, so the server does not keep half a change (#1316).
class _ImapUndoJournal {
  _ImapUndoJournal(this.client, this.path);

  final imap.ImapClient client;
  final String path;
  final List<Future<void> Function()> _steps = [];

  bool get isEmpty => _steps.isEmpty;

  void add(Future<void> Function() step) => _steps.add(step);

  /// Selects [path] again and takes the edits back, the latest first.
  /// Returns null when all of them were undone, else the first error.
  Future<Object?> run() async {
    try {
      await client.selectUnicodeMailboxByPath(path);
      for (final step in _steps.reversed) {
        await step();
      }
      return null;
    } catch (e) {
      return e;
    }
  }
}

/// Upper bound on the UIDs sent in one batched `UID MOVE`.
const _maxImapMoveBatch = 50;

extension _FlushImap on EmailRepositoryImpl {
  /// Drains pending changes for [accountId] via the appropriate protocol.
  /// Called at the start of each sync cycle. Returns count of applied changes.
  Future<int> _flushPendingChanges(String accountId, String password) async {
    await _recoverExpiredLeases(accountId);
    await _state.dropOrphanedAcks(accountId);
    // Shadows whose primary ended in another isolate or by a path that did
    // not take them along (SYNC-REDESIGN.md §6).
    await _rethreadRefolds(await _state.dropOrphanedShadows());
    // A counterpart's stand-in folder whose shadow create went with them.
    await _mailboxState.dropOrphanedCounterpartFolders(accountId);
    // Rows gone on the server whose last change settled since (failed or
    // was discarded): nothing can bring them back (clean-up rule).
    final cleaned = await _state.cleanUpGone(accountId);
    if (cleaned.isNotEmpty) await _logCleanedWithFailures(accountId, cleaned);
    Future<List<PendingChangeRow>> due({required bool mailboxes}) {
      final now = _now();
      return (_db.select(_db.pendingChanges)
            // A failed change waits for the user's Retry or Discard; a stuck
            // one for its next try.
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  (mailboxes
                      ? t.resourceType.equals(mailboxResourceType)
                      : t.resourceType.equals(mailboxResourceType).not()) &
                  (t.state.equals(_pendingState) |
                      (t.state.equals(_stuckState) &
                          t.leaseUntil.isSmallerOrEqualValue(now))) &
                  // Held while its mail waits for a foreign move's
                  // destination (#1313): sent to the vanished UID, a
                  // STORE would answer OK and do nothing. The adoption
                  // points it at the new UID; the end of the wait lets it
                  // fail visibly.
                  CustomExpression<bool>(
                    'NOT EXISTS (SELECT 1 FROM emails w '
                    'WHERE w.id = ${t.aliasedName}.resource_id '
                    'AND w.srv_gone = 1 '
                    'AND w.foreign_move_wait_seq IS NOT NULL)',
                  ),
            )
            // Flush in enqueue order. The autoincrement id gives that
            // exactly; `createdAt` can tie for changes queued together (a
            // Sieve flag + move) and would follow the wall clock if it
            // steps back.
            ..orderBy([(t) => OrderingTerm.asc(t.id)]))
          .get();
    }

    if ((await due(mailboxes: true)).isEmpty &&
        (await due(mailboxes: false)).isEmpty) {
      return 0;
    }

    final account = (await _accounts.getAccount(accountId))!;
    final token = _newClaimToken();
    try {
      return await runZoned(
        () async {
          // Folder creates and renames first: a move into a folder created
          // offline needs the folder (SYNC-REDESIGN.md §7).
          final folders = await _flushMailboxOps(account, password);
          final rows = await _holdForLocalFolders(
            accountId,
            await due(mailboxes: false),
          );
          if (rows.isEmpty) return folders;
          final mails = switch (account.type) {
            account_model.AccountType.imap =>
              await _flushPendingChangesImap(account, password, rows),
            account_model.AccountType.jmap =>
              await _flushPendingChangesJmap(account, password, rows),
          };
          // A folder delete waits for the mail changes queued before it
          // (phase 5b): with those sent, it goes in this flush too.
          final again = (await due(mailboxes: true))
                  .any((r) => r.changeType == deleteMailboxOp)
              ? await _flushMailboxOps(account, password, onlyDeletes: true)
              : 0;
          return folders + mails + again;
        },
        zoneValues: {_flushTokenKey: token},
      );
    } finally {
      await _releaseUnsettledClaims(accountId, token);
    }
  }

  /// [EmailStateWriter.expireParked] for [accountId] after a successful
  /// sync of [folder] (role [role]), with an App Log warning for each
  /// virtual row dropped (`email.virtual_expired`: its server copy never
  /// arrived) and each parked change given up on
  /// (`pending_change.parked_expired`, listed on the Pending Changes screen).
  Future<void> _expireParked(
    String accountId, {
    required String folder,
    required String? role,
  }) async {
    final expiry =
        await _state.expireParked(accountId, folder: folder, role: role);
    if (expiry.isEmpty) return;
    for (final row in expiry.droppedRows) {
      await _updateThread(accountId, row.mailboxPath, row.threadId ?? row.id);
      unawaited(
        _appLogger?.warn(
          'email.virtual_expired',
          'Removed the local copy of "${row.subject ?? '(no subject)'}" '
              '(${row.mailboxPath.isEmpty ? 'hidden' : row.mailboxPath}): '
              'its server copy did not arrive within '
              '${EmailStateWriter.parkedExpiry.inDays} days',
          accountId: accountId,
          mailboxPath: row.mailboxPath,
          data: {
            'removedEmailId': row.id,
            'messageId': row.messageId,
            'sentCopy': row.isVirtualSentCopy,
          },
        ),
      );
    }
    for (final id in expiry.changedRows) {
      await _rethreadRow(id);
    }
    for (final op in expiry.failedOps) {
      unawaited(
        _appLogger?.warn(
          'pending_change.parked_expired',
          'Gave up on a ${_describeChange(op)} that waited '
              '${EmailStateWriter.parkedExpiry.inDays} days for the server '
              'copy of its mail; listed on the Pending Changes screen',
          accountId: accountId,
          data: {
            'emailId': op.resourceId,
            'changeId': op.id,
            'changeType': op.changeType,
          },
        ),
      );
    }
  }

  /// App Log line for each row [EmailStateWriter.cleanUpGone] deleted whose
  /// failed change is still listed: the change stays on the Pending Changes
  /// screen without its mail.
  Future<void> _logCleanedWithFailures(
    String accountId,
    List<String> cleaned,
  ) async {
    final failed = await (_db.select(_db.pendingChanges)
          ..where(
            (t) => t.resourceId.isIn(cleaned) & t.state.equals(_failedState),
          ))
        .get();
    for (final change in failed) {
      unawaited(
        _appLogger?.warn(
          'pending_change.row_removed',
          'Removed a mail the server no longer has; its failed '
              '${_describeChange(change)} stays on the Pending Changes '
              'screen',
          accountId: accountId,
          data: {
            'removedEmailId': change.resourceId,
            'changeId': change.id,
            'changeType': change.changeType,
          },
        ),
      );
    }
  }

  Future<int> _flushPendingChangesImap(
    account_model.Account account,
    String password,
    List<PendingChangeRow> rows,
  ) async {
    final imap.ImapClient client;
    try {
      client = await _imapConnect(
        account,
        _effectiveUsername(account),
        password,
      );
    } catch (e) {
      // No change reached the server, so none is charged an attempt: a phone
      // offline for [_maxChangeAttempts] syncs must not silently drop the
      // user's queued actions. The next cycle retries; the sync's own connect
      // reports the failure (#1224).
      log('IMAP flush for ${account.id} skipped: connect failed ($e)');
      return 0;
    }
    var applied = 0;
    // Mails whose move/snooze/unsnooze/delete did not apply in this flush:
    // their later changes address the mail where that change would have put
    // it, so they wait (unclaimed, uncharged) for the next flush.
    final blocked = await _mailsInFlightElsewhere(
      account.id,
      selected: {for (final r in rows) r.id},
    );
    try {
      var next = 0;
      while (next < rows.length) {
        if (!client.isConnected) {
          // Lost between two changes: claim nothing more.
          log('IMAP flush for ${account.id} stopped: connection lost');
          break;
        }
        final batch = _imapMoveBatchAt(
          rows,
          next,
          batching: client.serverInfo.supportsUidPlus,
        );
        next += batch.length;
        final outcome = await _flushImapBatch(account, client, batch, blocked);
        applied += outcome.applied;
        if (outcome.connectionLost) break;
      }
    } finally {
      await closeImapClient(client);
    }
    return applied;
  }

  /// The run of pending changes starting at [rows][[start]] that can share
  /// one `UID MOVE`: consecutive plain moves (no snooze cleanup) with the same
  /// source and destination and distinct UIDs. Any other change is a run of
  /// one. Order is preserved, so a batch never jumps over another change.
  ///
  /// Only with [batching] (the server supports UIDPLUS): without `COPYUID`
  /// every batched row would still need its own MOVE + search afterwards,
  /// costing more round trips than it saves.
  List<PendingChangeRow> _imapMoveBatchAt(
    List<PendingChangeRow> rows,
    int start, {
    required bool batching,
  }) {
    final first = rows[start];
    final head = _plainImapMove(first);
    if (!batching || head == null) return [first];
    final uids = <int>{};
    final batch = <PendingChangeRow>[];
    for (var i = start; i < rows.length; i++) {
      final row = rows[i];
      if (batch.length == _maxImapMoveBatch) break;
      final move = _plainImapMove(row);
      if (move == null || move.key != head.key) break;
      if (!uids.add(move.uid)) break;
      batch.add(row);
    }
    return batch;
  }

  /// Batch key (`'<source>\u0000<dest>'`) and UID of a plain IMAP move that
  /// can be batched; null for anything else, including an unreadable payload
  /// (which then fails on its own, as a run of one).
  ({String key, int uid})? _plainImapMove(PendingChangeRow row) {
    if (row.changeType != 'move') return null;
    try {
      final payload = jsonDecode(row.payload) as Map<String, dynamic>;
      if (payload['clearSnooze'] == true) return null;
      // Its UID is not known yet: looked up on its own ([_currentImapUid]).
      if (payload[_uidAfterMoveKey] == true) return null;
      final src = payload['mailboxPath'];
      final dest = payload['dest'];
      final uid = payload['uid'];
      if (src is! String || dest is! String || uid is! int) return null;
      // Rows stamped with different UIDVALIDITYs never share a MOVE.
      return (
        key: '$src\u0000$dest\u0000${payload['uidValidity']}',
        uid: uid,
      );
    } catch (_) {
      return null;
    }
  }

  /// Applies [snapshots] — one change, or a batch from [_imapMoveBatchAt].
  ///
  /// A batch is claimed row by row, then moved with a single `UID MOVE`
  /// (#1224): one round trip instead of a SELECT + MOVE per message. Every
  /// row whose new UID the `COPYUID` reports is relocated and done; the rest
  /// (no UIDPLUS, a stale UID, a failed batch command) go through the
  /// one-by-one path, which re-checks where the message is.
  ///
  /// Skips the changes of mails in [blocked], and adds a mail to it when its
  /// move/snooze/unsnooze/delete does not apply (see
  /// [_flushPendingChangesImap]).
  Future<({int applied, bool connectionLost})> _flushImapBatch(
    account_model.Account account,
    imap.ImapClient client,
    List<PendingChangeRow> snapshots,
    Set<String> blocked,
  ) async {
    final claimed = <PendingChangeRow>[];
    for (final snapshot in snapshots) {
      if (blocked.contains(snapshot.resourceId)) continue;
      final row = await _claimPendingChange(snapshot);
      if (row == null) {
        // Cancelled, failed or claimed by another flush since the snapshot:
        // the mail's later changes wait for the next flush.
        blocked.add(snapshot.resourceId);
        continue;
      }
      if (await _namesFolderBeingChanged(row)) {
        // A folder it names is being renamed, moved or deleted by another
        // flush (checked after the claim, as the folder side does).
        await _unclaimPendingChange(row);
        blocked.add(row.resourceId);
        continue;
      }
      claimed.add(row);
    }
    if (claimed.isEmpty) return (applied: 0, connectionLost: false);

    var applied = 0;
    var pending = claimed;
    if (claimed.length > 1) {
      final batch = await _batchImapMove(client, claimed);
      if (batch.error case final e?) {
        if (_isImapConnectionLost(client, e)) {
          if (batch.moveSent) {
            // The MOVE may have reached the server: charge every row.
            for (final row in claimed) {
              await _recordChangeError(row, e);
            }
          } else {
            // Nothing reached the server: undo the claims, so a dropped
            // connection costs no attempts (and Undo can still cancel).
            for (final row in claimed) {
              await _unclaimPendingChange(row);
            }
          }
          log('IMAP flush for ${account.id} stopped: connection lost ($e)');
          return (applied: 0, connectionLost: true);
        }
        // E.g. `NO` for the whole set: let each row get its own outcome.
        log('IMAP batch move failed, applying one by one: $e');
      }
      for (final row in batch.moved) {
        await _settleApplied(row);
        applied++;
      }
      pending = [
        for (final row in claimed)
          if (!batch.moved.contains(row)) row,
      ];
    }

    for (var i = 0; i < pending.length; i++) {
      var row = pending[i];
      if (blocked.contains(row.resourceId)) {
        await _unclaimPendingChange(row);
        continue;
      }
      if (claimed.length > 1) {
        // Claimed with the whole batch: the one-by-one applies before this
        // one may have taken a while.
        final renewed = await _renewClaim(row);
        if (renewed == null) {
          blocked.add(row.resourceId);
          continue;
        }
        row = renewed;
      }
      final outcome = await _settleImapChange(account, client, row);
      if (outcome.connectionLost != null) {
        // Rows of this batch claimed but not reached: give the claim back.
        for (final rest in pending.skip(i + 1)) {
          await _unclaimPendingChange(rest);
        }
        return (applied: applied, connectionLost: true);
      }
      applied += outcome.applied;
      // A move/delete that did not apply holds back the mail's later
      // changes (they address it where it would have put it); so does any
      // change that is retried later, so the mail's changes keep their order
      // (a newer read/star change must not land before an older one). A
      // change that failed for good does not.
      if (outcome.applied == 0 &&
          (_placementChangeTypes.contains(row.changeType) ||
              await _stillQueued(row.id))) {
        blocked.add(row.resourceId);
      }
    }
    return (applied: applied, connectionLost: false);
  }

  /// Sends one `UID MOVE` for all [rows] (same source and destination) and
  /// relocates every row the `COPYUID` response maps. Returns those rows, the
  /// error that ended the attempt (if any), and whether the MOVE was sent.
  Future<({Set<PendingChangeRow> moved, Object? error, bool moveSent})>
      _batchImapMove(
    imap.ImapClient client,
    List<PendingChangeRow> rows,
  ) async {
    final payload = jsonDecode(rows.first.payload) as Map<String, dynamic>;
    final src = payload['mailboxPath'] as String;
    final dest = payload['dest'] as String;
    final uidOf = {
      for (final row in rows)
        row: (jsonDecode(row.payload) as Map<String, dynamic>)['uid'] as int,
    };
    try {
      final selected = await client.selectUnicodeMailboxByPath(src);
      final stamped = payload['uidValidity'];
      if (stamped is int &&
          selected.uidValidity != null &&
          selected.uidValidity != stamped) {
        // The UIDs may name other messages now: let the one-by-one path
        // look each up again by Message-ID ([_currentImapUid]).
        return (
          moved: <PendingChangeRow>{},
          error: StateError('UIDVALIDITY of $src changed'),
          moveSent: false,
        );
      }
    } catch (e) {
      return (moved: <PendingChangeRow>{}, error: e, moveSent: false);
    }
    // Taken before the MOVE (SYNC-REDESIGN.md §4.1): its answer is at least
    // this new.
    final moveSeq = await _state.nextReadSeq();
    final imap.GenericImapResult result;
    try {
      result = await client.uidMove(
        imap.MessageSequence.fromIds(uidOf.values.toList(), isUid: true),
        targetMailboxPath: dest,
      );
    } catch (e) {
      return (moved: <PendingChangeRow>{}, error: e, moveSent: true);
    }
    final moved = <PendingChangeRow>{};
    for (final MapEntry(key: row, value: uid) in uidOf.entries) {
      final newUid = _resolveCopyUid(result, uid);
      if (newUid == null) continue;
      // COPYUID maps it, so this only relocates the local row (no command).
      await _remapEmailAfterImapMove(
        client,
        oldId: row.resourceId,
        sourceUid: uid,
        destMailboxPath: dest,
        moveResult: result,
        seq: moveSeq,
      );
      moved.add(row);
    }
    return (moved: moved, error: null, moveSent: true);
  }

  /// The UID [row]'s change must act on in the selected [mailboxPath]. That
  /// is the payload's UID unless the folder's UIDVALIDITY changed since the
  /// change was queued ([_ChangeQueue._stampUidValidity]): the old UID may then name a
  /// different message, so the message is looked up again by Message-ID and
  /// acted on only when exactly one copy matches. Otherwise the change is
  /// moot ([_ImapMessageGoneException]): acting on the stale UID could flag,
  /// move or expunge someone else's mail.
  Future<int> _currentImapUid(
    imap.ImapClient client,
    PendingChangeRow row,
    Map<String, dynamic> payload, {
    required String mailboxPath,
    required int? selectedUidValidity,
  }) async {
    final uid = payload['uid'] as int;
    if (payload[_uidAfterMoveKey] == true) {
      return _uidAfterUnansweredMove(client, row, payload, mailboxPath);
    }
    final stamped = payload['uidValidity'];
    if (stamped is! int || selectedUidValidity == null) return uid;
    if (stamped == selectedUidValidity) return uid;
    // Only the Message-ID stamped at enqueue time: the local row behind
    // [row.resourceId] may be a different message since the reset.
    final messageId = payload['messageId'] as String?;
    final uids = await _searchUidsByMessageId(
      client,
      mailboxPath,
      messageId,
      throwOnFailure: true,
      select: false,
    );
    if (uids.length != 1) {
      throw _ImapUidValidityChangedException(
        'UIDVALIDITY of $mailboxPath changed ($stamped → '
        '$selectedUidValidity) and ${uids.isEmpty ? 'no' : 'more than one'} '
        'message matches its Message-ID',
      );
    }
    log(
      'IMAP change ${row.id}: UIDVALIDITY of $mailboxPath changed, '
      'UID $uid → ${uids.single} by Message-ID',
    );
    return uids.single;
  }

  /// The UID of [row]'s mail in the selected [mailboxPath] when the move
  /// queued before it reported none ([_ChangeQueue._markUidAfterQueuedMove]): its UID is
  /// the one from before that move, so the mail is looked up by Message-ID
  /// and acted on only when exactly one copy matches (#1266).
  Future<int> _uidAfterUnansweredMove(
    imap.ImapClient client,
    PendingChangeRow row,
    Map<String, dynamic> payload,
    String mailboxPath,
  ) async {
    final uids = await _searchUidsByMessageId(
      client,
      mailboxPath,
      payload['messageId'] as String?,
      throwOnFailure: true,
      select: false,
    );
    if (uids.length != 1) {
      throw _ImapMessageGoneException(
        'the move queued before this change reported no new UID, and '
        '${uids.isEmpty ? 'no' : 'more than one'} message in $mailboxPath '
        'matches its Message-ID',
      );
    }
    return uids.single;
  }

  /// Applies a marked move ([_ChangeQueue._markUidAfterQueuedMove]) from the selected
  /// [mailboxPath]: its UID is not known, so the mail is found by Message-ID
  /// there, or in the destination when an earlier attempt already moved it
  /// and the answer was lost ([_retryImapMoveByMessageId]).
  Future<void> _applyMoveAfterUnansweredMove(
    imap.ImapClient client,
    PendingChangeRow row,
    Map<String, dynamic> payload,
    String mailboxPath,
    _ImapUndoJournal undo,
  ) async {
    // A blank or `<>` Message-ID cannot find the mail either (#1327).
    final messageId = normaliseMessageId(payload['messageId'] as String?);
    if (messageId == null) {
      throw _ImapMessageGoneException(
        'the move queued before this one reported no new UID, and the mail '
        'has no Message-ID to find it by',
      );
    }
    await _retryImapMoveByMessageId(
      client,
      row: row,
      // No UID of this folder: none may count as "still in the source".
      staleUid: -1,
      mailboxPath: mailboxPath,
      destMailboxPath: payload['dest'] as String,
      messageId: messageId,
      // The source is selected; look in the destination before moving.
      movedNothing: true,
      beforeMove: payload['clearSnooze'] == true
          ? (s) => _removeImapSnoozeFlags(client, s, undo: undo)
          : null,
    );
  }

  /// The Message-ID of local email row [emailId], or null.
  Future<String?> _messageIdOf(String emailId) async {
    final row = await (_db.selectOnly(_db.emails)
          ..addColumns([_db.emails.messageId])
          ..where(_db.emails.id.equals(emailId))
          ..limit(1))
        .getSingleOrNull();
    return row?.read(_db.emails.messageId);
  }

  /// True when [error] means [client]'s connection is gone, whatever the
  /// error's wording: a recognised connection error, or enough_mail reporting
  /// the socket closed.
  bool _isImapConnectionLost(imap.ImapClient client, Object error) =>
      isImapConnectionLost(error) || !client.isConnected;

  /// Applies one claimed [row] and settles it: deleted when applied, marked
  /// failed when it can never apply, error recorded otherwise.
  /// `connectionLost` carries the error when the connection died, so the
  /// caller stops the flush.
  Future<({int applied, Object? connectionLost})> _settleImapChange(
    account_model.Account account,
    imap.ImapClient client,
    PendingChangeRow row,
  ) async {
    try {
      await _applyPendingChangeImap(client, row);
      // A delete for good expunged the mail: gone, as of the ack.
      await _settleApplied(row, confirmedGone: row.changeType == 'delete');
      return (applied: 1, connectionLost: null);
    } catch (e) {
      if (_isImapConnectionLost(client, e)) {
        // The connection is dead (e.g. network switch on mobile): every
        // further command would fail too. Count this attempt and leave the
        // remaining, unclaimed changes untouched for the next sync's fresh
        // connection. A command that merely timed out stops the flush too;
        // if one change keeps timing out, it is stuck after
        // [_maxChangeAttempts] and then tried only after its backoff.
        await _recordChangeError(row, e);
        log('IMAP flush for ${account.id} stopped: connection lost ($e)');
        return (applied: 0, connectionLost: e);
      }
      if (e is _ImapUidValidityChangedException) {
        // The folder was renumbered and the message cannot be identified
        // safely: mark the change failed rather than act on someone else's
        // mail. Nothing to go back to: the mail is not known there.
        if (!await _markChangeFailed(row, e, revert: false)) {
          return (applied: 0, connectionLost: null);
        }
        log('IMAP change ${row.id} failed: $e');
        unawaited(
          _appLogger?.warn(
            'pending_change.uidvalidity_changed',
            'Could not apply ${_describeChange(row)} — the server renumbered '
                'the folder and the message could not be found again; kept '
                'on the Pending Changes screen',
            accountId: account.id,
            emailId: row.resourceId,
            data: {'changeType': row.changeType},
            error: e,
          ),
        );
        return (applied: 0, connectionLost: null);
      }
      if (e is _ImapTargetVanishedException) {
        if (await _keepForForeignMove(account, row, e)) {
          return (applied: 0, connectionLost: null);
        }
        return _failMessageGone(
          account,
          row,
          _ImapMessageGoneException(e.message),
        );
      }
      if (e is _ImapMessageGoneException) {
        return _failMessageGone(account, row, e);
      }
      if (e is _ImapSourceSelectFailedException) {
        // Not a definite "gone": kept and retried with backoff. Logged once
        // per folder and pass.
        log('IMAP change ${row.id}: source folder not opened, kept ($e)');
        if (!e.repeat) {
          unawaited(
            _appLogger?.warn(
              'pending_change.select_failed_kept',
              'Could not open the folder of ${_describeChange(row)}; it reads '
                  'like "no such folder", but the server did not say '
                  'NONEXISTENT and still lists it (or its listing could not be '
                  'read): the change is kept and tried again',
              accountId: account.id,
              emailId: row.resourceId,
              data: {'changeType': row.changeType},
              error: e.cause,
            ),
          );
        }
        await _recordChangeError(row, e.cause);
        return (applied: 0, connectionLost: null);
      }
      if (isImapPermanentBad(e)) {
        // A tagged `BAD` about the command itself (a flag or path the server
        // rejects): the same command would get it again. Checked before the
        // "not found" wording, which a `BAD` text may contain without saying
        // that anything is gone.
        await _failOnImapBad(row, e);
        return (applied: 0, connectionLost: null);
      }
      final sourceGone = e is _ImapSourceMailboxGoneException;
      if (!sourceGone &&
          isImapMailboxNotFound(e) &&
          _locationChangeTypes.contains(row.changeType)) {
        // The source folder was selected, so the mail is still there: a
        // missing destination (`NO [TRYCREATE]` from the MOVE) means the
        // move did not happen. Mark it failed and show the mail where it is.
        if (!await _markChangeFailed(row, e)) {
          return (applied: 0, connectionLost: null);
        }
        log('IMAP change ${row.id} failed: destination missing ($e)');
        unawaited(
          _appLogger?.warn(
            'pending_change.dest_missing',
            'Could not apply ${_describeChange(row)} — the destination '
                'folder does not exist on the server; kept on the Pending '
                'Changes screen',
            accountId: account.id,
            emailId: row.resourceId,
            data: {'changeType': row.changeType},
            error: e,
          ),
        );
        return (applied: 0, connectionLost: null);
      }
      if (sourceGone || isImapMailboxNotFound(e)) {
        // The mail's folder is gone on the server, and the mail with it
        // (or, for a flag change or delete, the target is gone): treat as
        // success so the change doesn't accumulate or block future changes.
        final (:owned, :dropped) = await _db.transaction(() async {
          final owned = await (_db.delete(_db.pendingChanges)
                    ..where((t) => _ownsClaim(t, row)))
                  .go() >
              0;
          // A moved row sits in its destination with the deleted folder's
          // UID, naming whichever mail has that UID there (#1268). Only
          // while this flush still owns the change.
          final dropped = owned && sourceGone ? await _dropGoneRow(row) : null;
          // The change no longer folds into a row that is still there.
          if (owned && dropped == null) {
            await _refoldAndRethread(row.resourceId);
          }
          return (owned: owned, dropped: dropped);
        });
        if (!owned) return (applied: 0, connectionLost: null);
        log('IMAP change ${row.id} skipped: message already gone ($e)');
        // A warn: the user's change is dropped as applied without the
        // server having done it (its folder is gone, e.g. renamed or
        // deleted elsewhere).
        unawaited(
          _appLogger?.warn(
            'pending_change.skipped_gone',
            'Skipped ${_describeChange(row)} — its folder or message is '
                'gone on the server; the change is dropped as done',
            accountId: account.id,
            emailId: dropped != null ? null : row.resourceId,
            data: {'changeType': row.changeType},
          ),
        );
        _logGoneRowDropped(
          row,
          dropped,
          why: 'a skipped ${_describeChange(row)}: its source folder no '
              'longer exists on the server',
        );
        return (applied: 1, connectionLost: null);
      }
      if (isImapPermanentRefusal(e) || e is FormatException || e is TypeError) {
        // `NO [CANNOT]`, `[NOPERM]`, …, or a payload this app cannot read:
        // retrying cannot help. Failed at once, and the mail shows the
        // server's state again.
        if (!await _markChangeFailed(row, e)) {
          return (applied: 0, connectionLost: null);
        }
        log('IMAP change ${row.id} refused: $e');
        unawaited(
          _appLogger?.error(
            'pending_change.rejected',
            'Server rejected ${_describeChange(row)}; kept on the Pending '
                'Changes screen',
            accountId: account.id,
            emailId: row.resourceId,
            data: {'changeType': row.changeType},
            error: e,
          ),
        );
        return (applied: 0, connectionLost: null);
      }
      await _recordChangeError(row, e);
      return (applied: 0, connectionLost: null);
    }
  }

  /// Settles [row] as failed because its message is gone ([e]): retrying
  /// cannot bring the message back, but the user's change (e.g. an Undo's
  /// reverse move, #1048) did not happen. Marks the change failed and says
  /// so in the App Log at warn level; a move whose message is in neither
  /// its source nor its destination also drops the row
  /// ([_ChangeFailures._dropGoneRow]).
  Future<({int applied, Object? connectionLost})> _failMessageGone(
    account_model.Account account,
    PendingChangeRow row,
    _ImapMessageGoneException e,
  ) async {
    // One transaction: a phantom row must not outlive a crash here.
    final (:dependents, :dropped) = await _db.transaction(() async {
      final dependents =
          await _markChangeFailedInTransaction(row, e, revert: false);
      // A lost claim's outcome is not ours to act on.
      if (dependents == null) return (dependents: null, dropped: null);
      final dropped = e.inNeitherMailbox ? await _dropGoneRow(row) : null;
      return (dependents: dependents, dropped: dropped);
    });
    if (dependents == null) return (applied: 0, connectionLost: null);
    log('IMAP change ${row.id} failed: $e');
    unawaited(
      _appLogger?.warn(
        'pending_change.message_gone',
        'Could not apply ${_describeChange(row)} — the message is no '
            'longer on the server (deleted or moved by another client); '
            'kept on the Pending Changes screen',
        accountId: account.id,
        // A log row must not reference the email row just dropped.
        emailId: dropped != null ? null : row.resourceId,
        data: {'changeType': row.changeType},
        error: e,
      ),
    );
    _logDependentFailures(row, dependents);
    _logGoneRowDropped(
      row,
      dropped,
      why: 'a failed ${_describeChange(row)}: the message is in neither '
          'its source nor its destination folder on the server',
    );
    return (applied: 0, connectionLost: null);
  }

  /// [row]'s flag `STORE` hit no mail ([e]): the UID it addressed is gone
  /// from its folder (#1326). When that UID is where the row's server
  /// location still says the mail is, the sync of that folder has not seen
  /// it vanish yet: it carries the row over to the mail's new place
  /// (another client moved it, SYNC.md §3) and points the queued changes
  /// there, or finds it gone. So the change is kept, charged an attempt
  /// ([_ChangeFailures._recordChangeError]), and every queued change of the
  /// mail that addresses the same UID is marked ([_srcVanishedKey]): a
  /// move or delete marked so does not explain the mail's absence, so the
  /// sync still carries the row over. Returns false when the sync already
  /// knows the mail is gone (or the change addressed another place): then
  /// the caller fails it visibly.
  Future<bool> _keepForForeignMove(
    account_model.Account account,
    PendingChangeRow row,
    _ImapTargetVanishedException e,
  ) async {
    final payload = _decodePayload(row);
    if (payload == null || payload[_uidAfterMoveKey] == true) return false;
    final addressed = payload['mailboxPath'] ?? payload['src'];
    final uid = payload['uid'];
    final email = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(row.resourceId)))
        .getSingleOrNull();
    if (email == null ||
        email.srvGone ||
        email.isLocal ||
        email.srvMailboxPath != addressed ||
        email.srvUid != uid) {
      return false;
    }
    final held = await _db.transaction(() async {
      final live = await (_db.select(_db.pendingChanges)
            ..where(
              (t) =>
                  t.resourceId.equals(row.resourceId) &
                  t.state.isIn(_liveStates),
            ))
          .get();
      final ids = <int>[];
      for (final change in live) {
        final p = _decodePayload(change);
        if (p == null ||
            (p['mailboxPath'] ?? p['src']) != addressed ||
            p['uid'] != uid ||
            p[_uidAfterMoveKey] == true ||
            // A delete never follows the mail: it would expunge it wherever
            // another client put it (restored from Trash, say). It stays
            // unmarked, so the mail's absence settles it as moot.
            change.changeType == 'delete') {
          continue;
        }
        ids.add(change.id);
        if (p[_srcVanishedKey] == true) continue;
        p[_srcVanishedKey] = true;
        await (_db.update(_db.pendingChanges)
              ..where((t) => t.id.equals(change.id)))
            .write(PendingChangesCompanion(payload: Value(jsonEncode(p))));
      }
      return ids;
    });
    log('IMAP change ${row.id} kept: $e');
    unawaited(
      _appLogger?.warn(
        'pending_change.target_vanished',
        'Did not apply ${_describeChange(row)} yet: UID $uid in $addressed '
            'no longer holds "${email.subject ?? '(no subject)'}" (moved or '
            'deleted by another client), and the server answered OK without '
            'changing anything. Kept: the next sync finds where the mail '
            'went and the change is sent there, or it fails visibly',
        accountId: account.id,
        emailId: row.resourceId,
        mailboxPath: addressed is String ? addressed : null,
        data: {
          'changeType': row.changeType,
          'changeId': row.id,
          'uid': uid,
          'heldChangeIds': held,
        },
      ),
    );
    await _recordChangeError(row, e);
    return true;
  }

  /// Marks [row] failed at once after a command of it got a tagged `BAD`
  /// [error] about the command itself ([isImapPermanentBad]), with an App
  /// Log warn that quotes the server. The mail shows the server's state
  /// again; Retry / Discard are on the Pending Changes screen.
  Future<void> _failOnImapBad(PendingChangeRow row, Object error) async {
    if (!await _markChangeFailed(row, error)) return;
    log('IMAP change ${row.id} failed: BAD answer ($error)');
    _logImapBadFailure(row, error);
  }

  Future<void> _applyPendingChangeImap(
    imap.ImapClient client,
    PendingChangeRow row,
  ) async {
    final payload = jsonDecode(row.payload) as Map<String, dynamic>;
    // snooze/unsnooze payloads use 'src' for the source folder; all others use 'mailboxPath'.
    final mailboxPath = (payload['mailboxPath'] ?? payload['src']) as String;
    final failedBefore = _vagueSelectFailures[client]?[mailboxPath];
    if (failedBefore != null) {
      throw _ImapSourceSelectFailedException(failedBefore, repeat: true);
    }
    final imap.Mailbox selected;
    try {
      selected = await client.selectUnicodeMailboxByPath(mailboxPath);
    } catch (e) {
      // A `BAD` about the command fails the change, even when its text
      // reads like "not found": it does not say the folder is gone.
      if (isImapPermanentBad(e) || !isImapMailboxNotFound(e)) rethrow;
      // Dropping the change as moot (and the row a move left) needs a
      // definite answer (#1312).
      if (!await confirmImapMailboxGone(client, mailboxPath, e)) {
        (_vagueSelectFailures[client] ??= {})[mailboxPath] = e;
        throw _ImapSourceSelectFailedException(e, repeat: false);
      }
      throw _ImapSourceMailboxGoneException(e);
    }
    final undo = _ImapUndoJournal(client, mailboxPath);
    try {
      await _sendImapChange(client, row, payload, mailboxPath, selected, undo);
    } catch (e) {
      if (isImapPermanentBad(e) || isImapPermanentRefusal(e)) {
        await _undoImapEdits(row, undo, e);
      }
      rethrow;
    }
  }

  /// After [row] was refused for good with [error]: undoes, as a best
  /// effort, the flag edits its earlier commands made on the server
  /// ([undo]), e.g. the `\Deleted` of a delete whose EXPUNGE was refused, and
  /// says in the App Log what was undone or could not be.
  Future<void> _undoImapEdits(
    PendingChangeRow row,
    _ImapUndoJournal undo,
    Object error,
  ) async {
    if (undo.isEmpty) return;
    final failure = await undo.run();
    unawaited(
      _appLogger?.warn(
        'pending_change.server_edits_undone',
        failure == null
            ? 'Undid the flag edits ${_describeChange(row)} had made on the '
                'server before it was refused'
            : 'Could not undo the flag edits ${_describeChange(row)} had '
                'made on the server before it was refused (e.g. the mail '
                'stays marked deleted or keeps its snooze keyword there): '
                '$failure',
        accountId: row.accountId,
        emailId: row.resourceId,
        data: {'changeType': row.changeType, 'changeId': row.id},
        error: error,
      ),
    );
  }

  /// Sends [row] to [mailboxPath], selected as [selected]; flag edits that
  /// a later refused command would leave behind go into [undo].
  Future<void> _sendImapChange(
    imap.ImapClient client,
    PendingChangeRow row,
    Map<String, dynamic> payload,
    String mailboxPath,
    imap.Mailbox selected,
    _ImapUndoJournal undo,
  ) async {
    if (row.changeType == 'move' && payload[_uidAfterMoveKey] == true) {
      await _applyMoveAfterUnansweredMove(
        client,
        row,
        payload,
        mailboxPath,
        undo,
      );
      return;
    }
    final uid = await _currentImapUid(
      client,
      row,
      payload,
      mailboxPath: mailboxPath,
      selectedUidValidity: selected.uidValidity,
    );
    final seq = imap.MessageSequence.fromId(uid, isUid: true);
    if (_locationChangeTypes.contains(row.changeType) &&
        normaliseMessageId(
              payload['messageId'] as String? ??
                  await _messageIdOf(row.resourceId),
            ) ==
            null &&
        !await _uidIsThere(client, seq)) {
      // Without a Message-ID nothing after the MOVE can find the mail: the
      // UID must be there before it (#1327), or a MOVE of a UID another
      // client emptied would count as done. (A `COPYUID` alone is no proof
      // either way: a client library may drop the untagged one.)
      throw _ImapMessageGoneException(
        'UID $uid is gone from $mailboxPath, and the mail has no '
        'Message-ID to find it by',
      );
    }

    switch (row.changeType) {
      case 'flag_seen':
        final seen = payload['seen'] as bool;
        await _storeOnMail(
          client,
          seq,
          mailboxPath,
          () => seen ? client.uidMarkSeen(seq) : client.uidMarkUnseen(seq),
        );
      case 'flag_flagged':
        final flagged = payload['flagged'] as bool;
        await _storeOnMail(
          client,
          seq,
          mailboxPath,
          () => flagged
              ? client.uidMarkFlagged(seq)
              : client.uidMarkUnflagged(seq),
        );
      case 'add_keywords':
        final keywords = (payload['keywords'] as List<dynamic>).cast<String>();
        await _storeOnMail(
          client,
          seq,
          mailboxPath,
          () => client.uidStore(seq, keywords, action: imap.StoreAction.add),
        );
      case 'move':
        final dest = payload['dest'] as String;
        if (payload['clearSnooze'] == true) {
          await _removeImapSnoozeFlags(client, seq, undo: undo);
        }
        if (dest == mailboxPath) {
          // The mail is in the destination already: another client moved it
          // there, and the carry-over pointed the move at it (#1327).
          log('IMAP change ${row.id}: already in $dest, nothing to move');
          unawaited(
            _appLogger?.info(
              'pending_change.already_in_dest',
              'The ${_describeChange(row)} to $dest is done without a '
                  'command: another client had moved the mail there',
              accountId: row.accountId,
              emailId: row.resourceId,
              mailboxPath: dest,
              data: {'changeType': row.changeType, 'changeId': row.id},
            ),
          );
          return;
        }
        final moveSeq = await _state.nextReadSeq();
        final result = await client.uidMove(seq, targetMailboxPath: dest);
        final movedNothing = _imapMoveMovedNothing(client, result);
        if (!movedNothing &&
            await _remapEmailAfterImapMove(
              client,
              oldId: row.resourceId,
              sourceUid: uid,
              destMailboxPath: dest,
              moveResult: result,
              seq: moveSeq,
            )) {
          return;
        }
        await _retryImapMoveByMessageId(
          client,
          row: row,
          staleUid: uid,
          mailboxPath: mailboxPath,
          destMailboxPath: dest,
          messageId: payload['messageId'] as String?,
          movedNothing: movedNothing,
          beforeMove: payload['clearSnooze'] == true
              ? (s) => _removeImapSnoozeFlags(client, s, undo: undo)
              : null,
        );
      case 'delete':
        if (!await _uidIsThere(client, seq)) {
          // Nothing to expunge here; the mail is not looked for elsewhere:
          // another client may have restored it, and a delete must not
          // follow it there (#1327).
          await _logDeleteMoot(row, uid: uid, mailboxPath: mailboxPath);
          return;
        }
        // A refused EXPUNGE must not leave the mail flagged `\Deleted`:
        // any client's next EXPUNGE would remove it.
        undo.add(() => client.uidMarkUndeleted(seq));
        await deleteAndExpungeUids(client, [uid]);
      case 'snooze':
        final until = payload['until'] as String;
        // ISO8601 with colons is fine for IMAP atoms, but we use a cleaner
        // format just in case.
        final timestamp = until.replaceAll(':', '').replaceAll('-', '');
        final keyword = 'snz:$timestamp';
        // The Snoozed folder exists: the snooze waited for its queued
        // create (phase 5b), never created on the side here.
        final dest = payload['dest'] as String;
        // A re-snooze replaces the earlier snooze keyword: with both, sync
        // would read back whichever comes first.
        final resnooze = payload['prevSnoozedUntil'] != null;
        Future<void> tag(imap.MessageSequence s) async {
          if (resnooze) await _removeImapSnoozeFlags(client, s, undo: undo);
          await client.uidStore(s, [keyword], action: imap.StoreAction.add);
          undo.add(
            () => client.uidStore(
              s,
              [keyword],
              action: imap.StoreAction.remove,
            ),
          );
        }

        await tag(seq);
        final moveSeq = await _state.nextReadSeq();
        final snoozeResult = await client.uidMove(seq, targetMailboxPath: dest);
        final movedNothing = _imapMoveMovedNothing(client, snoozeResult);
        if (!movedNothing &&
            await _remapEmailAfterImapMove(
              client,
              oldId: row.resourceId,
              sourceUid: uid,
              destMailboxPath: dest,
              moveResult: snoozeResult,
              seq: moveSeq,
            )) {
          return;
        }
        // A stale UID (e.g. Undo re-snoozing a row rebuilt from its snapshot)
        // makes STORE + MOVE silent no-ops: re-find the message like a move.
        await _retryImapMoveByMessageId(
          client,
          row: row,
          staleUid: uid,
          mailboxPath: mailboxPath,
          destMailboxPath: dest,
          messageId: payload['messageId'] as String?,
          beforeMove: tag,
          movedNothing: movedNothing,
        );
      case 'unsnooze':
        // Back to the inbox, which exists; a folder that is gone is not
        // created again on the side (a failed move, listed, instead).
        final dest = payload['dest'] as String;
        await _removeImapSnoozeFlags(client, seq, undo: undo);
        final moveSeq = await _state.nextReadSeq();
        final unsnoozeResult =
            await client.uidMove(seq, targetMailboxPath: dest);
        final unsnoozedNothing = _imapMoveMovedNothing(client, unsnoozeResult);
        if (!unsnoozedNothing &&
            await _remapEmailAfterImapMove(
              client,
              oldId: row.resourceId,
              sourceUid: uid,
              destMailboxPath: dest,
              moveResult: unsnoozeResult,
              seq: moveSeq,
            )) {
          return;
        }
        // E.g. another device woke the mail first: find it like a move, so
        // the row is relocated where it is, or dropped when it is gone,
        // instead of keeping the Snoozed folder's UID in [dest] (#1268).
        await _retryImapMoveByMessageId(
          client,
          row: row,
          staleUid: uid,
          mailboxPath: mailboxPath,
          destMailboxPath: dest,
          messageId: payload['messageId'] as String?,
          beforeMove: (s) => _removeImapSnoozeFlags(client, s, undo: undo),
          movedNothing: unsnoozedNothing,
        );
      case 'clear_snooze':
        await _clearImapSnoozeFlags(
          client,
          row: row,
          uid: uid,
          mailboxPath: mailboxPath,
        );
    }
  }

  /// Sends [store], a flag `UID STORE` of the single UID [seq] in the
  /// selected [mailboxPath], and makes sure it hit a mail: a server answers
  /// a STORE of a UID that no longer exists with OK and changes nothing
  /// (#1326). The untagged FETCH it sends for the UID shows the hit; without
  /// one (a server that sends none for an unchanged flag, or none with the
  /// UID), a `UID FETCH … FLAGS` asks whether the UID is still there.
  /// Throws [_ImapTargetVanishedException] when it is not.
  Future<void> _storeOnMail(
    imap.ImapClient client,
    imap.MessageSequence seq,
    String mailboxPath,
    Future<imap.StoreImapResult> Function() store,
  ) async {
    final uid = seq.toList().single;
    final result = await store();
    if (result.changedMessages?.any((m) => m.uid == uid) ?? false) return;
    final there = await client.uidFetchMessages(seq, 'FLAGS');
    if (there.messages.any((m) => m.uid == uid)) return;
    throw _ImapTargetVanishedException(
      'UID $uid is gone from $mailboxPath: the STORE answered OK but '
      'changed nothing',
    );
  }

  /// Whether the selected folder has a message at the single UID [seq]:
  /// a `UID FETCH … FLAGS` names it (an unsolicited FETCH without the UID
  /// does not count).
  Future<bool> _uidIsThere(
    imap.ImapClient client,
    imap.MessageSequence seq,
  ) async {
    final uid = seq.toList().single;
    final there = await client.uidFetchMessages(seq, 'FLAGS');
    return there.messages.any((m) => m.uid == uid);
  }

  /// App Log warn for [row], a delete for good whose [uid] is gone from
  /// [mailboxPath]: settled as done without a command. Another client
  /// deleted the mail, or moved it elsewhere, where it stays: the delete
  /// does not follow it (#1327). Which of the two is not known here.
  Future<void> _logDeleteMoot(
    PendingChangeRow row, {
    required int uid,
    required String mailboxPath,
  }) async {
    final email = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(row.resourceId)))
        .getSingleOrNull();
    log('IMAP change ${row.id}: UID $uid gone from $mailboxPath, delete moot');
    unawaited(
      _appLogger?.warn(
        'pending_change.delete_moot',
        'Did not apply the delete of '
            '"${email?.subject ?? '(no subject)'}": UID $uid is no longer '
            'in $mailboxPath (deleted or moved by another client). If it was '
            'moved elsewhere it stays there; the delete does not follow it',
        accountId: row.accountId,
        emailId: row.resourceId,
        mailboxPath: mailboxPath,
        data: {'changeType': row.changeType, 'changeId': row.id, 'uid': uid},
      ),
    );
  }

  /// Removes every `snz:` snooze keyword from the message at [seq] in the
  /// selected mailbox, so a later sync does not read the snooze back.
  /// Returns false when no message exists at [seq] (a stale UID).
  Future<bool> _removeImapSnoozeFlags(
    imap.ImapClient client,
    imap.MessageSequence seq, {
    _ImapUndoJournal? undo,
  }) async {
    final fetch = await client.uidFetchMessages(seq, 'FLAGS');
    if (fetch.messages.isEmpty) return false;
    final flags = fetch.messages.first.flags ?? [];
    final snzFlags = flags.where((f) => f.startsWith('snz:')).toList();
    if (snzFlags.isEmpty) return true;
    await client.uidStore(seq, snzFlags, action: imap.StoreAction.remove);
    undo?.add(
      () => client.uidStore(seq, snzFlags, action: imap.StoreAction.add),
    );
    return true;
  }

  /// IMAP `clear_snooze`: strips the `snz:` flags at the queued UID or, when
  /// that UID went stale, at the message re-found by Message-ID. Logs a
  /// warning when it cannot be found at all; the change is not retried since
  /// a missing message has no keyword to keep reading back.
  Future<void> _clearImapSnoozeFlags(
    imap.ImapClient client, {
    required PendingChangeRow row,
    required int uid,
    required String mailboxPath,
  }) async {
    if (await _removeImapSnoozeFlags(
      client,
      imap.MessageSequence.fromId(uid, isUid: true),
    )) {
      return;
    }
    final local = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(row.resourceId)))
        .getSingleOrNull();
    final found =
        await _searchUidByMessageId(client, mailboxPath, local?.messageId);
    if (found != null &&
        found != uid &&
        await _removeImapSnoozeFlags(
          client,
          imap.MessageSequence.fromId(found, isUid: true),
        )) {
      return;
    }
    unawaited(
      _appLogger?.warn(
        'email.snooze_cleanup_missed',
        'Could not clear the snooze keyword: UID $uid is gone from '
            '$mailboxPath and the message was not found by Message-ID',
        accountId: row.accountId,
        emailId: row.resourceId,
        mailboxPath: mailboxPath,
      ),
    );
  }

  /// Handles a `UID MOVE` that reported OK but whose message could not be
  /// found in [destMailboxPath] afterwards — or, with [movedNothing], that
  /// visibly moved nothing: then the source, still selected, is searched
  /// without another SELECT (#1224). Servers accept a MOVE of a UID that
  /// does not exist as a no-op, so a stale [staleUid] (e.g. Undo's reverse move
  /// queued before the original move relocated the row) would otherwise be
  /// dropped as "applied" while the message stays put (#1048).
  ///
  /// Re-resolves the UID in [mailboxPath] by Message-ID and moves that one,
  /// running [beforeMove] on it first (snooze flag edits ride along).
  /// Shared by `move` and `snooze`.
  /// When the message is no longer in [mailboxPath] but already sits in
  /// [destMailboxPath] (an earlier attempt moved it, but the remap missed it,
  /// e.g. a lagging search index), the move is treated as applied: [beforeMove]
  /// runs there and the row is relocated (#1201).
  /// Throws [_ImapMessageGoneException] when the message is in neither
  /// mailbox (deleted or moved elsewhere by another client), so the flush
  /// drops the change and logs it as already gone. Throws [StateError] when
  /// the MOVE had no effect although the message is still there, so the
  /// change is retried and the failure lands in the App Log.
  /// Without any Message-ID to verify against, the MOVE counts as applied
  /// when its UID, there right before it, is gone from the source after it;
  /// otherwise it throws [StateError] (retried).
  Future<void> _retryImapMoveByMessageId(
    imap.ImapClient client, {
    required PendingChangeRow row,
    required int staleUid,
    required String mailboxPath,
    required String destMailboxPath,
    required String? messageId,
    Future<void> Function(imap.MessageSequence seq)? beforeMove,
    bool movedNothing = false,
  }) async {
    final local = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(row.resourceId)))
        .getSingleOrNull();
    final mid = messageId ?? local?.messageId;
    if (normaliseMessageId(mid) == null) {
      // Nothing to look for the mail by. [_sendImapChange] made sure the
      // UID was in the source right before the MOVE (#1327); the source is
      // still selected. Gone from it now: the MOVE moved it (its COPYUID,
      // if any, was not seen). Still there: it did nothing.
      if (staleUid < 0 ||
          !await _uidIsThere(
            client,
            imap.MessageSequence.fromId(staleUid, isUid: true),
          )) {
        return;
      }
      throw StateError(
        'MOVE of UID $staleUid from $mailboxPath to $destMailboxPath had no '
        'effect: the UID is still in $mailboxPath',
      );
    }
    // Taken before the searches: a location they find is at least this new.
    final searchSeq = await _state.nextReadSeq();

    // After a MOVE that moved nothing, the source is still selected.
    final resolvedUid = await _searchUidByMessageId(
      client,
      mailboxPath,
      mid,
      throwOnFailure: true,
      select: !movedNothing,
    );
    // True when the message already sits in the destination: then the move
    // happened (an earlier attempt, or a remap that missed it because the
    // server's index lags, e.g. Exchange), so it is finished there.
    // With [sourceEmpty] (no copy left in the source), a row sync already
    // fetched at the destination UID is this very mail and may be merged.
    Future<bool> finishedInDestination({required bool sourceEmpty}) async {
      final destUid = await _searchUidByMessageId(
        client,
        destMailboxPath,
        mid,
        throwOnFailure: true,
      );
      if (destUid == null) return false;
      int? destValidity;
      try {
        destValidity =
            (await client.selectUnicodeMailboxByPath(destMailboxPath))
                .uidValidity;
        await beforeMove
            ?.call(imap.MessageSequence.fromId(destUid, isUid: true));
      } catch (e) {
        // The move happened: a refusal of the flag edit after it must not
        // fail the change, which would show the mail in its source again.
        if (!isImapPermanentBad(e) && !isImapPermanentRefusal(e)) rethrow;
        log('IMAP change ${row.id}: moved, but its flag edit in '
            '$destMailboxPath was refused ($e)');
        unawaited(
          _appLogger?.warn(
            'pending_change.dest_flags_refused',
            'The ${_describeChange(row)} is done, but the server refused '
                'its flag edit in $destMailboxPath (e.g. the snooze keyword '
                'is not set there)',
            accountId: row.accountId,
            emailId: row.resourceId,
            data: {'changeType': row.changeType, 'changeId': row.id},
            error: e,
          ),
        );
      }
      await _relocateEmailAfterImapMove(
        id: row.resourceId,
        destMailboxPath: destMailboxPath,
        newUid: destUid,
        mergeDuplicate: sourceEmpty,
        seq: searchSeq,
        uidValidity: destValidity,
      );
      // Possibly moved there by another client, after read/star changes of
      // ours went to the UID it had left: the flags it has there are not
      // known locally, and CONDSTORE need not report it again.
      await _makeFlagReconcileDue(row.accountId, destMailboxPath, jmap: false);
      return true;
    }

    if (resolvedUid == null) {
      if (await finishedInDestination(sourceEmpty: true)) return;
      // In neither mailbox and both searches succeeded: another client already
      // deleted or moved it. Retrying can never succeed, so the flush drops
      // the change as "already gone". A failed search throws instead (see
      // `throwOnFailure`), so it is retried rather than mistaken for "gone".
      throw _ImapMessageGoneException(
        'MOVE of UID $staleUid from $mailboxPath to $destMailboxPath had no '
        'effect: message $mid is in neither mailbox',
        inNeitherMailbox: true,
      );
    }
    if (resolvedUid == staleUid) {
      // Wording must not match [isImapMailboxNotFound], which would treat
      // the change as applied.
      throw StateError(
        'MOVE of UID $staleUid from $mailboxPath to $destMailboxPath had no '
        'effect: message $mid is still in $mailboxPath',
      );
    }
    // The destination was not checked yet after a MOVE that moved nothing:
    // if ours is there, the match in the source is another copy with the
    // same Message-ID (e.g. cross-posted list mail), not to be moved.
    if (movedNothing && await finishedInDestination(sourceEmpty: false)) {
      return;
    }
    await client.selectUnicodeMailboxByPath(mailboxPath);
    final resolvedSeq = imap.MessageSequence.fromId(resolvedUid, isUid: true);
    await beforeMove?.call(resolvedSeq);
    final moveSeq = await _state.nextReadSeq();
    final result = await client.uidMove(
      resolvedSeq,
      targetMailboxPath: destMailboxPath,
    );
    final located = await _remapEmailAfterImapMove(
      client,
      oldId: row.resourceId,
      sourceUid: resolvedUid,
      destMailboxPath: destMailboxPath,
      moveResult: result,
      seq: moveSeq,
    );
    if (located) return;
    throw StateError(
      'MOVE of UID $resolvedUid from $mailboxPath to $destMailboxPath had no '
      'effect: message $mid is missing from $destMailboxPath',
    );
  }

  /// Records the new server location of the local row after an IMAP MOVE so
  /// the cache keeps tracking the same physical message under its new
  /// (mailbox, UID).
  ///
  /// The new UID is taken from the RFC 4315 `COPYUID` response code first
  /// (every modern server advertises `UIDPLUS`). If that's missing we fall
  /// back to `UID SEARCH HEADER Message-ID …` in the destination mailbox.
  /// When neither yields a UID we leave the row in place; the next sync
  /// cycle will re-fetch it as a new message and reconciliation will drop
  /// the stale source-side row.
  ///
  /// Returns false only when the moved message could not be located in
  /// [destMailboxPath]; true when it was (or there is no local row to remap).
  Future<bool> _remapEmailAfterImapMove(
    imap.ImapClient client, {
    required String oldId,
    required int sourceUid,
    required String destMailboxPath,
    required imap.GenericImapResult moveResult,
    int? seq,
  }) async {
    final row = await (_db.select(_db.emails)..where((t) => t.id.equals(oldId)))
        .getSingleOrNull();
    final copyUid = _resolveCopyUid(moveResult, sourceUid);
    // Deleted for good meanwhile (gone, or hidden by its queued delete) and
    // the new UID unknown: its queued delete still needs the UID, and only a
    // unique match may be trusted with that.
    if (row == null || (row.localHidden && copyUid == null)) {
      final newUid =
          copyUid ?? await _uniqueUidOfQueued(client, oldId, destMailboxPath);
      if (newUid != null) {
        await _repointQueuedChanges(
          oldId: oldId,
          destMailboxPath: destMailboxPath,
          newUid: newUid,
        );
      }
      return true;
    }

    // The UIDVALIDITY the new UID was learnt under: COPYUID names it, a
    // search's SELECT reports it.
    int? newUidValidity = copyUid == null ? null : _copyUidValidity(moveResult);
    final newUid = copyUid ??
        await _searchUidByMessageId(
          client,
          destMailboxPath,
          row.messageId,
          onSelected: (validity) => newUidValidity = validity,
        );
    if (newUid == null) {
      log(
        '_remapEmailAfterImapMove: could not resolve new UID for $oldId '
        'after move to $destMailboxPath (no COPYUID, '
        'messageId=${row.messageId}); row will be re-fetched on next sync',
      );
      return false;
    }

    await _relocateEmailAfterImapMove(
      id: oldId,
      destMailboxPath: destMailboxPath,
      newUid: newUid,
      seq: seq,
      uidValidity: newUidValidity,
    );
    return true;
  }

  /// Records [newUid] in [destMailboxPath] as the server location of row
  /// [id] after an IMAP MOVE and rebuilds the thread aggregates in both
  /// mailboxes. When the row is gone, only its queued changes follow.
  Future<void> _relocateEmailAfterImapMove({
    required String id,
    required String destMailboxPath,
    required int newUid,
    bool mergeDuplicate = true,
    int? seq,
    int? uidValidity,
  }) async {
    final row = await (_db.select(_db.emails)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) {
      await _repointQueuedChanges(
        oldId: id,
        destMailboxPath: destMailboxPath,
        newUid: newUid,
      );
      return;
    }
    await _relocateEmailRow(
      id: id,
      newUid: newUid,
      newMailboxPath: destMailboxPath,
      mergeDuplicate: mergeDuplicate,
      seq: seq,
      uidValidity: uidValidity,
    );

    // Rebuild thread aggregates in both mailboxes from the now-updated emails.
    final threadId = row.threadId ?? id;
    await _updateThread(row.accountId, row.mailboxPath, threadId);
    await _updateThread(row.accountId, destMailboxPath, threadId);
  }

  /// Points the changes still queued for [oldId], whose local row is gone
  /// (deleted for good while its move was queued), at the mail's [newUid] in
  /// [destMailboxPath], as [_RowIdentity._relocateEmailRow] does for a row that still
  /// exists. Otherwise a queued delete for good would expunge whatever
  /// mail has the pre-move UID there (#1266).
  Future<void> _repointQueuedChanges({
    required String oldId,
    required String destMailboxPath,
    required int newUid,
  }) =>
      _rewritePendingChangeUids(
        resourceId: oldId,
        mailboxPath: destMailboxPath,
        newUid: newUid,
      );

  /// The UID in [destMailboxPath] of the mail whose local row [oldId] is
  /// gone, found by the Message-ID stamped on its queued changes, when
  /// exactly one message matches; null otherwise, or when nothing besides
  /// the move itself is queued for it. A wrong guess here would point a
  /// queued delete for good at another copy, so an ambiguous match leaves
  /// the changes marked ([_uidAfterUnansweredMove] then fails them).
  Future<int?> _uniqueUidOfQueued(
    imap.ImapClient client,
    String oldId,
    String destMailboxPath,
  ) async {
    final queued = await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.resourceId.equals(oldId) & t.state.equals(_ackedState).not(),
          ))
        .get();
    if (queued.length < 2) return null;
    String? messageId;
    for (final change in queued) {
      if (_decodePayload(change)?['messageId'] case final String id) {
        messageId = id;
        break;
      }
    }
    final uids = await _searchUidsByMessageId(
      client,
      destMailboxPath,
      messageId,
    );
    return uids.length == 1 ? uids.single : null;
  }

  /// True when a `UID MOVE` probably moved nothing: the server supports
  /// UIDPLUS, which should answer a MOVE with `COPYUID` (RFC 6851 §4.3), and
  /// this one did not — most likely the UID no longer exists in the source.
  /// Only a hint: the callers still look in the destination before giving
  /// up or moving another copy. Without UIDPLUS the missing code says
  /// nothing.
  bool _imapMoveMovedNothing(
    imap.ImapClient client,
    imap.GenericImapResult result,
  ) {
    if (!client.serverInfo.supportsUidPlus) return false;
    try {
      return result.responseCodeCopyUid == null;
    } catch (_) {
      // A malformed COPYUID still means something was moved.
      return false;
    }
  }

  /// Extracts the destination UID for [sourceUid] from a MOVE/COPY result's
  /// `COPYUID` response code (RFC 4315). Returns null when the server did not
  /// advertise UIDPLUS or the response code is malformed.
  /// The destination's UIDVALIDITY a MOVE/COPY result's `COPYUID` names;
  /// null without one.
  int? _copyUidValidity(imap.GenericImapResult result) {
    try {
      final validity = result.responseCodeCopyUid?.uidValidity;
      return validity == null || validity == 0 ? null : validity;
    } catch (_) {
      return null;
    }
  }

  int? _resolveCopyUid(imap.GenericImapResult result, int sourceUid) {
    final code = result.responseCodeCopyUid;
    if (code == null) return null;
    try {
      final sources = code.originalSequence?.toList();
      final targets = code.targetSequence.toList();
      if (sources == null) {
        // Some servers omit the source set when only one message moved.
        return targets.length == 1 ? targets.first : null;
      }
      final idx = sources.indexOf(sourceUid);
      if (idx < 0 || idx >= targets.length) return null;
      return targets[idx];
    } catch (_) {
      return null;
    }
  }

  /// Looks up the UID of a message in [mailboxPath] by its RFC 2822
  /// `Message-ID` header. Used as a fallback when the server doesn't
  /// support UIDPLUS so we can still relink the local row after a move.
  /// Returns null when nothing matches. Rethrows when the connection is lost
  /// ([isImapConnectionLost]). Any other failure returns null too, unless
  /// [throwOnFailure] is set: then it throws a [StateError] so a caller that
  /// treats "no match" as "the message is gone" can tell the two apart.
  Future<int?> _searchUidByMessageId(
    imap.ImapClient client,
    String mailboxPath,
    String? messageId, {
    bool throwOnFailure = false,
    bool select = true,
    void Function(int? uidValidity)? onSelected,
  }) async {
    final uids = await _searchUidsByMessageId(
      client,
      mailboxPath,
      messageId,
      throwOnFailure: throwOnFailure,
      select: select,
      onSelected: onSelected,
    );
    if (uids.isEmpty) return null;
    return uids.reduce((a, b) => a > b ? a : b);
  }

  /// Every UID in [mailboxPath] whose Message-ID header is [messageId]; empty
  /// when none matches, or when the search fails and [throwOnFailure] is
  /// false. [onSelected] gets the UIDVALIDITY the [select] reported, under
  /// which the UIDs found are valid.
  Future<List<int>> _searchUidsByMessageId(
    imap.ImapClient client,
    String mailboxPath,
    String? messageId, {
    bool throwOnFailure = false,
    bool select = true,
    void Function(int? uidValidity)? onSelected,
  }) async {
    if (messageId == null || messageId.isEmpty) return const [];
    try {
      if (select) {
        final selected = await client.selectUnicodeMailboxByPath(mailboxPath);
        onSelected?.call(selected.uidValidity);
      }
      for (final criteria in messageIdSearchCriteria(messageId)) {
        final result = await client.uidSearchMessages(searchCriteria: criteria);
        final uids = result.matchingSequence?.toList() ?? const <int>[];
        if (uids.isEmpty) continue;
        return uids;
      }
      return const [];
    } catch (e) {
      // A dead connection is not "no match": let it reach the caller so a
      // batch (e.g. the pending-change flush) stops instead of carrying on.
      if (isImapConnectionLost(e)) rethrow;
      log('_searchUidsByMessageId failed for $messageId in $mailboxPath: $e');
      if (!throwOnFailure) return const [];
      // Wording must not match [isImapMailboxNotFound], which would treat
      // the change as applied.
      throw StateError('Message-ID search in $mailboxPath failed: $e');
    }
  }
}
