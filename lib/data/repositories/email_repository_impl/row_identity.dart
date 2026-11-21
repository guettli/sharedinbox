part of '../email_repository_impl.dart';

// Row identity: finding rows by server location, relocating a row to a new
// server location, carrying a vanished row over to its moved copy and merging
// duplicate rows.

/// Where to ask the IMAP server for a row's message: its recorded server
/// folder, which behind a queued move differs from the folder it is shown
/// in (a row without one falls back to the shown folder). There is no such
/// fallback for the UID: a row without `srv_uid` is found by Message-ID
/// ([_Bodies._imapUidToFetch]), since its `uid` may name another mail now.
extension on Email {
  String get imapServerPath => srvMailboxPath ?? mailboxPath;
}

/// The condition of [_RowIdentity._rowAtImapLocation].
Expression<bool> _atImapLocation(
  $EmailsTable t,
  String accountId,
  String mailboxPath,
  int uid, {
  int? uidValidity,
  String? exceptId,
}) {
  final validity = uidValidity == 0 ? null : uidValidity;
  final at = t.accountId.equals(accountId) &
      t.srvMailboxPath.equals(mailboxPath) &
      t.srvUid.equals(uid) &
      (validity == null
          ? t.srvUidValidity.isNull()
          : (t.srvUidValidity.equals(validity) | t.srvUidValidity.isNull()));
  return exceptId == null ? at : at & t.id.equals(exceptId).not();
}

extension _RowIdentity on EmailRepositoryImpl {
  /// Records that the server has the mail of row [id] at [newUid] in
  /// [newMailboxPath] now: its `uid` and server location
  /// (`srv_mailbox_path` / `srv_uid` / `srv_uid_validity`,
  /// [EmailStateWriter.relocate]), and the UIDs in its queued IMAP changes.
  /// The folder it shows follows, unless a later move, snooze or unsnooze of
  /// the mail is still queued (#1276): the fold of the location overlay
  /// keeps showing that one's destination. The row keeps its id
  /// (SYNC-REDESIGN.md §6), so its body, downloaded attachments, queued
  /// changes, logs, threads and Undo history stay attached as they are.
  /// Shared by [_FlushImap._relocateEmailAfterImapMove] and the body-fetch identity
  /// guard.
  ///
  /// [uidValidity] is the UIDVALIDITY under which [newUid] was learnt (the
  /// `COPYUID` answer's, or the SELECT's of the session that searched):
  /// the checkpoint's may be from before a change of it the folder's sync
  /// has not seen yet, and stamping that one would hide the row from the
  /// sync's location lookup, which then stores the mail twice. Null: not
  /// known, the checkpoint's.
  Future<void> _relocateEmailRow({
    required String id,
    required int newUid,
    required String newMailboxPath,
    bool mergeDuplicate = false,
    int? seq,
    int? uidValidity,
  }) async {
    var displaced = const <Email>[];
    Email? merged;
    await _db.transaction(() async {
      final row = await (_db.select(_db.emails)..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      if (row == null) return;
      final newUidValidity = uidValidity == null || uidValidity == 0
          ? await _knownUidValidity(row.accountId, newMailboxPath)
          : uidValidity;
      // Compared with what is recorded, so a row whose location was
      // released (or never recorded) gets it recorded.
      if (row.srvUid == newUid &&
          row.srvMailboxPath == newMailboxPath &&
          (newUidValidity == null || row.srvUidValidity == newUidValidity)) {
        return;
      }
      // Sync already fetched the mail at its new place (its MOVE's answer
      // came after the destination's sync, or another client moved it there
      // first): that row is a second row of the same mail. Drop it and keep
      // this one, which carries the user's changes and local state. Not with
      // [mergeDuplicate] false: the UID was found by Message-ID while a copy
      // with that Message-ID is still in the source, so it may be another
      // copy (cross-posted mail).
      final existing = await _rowAtImapLocation(
        row.accountId,
        newMailboxPath,
        newUid,
        uidValidity: newUidValidity,
        exceptId: id,
      );
      if (existing != null &&
          mergeDuplicate &&
          existing.messageId != null &&
          existing.messageId == row.messageId) {
        log(
          'Relocate $id to UID $newUid in $newMailboxPath: dropping the copy '
          'sync already fetched (${existing.id})',
        );
        // Its queued changes, logs, thread and Undo references (and its
        // body, if this row has none) carry over to this row.
        await _mergeDuplicateRow(dropId: existing.id, keepId: id);
        merged = existing;
        // The kept row has this app's view of the flags, the dropped one the
        // server's: read them again.
        await _makeFlagReconcileDue(row.accountId, newMailboxPath, jmap: false);
        await _updateThread(
          existing.accountId,
          existing.mailboxPath,
          existing.threadId ?? existing.id,
        );
      }
      // Another row still records the location the server just gave this
      // mail: that record is stale (one location holds one message).
      displaced = await _releaseImapLocation(
        row.accountId,
        newMailboxPath,
        newUid,
        newUidValidity,
        exceptId: id,
      );

      await _state.relocate(
        id,
        mailboxPath: newMailboxPath,
        uid: newUid,
        uidValidity: newUidValidity,
        seq: seq,
      );
      await _rewritePendingChangeUids(
        resourceId: id,
        mailboxPath: newMailboxPath,
        newUid: newUid,
        oldUid: row.uid,
        uidValidity: newUidValidity,
      );
      // latest_uid follows the latest email's UID, the thread list's
      // same-second tiebreaker.
      await _db.customStatement(
        'UPDATE threads SET latest_uid = ?1 WHERE latest_email_id = ?2',
        [newUid, id],
      );
    });
    _logLocationReleased(displaced, takenBy: id);
    final dropped = merged;
    if (dropped == null) return;
    unawaited(
      _appLogger?.warn(
        'email.duplicate_merged',
        'Dropped a second copy of "${dropped.subject ?? '(no subject)'}" '
            'that sync had stored at UID $newUid in $newMailboxPath: the '
            'moved message is there now and keeps its own row.',
        accountId: dropped.accountId,
        mailboxPath: newMailboxPath,
        emailId: id,
        data: {'droppedEmailId': dropped.id},
      ),
    );
  }

  /// Points the IMAP payloads of [resourceId]'s queued changes that address
  /// the message in [mailboxPath] at its new [newUid]. Changes queued after an
  /// optimistic move (e.g. Undo's reverse move Trash→INBOX) still carry the
  /// pre-move UID, which does not exist in the destination mailbox: the server
  /// would accept the `UID MOVE` as a no-op and the change would be lost
  /// (#1048). With [fromMailboxPath], the changes that still address the
  /// mail at [oldUid] there (another client moved it) follow it too. They
  /// are stamped with [uidValidity], when given, else with the folder's
  /// current one. Returns how many of them address the mail at [newUid] in
  /// [mailboxPath] now.
  Future<int> _rewritePendingChangeUids({
    required String resourceId,
    required String mailboxPath,
    required int newUid,
    int? oldUid,
    String? fromMailboxPath,
    int? uidValidity,
  }) async {
    final rows = await (_db.select(_db.pendingChanges)
          ..where((t) => t.resourceId.equals(resourceId)))
        .get();
    var rewritten = 0;
    for (final row in rows) {
      final Map<String, dynamic> payload;
      try {
        payload = jsonDecode(row.payload) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      if (payload['uid'] is! int) continue;
      final addressed = payload['mailboxPath'] ?? payload['src'];
      // Addresses the mail where it was before another client moved it.
      final leftBehind = fromMailboxPath != null &&
          fromMailboxPath != mailboxPath &&
          addressed == fromMailboxPath &&
          payload['uid'] == oldUid &&
          payload[_uidAfterMoveKey] == null;
      if (leftBehind) {
        payload[payload.containsKey('mailboxPath') ? 'mailboxPath' : 'src'] =
            mailboxPath;
      } else if (payload['uid'] == newUid &&
          payload[_uidAfterMoveKey] == null &&
          (uidValidity == null || payload['uidValidity'] == uidValidity)) {
        // Already there (a UIDVALIDITY change may give the mail its old
        // UID under the new one: then only the stamp is rewritten).
        continue;
      } else if (addressed != mailboxPath) {
        // Queued behind a later move that is not answered yet: it stays
        // marked, but carries the mail's current UID, as one queued now
        // would. Undoing or failing that move points it back here by
        // this UID (`_unmarkAfterCancelledMove`,
        // `_pointLaterChangesAtSource`); before, it kept a UID from two
        // folders back and named whichever mail has it here (#1276).
        if (payload[_uidAfterMoveKey] == true &&
            oldUid != null &&
            payload['uid'] == oldUid) {
          payload['uid'] = newUid;
          await (_db.update(_db.pendingChanges)
                ..where((t) => t.id.equals(row.id)))
              .write(
            PendingChangesCompanion(payload: Value(jsonEncode(payload))),
          );
        }
        continue;
      }
      payload['uid'] = newUid;
      payload.remove(_uidAfterMoveKey);
      // It names the mail where it is now.
      payload.remove(_srcVanishedKey);
      if (row.state != _ackedState) rewritten++;
      // The new UID was learned under [uidValidity], else under the
      // folder's current UIDVALIDITY.
      payload.remove('uidValidity');
      final checkpoint = uidValidity == null
          ? await _loadImapCheckpoint(row.accountId, 'IMAP:$mailboxPath')
          : null;
      if (uidValidity ?? checkpoint?['uidValidity'] case final int validity
          when validity != 0) {
        payload['uidValidity'] = validity;
      }
      await (_db.update(_db.pendingChanges)..where((t) => t.id.equals(row.id)))
          .write(PendingChangesCompanion(payload: Value(jsonEncode(payload))));
    }
    return rewritten;
  }

  /// The row of the message the server has under [uid] in [mailboxPath],
  /// found by the server-location columns (SYNC-REDESIGN.md §8 phase 2):
  /// never by building an id, and never by the shown `mailboxPath`, which
  /// behind a queued move already names the destination. With a known
  /// [uidValidity] a row stamped with another one is a different message
  /// and not returned; one without a stamp is (an exact stamp wins). With
  /// an unknown one, only an unstamped row matches. [exceptId] is skipped.
  Future<Email?> _rowAtImapLocation(
    String accountId,
    String mailboxPath,
    int uid, {
    int? uidValidity,
    String? exceptId,
  }) =>
      (_db.select(_db.emails)
            ..where(
              (t) => _atImapLocation(
                t,
                accountId,
                mailboxPath,
                uid,
                uidValidity: uidValidity,
                exceptId: exceptId,
              ),
            )
            ..orderBy([(t) => OrderingTerm.desc(t.srvUidValidity.isNotNull())])
            ..limit(1))
          .getSingleOrNull();

  /// The row of the JMAP Email [jmapId], found by its server id.
  Future<Email?> _rowByJmapId(String accountId, String jmapId) =>
      (_db.select(_db.emails)
            ..where(
              (t) => t.accountId.equals(accountId) & t.srvJmapId.equals(jmapId),
            )
            ..limit(1))
          .getSingleOrNull();

  /// Clears the recorded UID of the rows other than [exceptId] that hold
  /// this IMAP location ([EmailStateWriter.releaseLocation]), because the
  /// server just gave it to [exceptId]'s mail: one location holds one
  /// message. Returns those rows (log them with [_logLocationReleased] after
  /// the transaction).
  Future<List<Email>> _releaseImapLocation(
    String accountId,
    String mailboxPath,
    int uid,
    int? uidValidity, {
    required String exceptId,
  }) async {
    final rows = await (_db.select(_db.emails)
          ..where(
            (t) => _atImapLocation(
              t,
              accountId,
              mailboxPath,
              uid,
              uidValidity: uidValidity,
              exceptId: exceptId,
            ),
          ))
        .get();
    await _state.releaseLocation([for (final row in rows) row.id]);
    return rows;
  }

  /// App Log line for each row whose server location [_releaseImapLocation]
  /// cleared: sync no longer finds it, so a stale copy may linger.
  void _logLocationReleased(List<Email> rows, {required String takenBy}) {
    for (final released in rows) {
      _logLocationReleasedOne(released, takenBy: takenBy);
    }
  }

  void _logLocationReleasedOne(Email released, {required String takenBy}) {
    unawaited(
      _appLogger?.warn(
        'email.server_location_released',
        'Forgot where the server has "${released.subject ?? '(no subject)'}" '
            '(UID ${released.srvUid} in ${released.srvMailboxPath}): the '
            'server gave that UID to another message. Sync no longer '
            'updates this copy.',
        accountId: released.accountId,
        mailboxPath: released.mailboxPath,
        emailId: released.id,
        data: {'takenBy': takenBy},
      ),
    );
  }

  /// When [row] has just vanished from [vanishedFrom] (whose UIDs are now
  /// [serverUids]), returns the row of the same mail at its new location:
  /// the only other server row of the account with [row]'s move-stable
  /// server id (RFC 8474 EMAILID / X-GM-MSGID). Null when [row] has no
  /// server id, or no such row or more than one exists (SYNC-REDESIGN.md
  /// §6: a row carries over only on a unique match). A row in the same
  /// folder counts when it records another, still existing UID there (our
  /// own move whose relocation failed: the row shows the destination with
  /// its old UID, and sync stored the mail there a second time).
  Future<Email?> _movedCopyOf(
    Email row,
    String vanishedFrom,
    Set<int> serverUids,
  ) async {
    final serverEmailId = row.serverEmailId;
    if (serverEmailId == null || serverEmailId.isEmpty) return null;
    final copies = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(row.accountId) &
                t.serverEmailId.equals(serverEmailId) &
                t.isLocal.equals(false) &
                // Not one the server no longer has either.
                t.srvGone.equals(false) &
                t.id.equals(row.id).not(),
          )
          ..limit(2))
        .get();
    if (copies.length != 1) return null;
    final copy = copies.single;
    final copyPath = copy.srvMailboxPath;
    final copyUid = copy.srvUid;
    if (copyPath == null || copyUid == null) return null;
    if (copyPath == vanishedFrom) {
      if (!serverUids.contains(copyUid)) return null;
      if (copyPath == row.srvMailboxPath && copyUid == row.srvUid) return null;
    }
    return copy;
  }

  /// Another client moved the mail of [row] (it vanished from its folder)
  /// to where sync already stored it as [copy]. [row] carries over: it keeps
  /// its id and takes the copy's place, i.e. everything the copy recorded
  /// (shown folder, UID, server location, headers, and the flags it has no
  /// queued change for), and the copy is merged into it
  /// ([_mergeDuplicateRow]). The vanished row survives, not
  /// the copy, because it is the one the user knows: an open detail view,
  /// Undo history, notifications and drafts reference its id, while the
  /// copy was stored by a recent sync; whatever references the copy did
  /// collect are re-pointed. Its queued IMAP changes that address the old
  /// location follow the mail to the new one.
  ///
  /// Re-checked in the transaction: when the user moved [row] meanwhile, or
  /// a flush is sending a change of [copy] right now (merging would lose
  /// what its answer records), nothing happens and the row is kept for the
  /// next sync (`kept`). When [copy]'s location is from before a
  /// UIDVALIDITY change of its folder, its UID may name another mail: no
  /// carry-over, the row is deleted as gone. Returns the dropped copy for
  /// the App Log when the row carried over, and how many of the row's
  /// queued (or failed) changes now address the mail at its new place
  /// (`retargeted`).
  ///
  /// A queued move, snooze or unsnooze of [row] keeps it here, unless the
  /// flush found it addressing a UID already gone ([_srcVanishedKey],
  /// #1327): that one was never applied, so it follows the mail and is sent
  /// from the new place.
  ///
  /// [adopting]: [row] waits, gone, for a foreign move's destination and
  /// [copy] just arrived there ([_adoptForeignMove]): nothing happens unless
  /// both still are what they were (in another isolate a sync may have
  /// adopted or revived [row], or the copy was matched meanwhile).
  Future<({bool kept, Email? dropped, int retargeted})> _carryOverMovedRow({
    required Email row,
    required Email copy,
    required String vanishedFrom,
    bool adopting = false,
  }) async {
    const gone = (kept: false, dropped: null, retargeted: 0);
    const later = (kept: true, dropped: null, retargeted: 0);
    return _db.transaction(() async {
      final current = await (_db.select(_db.emails)
            ..where((t) => t.id.equals(row.id)))
          .getSingleOrNull();
      final dup = await (_db.select(_db.emails)
            ..where((t) => t.id.equals(copy.id)))
          .getSingleOrNull();
      if (current == null) return later;
      if (dup == null) return gone;
      if (adopting &&
          (!current.srvGone ||
              current.foreignMoveWaitSeq == null ||
              dup.srvGone ||
              dup.isLocal ||
              normaliseMessageId(dup.messageId) !=
                  normaliseMessageId(current.messageId) ||
              !await _stillUniqueAdoption(current, dup))) {
        return later;
      }
      final newPath = dup.srvMailboxPath;
      final newUid = dup.srvUid;
      if (newPath == null || newUid == null) return gone;
      final rowChanges = await _liveChanges(current.id);
      final copyChanges = await _liveChanges(dup.id);
      if (current.srvMailboxPath != vanishedFrom ||
          rowChanges.any(
            (c) =>
                _locationChangeTypes.contains(c.changeType) &&
                !_addressesVanishedUid(c),
          ) ||
          copyChanges.any((c) => c.state == _inflightState)) {
        return later;
      }
      final newUidValidity = dup.srvUidValidity;
      // An adopted copy was just stored under the UIDVALIDITY its SELECT
      // reported; the checkpoint may still hold the one before a change.
      final known =
          adopting ? null : await _knownUidValidity(dup.accountId, newPath);
      if (known != null && newUidValidity != null && known != newUidValidity) {
        return gone;
      }
      await _mergeDuplicateRow(dropId: dup.id, keepId: current.id);
      // Read and star changes acked in the folder the mail left: the flush
      // acks a STORE only when it hit the mail (#1326), so the mail took
      // the flags along and the copy's read has them; folded on, they
      // would wait for a read of a folder that no longer has the mail
      // (takeOverRow re-folds).
      await _state.dropAckedFlagsAt(current.id, vanishedFrom);
      // The copy's server facts, the read/star/snooze state with the read
      // stamp it was read under included. The changes of both rows (the
      // copy's now point here) fold over it: a flag the user changed on
      // [row] before the move keeps showing until a read confirms it.
      await _state.takeOverRow(current.id, dup);
      final retargeted = await _rewritePendingChangeUids(
        resourceId: current.id,
        mailboxPath: newPath,
        newUid: newUid,
        oldUid: current.srvUid ?? current.uid,
        fromMailboxPath: current.srvMailboxPath ?? current.mailboxPath,
        // The UID was learned under the copy's UIDVALIDITY.
        uidValidity: newUidValidity,
      );
      // The copy's thread in the new folder lists this row now.
      for (final threadId in {dup.threadId ?? dup.id, dup.threadId ?? row.id}) {
        await _updateThread(dup.accountId, dup.mailboxPath, threadId);
      }
      return (kept: true, dropped: dup, retargeted: retargeted);
    });
  }

  /// Sync just stored row [arrivedId], a new mail with Message-ID [mid] in
  /// [arrivalFolder] of IMAP account [accountId]. When exactly one row of
  /// the account waits, gone from its folder, for a foreign move's
  /// destination ([KeywordRead.markGone] with `awaitForeignMove`) and it
  /// has that Message-ID, it is the moved mail (#1313: another client moved
  /// it, and this device synced the source first): it carries over in
  /// place ([_carryOverMovedRow]) and keeps its id, body, attachments and
  /// references; the arrived row is merged into it. Never a live row: a
  /// second copy the server still has elsewhere (a self-sent mail's Sent
  /// and Inbox copies, a Gmail label) is not gone. Not when the pair cannot
  /// be the same mail ([_foreignMoveMismatch]). Logged (App Log warn
  /// `email.foreign_move_adopted`). Returns whether it was adopted.
  Future<bool> _adoptForeignMove(
    String accountId,
    String arrivalFolder,
    String arrivedId,
    String mid,
  ) async {
    final waiting = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.srvGone.equals(true) &
                t.foreignMoveWaitSeq.isNotNull() &
                t.isLocal.equals(false) &
                t.id.equals(arrivedId).not() &
                (t.messageId.equals(mid) | t.messageId.equals('<$mid>')),
          )
          ..limit(2))
        .get();
    if (waiting.isEmpty) return false;
    if (waiting.length > 1) {
      for (final row in waiting) {
        _logForeignMoveNotAdopted(
          row,
          arrivalFolder,
          'more than one row waits with this Message-ID',
        );
      }
      return false;
    }
    final row = waiting.single;
    final from = row.srvMailboxPath;
    final arrived = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(arrivedId)))
        .getSingleOrNull();
    if (from == null || arrived == null) return false;
    final mismatch = await _foreignMoveMismatch(row, arrived, arrivalFolder);
    if (mismatch != null) {
      _logForeignMoveNotAdopted(row, arrivalFolder, mismatch);
      return false;
    }
    final carried = await _carryOverMovedRow(
      row: row,
      copy: arrived,
      vanishedFrom: from,
      adopting: true,
    );
    final dropped = carried.dropped;
    if (dropped == null) {
      // Not retried: the arrival is stored now, and the wait ends as usual.
      _logForeignMoveNotAdopted(
        row,
        arrivalFolder,
        carried.kept
            ? 'the row changed meanwhile, has a move or delete of its own '
                'queued, or a change of the new row is being sent'
            : 'the new row is gone already',
      );
      return false;
    }
    _logForeignMoveAdopted(
      row,
      dropped,
      from: from,
      to: arrivalFolder,
      retargeted: carried.retargeted,
    );
    return true;
  }

  /// Inside [_carryOverMovedRow]'s transaction: [current] is still the only
  /// row of its account waiting with its Message-ID, and [dup]'s folder has
  /// no other live row with it.
  Future<bool> _stillUniqueAdoption(Email current, Email dup) async {
    final mid = normaliseMessageId(current.messageId);
    if (mid == null) return false;
    Expression<bool> sameMid($EmailsTable t) =>
        t.accountId.equals(current.accountId) &
        t.isLocal.equals(false) &
        (t.messageId.equals(mid) | t.messageId.equals('<$mid>'));
    final waiting = await (_db.select(_db.emails)
          ..where(
            (t) =>
                sameMid(t) &
                t.srvGone.equals(true) &
                t.foreignMoveWaitSeq.isNotNull(),
          )
          ..limit(2))
        .get();
    if (waiting.length != 1) return false;
    final others = await (_db.select(_db.emails)
          ..where(
            (t) =>
                sameMid(t) &
                t.srvGone.equals(false) &
                t.srvMailboxPath.equalsNullable(dup.srvMailboxPath) &
                t.id.equals(dup.id).not(),
          )
          ..limit(1))
        .get();
    return others.isEmpty;
  }

  /// App Log line for [row], gone from its folder, carried over in place to
  /// [dropped], the row sync stored for its mail in [to] (another client
  /// moved it from [from]); [destinationFirst]: [to] was synced first.
  /// [retargeted] of its queued changes now address it in [to].
  void _logForeignMoveAdopted(
    Email row,
    Email dropped, {
    required String from,
    required String to,
    bool destinationFirst = false,
    int retargeted = 0,
  }) {
    unawaited(
      _appLogger?.warn(
        'email.foreign_move_adopted',
        '"${row.subject ?? '(no subject)'}" left $from and arrived in $to '
            '(moved by another client): its row follows it there with its '
            'cached body and attachments, and the row sync had stored '
            'there was merged into it.${_retargetedNote(retargeted, to)}',
        accountId: row.accountId,
        mailboxPath: to,
        emailId: row.id,
        data: {
          'droppedEmailId': dropped.id,
          'from': from,
          'to': to,
          'order': destinationFirst ? 'destination_first' : 'source_first',
          if (retargeted > 0) 'retargetedChanges': retargeted,
        },
      ),
    );
  }

  /// App Log info line: [row], gone from its folder, was not carried over
  /// to the mail with its Message-ID in [to], because of [reason].
  void _logForeignMoveNotAdopted(Email row, String to, String reason) {
    unawaited(
      _appLogger?.info(
        'email.foreign_move_not_adopted',
        '"${row.subject ?? '(no subject)'}", gone from '
            '${row.srvMailboxPath}, was not matched with the mail with its '
            'Message-ID in $to: $reason',
        accountId: row.accountId,
        mailboxPath: to,
        emailId: row.id,
        data: {'from': row.srvMailboxPath, 'to': to, 'reason': reason},
      ),
    );
  }

  /// Why [arrived], just stored in [arrivalFolder], cannot be the mail of
  /// [waiting], a row gone from its folder with the same Message-ID; null
  /// when it can. Not into All Mail (Gmail: every mail is there; a later
  /// sync of it is not where a mail went) or Drafts (an edited draft comes
  /// back with the same Message-ID and another text); not across the Sent
  /// boundary (a self-sent mail's Sent copy is another copy, like the role
  /// pairing of virtual rows, SYNC-REDESIGN.md §6); not when the arrival
  /// folder holds another live row of the Message-ID (which one moved is
  /// unknown); not when both carry a move-stable server id (EMAILID,
  /// X-GM-MSGID) or a size and they differ: a move keeps both.
  Future<String?> _foreignMoveMismatch(
    Email waiting,
    Email arrived,
    String arrivalFolder,
  ) async {
    final accountId = waiting.accountId;
    final arrivalRole = await _mailboxRole(accountId, arrivalFolder);
    if (arrivalRole == 'all' || arrivalRole == 'drafts') {
      return 'arrived in a folder of role $arrivalRole';
    }
    final sourceRole = waiting.srvMailboxPath == null
        ? null
        : await _mailboxRole(accountId, waiting.srvMailboxPath!);
    if ((arrivalRole == 'sent') != (sourceRole == 'sent')) {
      return 'across the Sent folder';
    }
    final mid = normaliseMessageId(waiting.messageId);
    final others = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.srvMailboxPath.equals(arrivalFolder) &
                t.srvGone.equals(false) &
                t.isLocal.equals(false) &
                t.id.equals(arrived.id).not() &
                (t.messageId.equals(mid ?? '') | t.messageId.equals('<$mid>')),
          )
          ..limit(1))
        .get();
    if (others.isNotEmpty) return 'another copy is in $arrivalFolder';
    final a = waiting.serverEmailId;
    final b = arrived.serverEmailId;
    if (a != null && a.isNotEmpty && b != null && b.isNotEmpty && a != b) {
      return 'another server email id';
    }
    final sizeA = waiting.sizeBytes;
    final sizeB = arrived.sizeBytes;
    if (sizeA != null && sizeB != null && sizeA != sizeB) {
      return 'another size';
    }
    // A Message-ID alone is not enough (a legacy row without size or
    // server id): the size, the server id, or the Date and Subject agree.
    final sameId = a != null && a.isNotEmpty && a == b;
    final sameSize = sizeA != null && sizeA == sizeB;
    final sameHeaders = waiting.sentAt != null &&
        waiting.sentAt == arrived.sentAt &&
        waiting.subject == arrived.subject;
    if (!sameId && !sameSize && !sameHeaders) {
      return 'only the Message-ID agrees (no size, server id, or Date and '
          'Subject to confirm it)';
    }
    return null;
  }

  /// The changes queued (pending, inflight or stuck) for row [id].
  Future<List<PendingChangeRow>> _liveChanges(String id) =>
      (_db.select(_db.pendingChanges)
            ..where(
              (t) => t.resourceId.equals(id) & t.state.isIn(_liveStates),
            ))
          .get();

  /// App Log line for a copy [_carryOverMovedRow] merged into [kept], the
  /// row of the mail that vanished from [from] (where the server had it,
  /// not where [kept] is shown: behind a queued move that is its
  /// destination, #1327); [retargeted] of its queued changes now address it
  /// at the copy's place.
  void _logMovedRowCarriedOver(
    Email kept,
    Email dropped, {
    required String from,
    int retargeted = 0,
  }) {
    final to = dropped.srvMailboxPath ?? dropped.mailboxPath;
    unawaited(
      _appLogger?.warn(
        'email.duplicate_merged',
        '"${dropped.subject ?? '(no subject)'}" was moved from $from to '
            '$to by another client: its row follows it there, and the '
            'second row sync had stored there was merged into it.'
            '${_retargetedNote(retargeted, to)}',
        accountId: kept.accountId,
        mailboxPath: to,
        emailId: kept.id,
        data: {
          'droppedEmailId': dropped.id,
          'from': from,
          'to': to,
          if (retargeted > 0) 'retargetedChanges': retargeted,
        },
      ),
    );
  }

  /// The App Log note that [count] queued changes of a carried-over row now
  /// address the mail in [folder] (empty for none).
  String _retargetedNote(int count, String folder) => count == 0
      ? ''
      : ' $count queued change(s) of it now address it in $folder and are '
          'sent there.';

  /// Merges [dropId], a second row of the mail of [keepId], into [keepId]
  /// and deletes it. Row ids are frozen (SYNC-REDESIGN.md §6): this is the
  /// only place that points references from one email row to another, and
  /// only for a duplicate about to be deleted. Its cached body moves over
  /// when [keepId] has none, and its queued changes, thread entries, Undo
  /// history, App Log lines, notification marks and draft replies point at
  /// [keepId]. The caller logs the merge once its transaction committed.
  Future<void> _mergeDuplicateRow({
    required String dropId,
    required String keepId,
  }) async {
    var attachmentsMove = false;
    await _db.transaction(() async {
      final keepHasBody = await (_db.select(_db.emailBodies)
                ..where((t) => t.emailId.equals(keepId))
                ..limit(1))
              .getSingleOrNull() !=
          null;
      if (!keepHasBody) {
        await _db.customStatement(
          'UPDATE email_bodies SET email_id = ?1 WHERE email_id = ?2',
          [keepId, dropId],
        );
        // Its downloaded attachments go with its body, unless the kept row
        // has downloaded some of its own.
        final keepHasFiles = await (_db.select(_db.attachmentFiles)
                  ..where((t) => t.emailId.equals(keepId))
                  ..limit(1))
                .getSingleOrNull() !=
            null;
        if (!keepHasFiles) {
          await _db.customStatement(
            'UPDATE attachment_files SET email_id = ?1 WHERE email_id = ?2',
            [keepId, dropId],
          );
          attachmentsMove = true;
        }
      }

      await (_db.update(_db.pendingChanges)
            ..where((t) => t.resourceId.equals(dropId)))
          .write(PendingChangesCompanion(resourceId: Value(keepId)));

      // threads.latest_email_id / threads.email_ids_json and undo_actions
      // embed email ids as unique opaque strings — safe to rewrite by REPLACE.
      await _db.customStatement(
        'UPDATE threads SET latest_email_id = ?1 WHERE latest_email_id = ?2',
        [keepId, dropId],
      );
      await _db.customStatement(
        'UPDATE threads SET email_ids_json = REPLACE(email_ids_json, ?1, ?2) '
        'WHERE email_ids_json LIKE ?3',
        ['"$dropId"', '"$keepId"', '%"$dropId"%'],
      );
      await _db.customStatement(
        'UPDATE undo_actions SET data_json = REPLACE(data_json, ?1, ?2) '
        'WHERE data_json LIKE ?3',
        ['"$dropId"', '"$keepId"', '%"$dropId"%'],
      );
      // The per-message logs follow the message;
      // deleting the row would set their email_id to null.
      await _db.customStatement(
        'UPDATE app_logs SET email_id = ?1 WHERE email_id = ?2',
        [keepId, dropId],
      );
      // A notification shown for the copy counts for the kept row, so the
      // mail is not announced twice.
      await _db.customStatement(
        'INSERT OR IGNORE INTO notified_emails '
        '(account_id, email_id, notified_at) '
        'SELECT account_id, ?1, notified_at FROM notified_emails '
        'WHERE email_id = ?2',
        [keepId, dropId],
      );
      await _db.customStatement(
        'DELETE FROM notified_emails WHERE email_id = ?1',
        [dropId],
      );
      await _db.customStatement(
        'UPDATE drafts SET reply_to_email_id = ?1 '
        'WHERE reply_to_email_id = ?2',
        [keepId, dropId],
      );
      // Its own body (when the kept row has one) and attachment rows go
      // with it.
      await _state.deleteRow(dropId);
      // The copy's changes fold into the kept row now.
      await _state.refold(keepId);
    });
    await _moveOrDropAttachmentDir(
      dropId: dropId,
      keepId: keepId,
      move: attachmentsMove,
    );
  }

  /// The attachment cache folder of [dropId] (keyed by email id, see
  /// [downloadAttachment]) becomes [keepId]'s when [move], else is deleted,
  /// so a merged row leaves no files behind. Best effort: a file that
  /// cannot be moved is downloaded again when opened.
  Future<void> _moveOrDropAttachmentDir({
    required String dropId,
    required String keepId,
    required bool move,
  }) async {
    try {
      final dropDir = Directory(await _attachmentDirOf(dropId));
      if (!await dropDir.exists()) return;
      final keepDir = Directory(await _attachmentDirOf(keepId));
      if (move && !await keepDir.exists()) {
        await dropDir.rename(keepDir.path);
        return;
      }
      await dropDir.delete(recursive: true);
    } catch (e) {
      log('Attachment folder of merged row $dropId: $e');
    }
  }

  /// The folder [downloadAttachment] caches [emailId]'s attachments in.
  Future<String> _attachmentDirOf(String emailId) async => p.join(
        (await _getCacheDir()).path,
        'sharedinbox',
        'attachments',
        emailId.replaceAll(':', '_'),
      );
}
