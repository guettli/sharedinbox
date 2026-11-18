part of '../email_repository_impl.dart';

// Counterpart mirroring: copies of the same message in other accounts (by
// Message-ID) get shadow ops of the user's change; and the in-place match of
// a row without a server copy (a virtual row, a JMAP mail without a known
// id, an acked move waiting for its destination copy) when the server copy
// arrives (SYNC-REDESIGN.md §6, §4.5).

/// Change types whose latest queued op on the source row a counterpart
/// shadow follows, per mirrored action.
const _moveOpTypes = ['move'];
const _deleteOpTypes = ['move', 'delete'];

extension _Counterparts on EmailRepositoryImpl {
  /// Mirrors a snooze (or an un-snooze when [until] is null) onto the matching
  /// message in every counterpart account — the same server mailbox connected
  /// via the other protocol (see [AccountComparison]).
  ///
  /// A user who connects to one server via both IMAP and JMAP has two
  /// independent [Account] rows, each with its own copy of every message, so
  /// snoozing on one account leaves the other untouched. This bridges them:
  /// messages are correlated by their normalised RFC 2822 Message-ID and the
  /// counterpart's row gets a shadow of the change queued on [sourceRowId]
  /// (SYNC-REDESIGN.md §6): it shows there at once, is never sent (the
  /// server message is changed once, by the primary), and is acked, dropped
  /// or failed with the primary.
  ///
  /// Best-effort: counterparts that haven't synced the message yet are skipped
  /// (their next sync reconstructs the snooze from the shared server-side
  /// `snz:` keyword anyway), and rows already in the requested state are left
  /// alone so no redundant change is enqueued.
  Future<void> _mirrorSnoozeToCounterparts(
    String sourceAccountId,
    String? messageId, {
    required DateTime? until,
    required String sourceRowId,
  }) async {
    final targets = await _mirrorTargets(
      sourceAccountId,
      messageId,
      sourceRowId: sourceRowId,
      opTypes: until == null ? const ['unsnooze'] : const ['snooze'],
    );
    if (targets == null) return;
    final (:primary, :twins) = targets;

    for (final row in twins) {
      if (until != null) {
        // Already snoozed to (about) the same time → nothing to mirror.
        final current = row.snoozedUntil;
        if (current != null &&
            current.difference(until).abs() < const Duration(seconds: 1)) {
          continue;
        }
        await _asShadowOf(primary, () => _snoozeRow(row, until));
      } else {
        // Already awake → nothing to mirror.
        if (row.snoozedUntil == null) continue;
        await _asShadowOf(primary, () => _unsnoozeRow(row));
      }
    }
  }

  /// The twin rows of the mail with [messageId] in the counterpart accounts
  /// of [sourceAccountId], and the change of [opTypes] just queued on its
  /// row [sourceRowId] that their shadows follow; null when there is none
  /// (the action queued nothing, or the mail has no Message-ID).
  Future<({int primary, List<Email> twins})?> _mirrorTargets(
    String sourceAccountId,
    String? messageId, {
    required String sourceRowId,
    required List<String> opTypes,
  }) async {
    final mid = normaliseMessageId(messageId);
    if (mid == null) return null;
    final primary = await _latestQueuedOp(sourceRowId, opTypes);
    if (primary == null) return null;
    final source = await _accounts.getAccount(sourceAccountId);
    if (source == null) return null;
    final all = await _accounts.observeAccounts().first;
    final twins = <Email>[];
    for (final counterpart in AccountComparison.counterpartsOf(source, all)) {
      final row = await _findEmailRowByNormalisedMessageId(counterpart.id, mid);
      if (row != null) twins.add(row);
    }
    return (primary: primary, twins: twins);
  }

  /// The id of the latest change of [types] queued on row [rowId] and not
  /// sent yet or being sent (the primary a counterpart shadow follows);
  /// null when none is (the action queued nothing).
  Future<int?> _latestQueuedOp(String rowId, List<String> types) async {
    final row = await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.resourceId.equals(rowId) &
                t.changeType.isIn(types) &
                t.state.isIn(const [..._liveStates, _parkedState]),
          )
          ..orderBy([(t) => OrderingTerm.desc(t.id)])
          ..limit(1))
        .getSingleOrNull();
    return row?.id;
  }

  /// Looks up a single email row in [accountId] whose Message-ID matches [mid]
  /// (already run through [normaliseMessageId]). Matches both the bracket-less
  /// JMAP form and the legacy `<...>` IMAP form stored in the column.
  Future<Email?> _findEmailRowByNormalisedMessageId(
    String accountId,
    String mid,
  ) {
    return (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                (t.messageId.equals(mid) | t.messageId.equals('<$mid>')) &
                _visible(t),
          )
          ..limit(1))
        .getSingleOrNull();
  }

  /// [_matchArrival], for tests.
  Future<void> _matchArrivalForTest(
    String accountId,
    String arrivalMailboxPath,
    String realEmailId,
    String? messageId,
  ) =>
      _matchArrival(
        accountId,
        arrivalMailboxPath,
        realEmailId,
        messageId,
        isNew: true,
      );

  /// Sync just stored row [realEmailId], the server's copy of Message-ID
  /// [messageId] in [arrivalMailboxPath]. When a row of the account waits
  /// for exactly that mail, the server copy fills it in place
  /// (SYNC-REDESIGN.md §6): that row keeps its id, its references and the
  /// user's changes, takes the copy's server facts and headers, and the
  /// copy is merged into it. Rows that wait:
  /// - a local virtual row (#545 self-send note, #918 Sent copy), paired by
  ///   today's role rule: a Sent-folder arrival only with the virtual Sent
  ///   copy, any other with the note (also one a server-side filter filed
  ///   elsewhere). Its parked changes become pending ([_unparkOps]);
  /// - for an [isNew] row only: a row gone from its source whose acked move
  ///   into [arrivalMailboxPath] never learnt the new UID (§4.5, the appear
  ///   side of carry-over), and a JMAP row of [arrivalMailboxPath] whose
  ///   server id was never recorded.
  /// No-op without a unique match, so it is safe for every synced message
  /// and safe to replay.
  Future<void> _matchArrival(
    String accountId,
    String arrivalMailboxPath,
    String realEmailId,
    String? messageId, {
    required bool isNew,
  }) async {
    final mid = normaliseMessageId(messageId);
    if (mid == null) return;

    // A send can leave two virtual rows behind: the self-send note in the
    // inbox (#545) and, when the server gave us no APPENDUID, the Sent copy
    // (#918). Pair each with the arrival it actually is, keyed off
    // `isVirtualSentCopy` rather than its current folder: the user may well
    // have filed the note into Trash, and that move is exactly what the
    // match carries over. Matching the wrong one would move an inbox arrival
    // into Sent.
    final arrivalIsSent =
        await _mailboxRole(accountId, arrivalMailboxPath) == 'sent';
    final local = await _localRowFor(accountId, mid, sentCopy: arrivalIsSent);
    if (local != null && local.id != realEmailId) {
      await _matchInPlace(local, realEmailId, kind: 'virtual');
      return;
    }
    if (!isNew) return;
    final awaiting = await _state.awaitingRowFor(
      accountId,
      arrivalMailboxPath,
      mid,
      exceptId: realEmailId,
    );
    if (awaiting != null) {
      await _matchInPlace(awaiting, realEmailId, kind: 'moved');
      return;
    }
    final idless = await _idlessJmapRowFor(
      accountId,
      arrivalMailboxPath,
      mid,
      exceptId: realEmailId,
    );
    if (idless != null) {
      await _matchInPlace(idless, realEmailId, kind: 'no_server_id');
    }
  }

  /// The JMAP row of [accountId] in [mailboxPath] with Message-ID [mid]
  /// whose server id was never recorded, when exactly one exists.
  Future<Email?> _idlessJmapRowFor(
    String accountId,
    String mailboxPath,
    String mid, {
    required String exceptId,
  }) async {
    if ((await _bulkAccount(accountId))?.type !=
        account_model.AccountType.jmap) {
      return null;
    }
    final rows = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.isLocal.equals(false) &
                t.srvJmapId.isNull() &
                t.srvUid.isNull() &
                t.srvMailboxPath.equals(mailboxPath) &
                t.id.equals(exceptId).not() &
                (t.messageId.equals(mid) | t.messageId.equals('<$mid>')),
          )
          ..limit(2))
        .get();
    return rows.length == 1 ? rows.single : null;
  }

  /// [keep], a row waiting for its server copy ([_matchArrival]), takes the
  /// place of the just stored row [arrivedId]: the arrived row is merged
  /// into it ([_RowIdentity._mergeDuplicateRow]: its references follow, and
  /// its body replaces a virtual row's draft text), [keep] takes its server
  /// facts, headers and read stamps ([EmailStateWriter.takeOverRow]), its
  /// parked changes become pending, and an acked move it waited with
  /// settles against the new location. Logged (App Log warn
  /// `email.local_row_matched`: sync rewrote a local row and dropped a
  /// stored one).
  Future<void> _matchInPlace(
    Email keep,
    String arrivedId, {
    required String kind,
  }) async {
    final matched = await _db.transaction(() async {
      final current = await (_db.select(_db.emails)
            ..where((t) => t.id.equals(keep.id)))
          .getSingleOrNull();
      final arrived = await (_db.select(_db.emails)
            ..where((t) => t.id.equals(arrivedId)))
          .getSingleOrNull();
      if (current == null || arrived == null) return null;
      // Re-checked in the transaction: another isolate, or a second copy
      // with the same Message-ID, may have matched [current] meanwhile
      // (its parked changes are rewritten for that copy then), or
      // [arrived] may be a row that is waiting itself.
      if (!await _isWaiting(current) ||
          arrived.isLocal ||
          arrived.srvGone ||
          (arrived.srvUid == null && arrived.srvJmapId == null) ||
          normaliseMessageId(arrived.messageId) !=
              normaliseMessageId(current.messageId)) {
        return null;
      }
      // A virtual row's body is the draft text: the server's copy (stored,
      // or fetched when opened) replaces it.
      if (current.isLocal) {
        await (_db.delete(_db.emailBodies)
              ..where((t) => t.emailId.equals(current.id)))
            .go();
      }
      await _mergeDuplicateRow(dropId: arrived.id, keepId: current.id);
      await _state.takeOverRow(current.id, arrived);
      // Local-only: the folder a snooze of it came from.
      if (current.snoozedFromMailboxPath case final from?) {
        await _state.writeSnoozedFrom(current.id, from);
      }
      final unparked = await _unparkOps(current.id);
      await _state.settle(
        await _state.beginRead(current.accountId),
        current.id,
      );
      await _state.refold(current.id);
      return (current: current, arrived: arrived, unparked: unparked);
    });
    if (matched == null) return;
    final (:current, :arrived, unparked: result) = matched;
    final unparked = result.sent;
    final now = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(current.id)))
        .getSingleOrNull();
    await _updateThread(
      current.accountId,
      current.mailboxPath,
      current.threadId ?? current.id,
    );
    await _updateThread(
      arrived.accountId,
      arrived.mailboxPath,
      arrived.threadId ?? arrived.id,
    );
    if (now != null) {
      await _updateThread(
        now.accountId,
        now.mailboxPath,
        now.threadId ?? now.id,
      );
    }
    if (unparked > 0) _changeCtrl.add(current.accountId);
    final what = switch (kind) {
      'virtual' => 'the local copy shown since sending',
      'moved' => 'the row of the moved mail',
      _ => 'the row stored without a server id',
    };
    final refused = result.refusedDelete;
    unawaited(
      _appLogger?.warn(
        'email.local_row_matched',
        'The server copy of "${arrived.subject ?? '(no subject)'}" arrived '
            'in ${arrived.mailboxPath}: $what takes its place'
            '${unparked > 0 ? ', and its $unparked change(s) are sent now' : ''}'
            '${result.deletedForGood ? ' (the mail is deleted for good, as '
                'the user deleted the local copy)' : ''}'
            '${refused != null ? '; not deleted for good: it arrived '
                'elsewhere than where the user deleted it, so it shows '
                'again and the delete is listed as failed' : ''}',
        accountId: current.accountId,
        mailboxPath: arrived.mailboxPath,
        emailId: current.id,
        data: {
          'kind': kind,
          'droppedEmailId': arrived.id,
          'unparked': unparked,
          'deletedForGood': result.deletedForGood,
          if (refused != null) 'refusedDeleteId': refused.id,
          'shownBefore': current.mailboxPath,
        },
      ),
    );
  }

  /// Whether [row] still waits for its server copy ([_matchArrival]): a
  /// local virtual row, a row gone from its source with an acked move
  /// waiting for its destination copy, or a JMAP row whose server id was
  /// never recorded.
  Future<bool> _isWaiting(Email row) async {
    if (row.isLocal) return true;
    if (row.srvGone) {
      final waiting = await (_db.select(_db.pendingChanges)
            ..where(
              (t) =>
                  t.resourceId.equals(row.id) &
                  t.state.equals(_ackedState) &
                  t.leaseUntil.isNotNull(),
            )
            ..limit(1))
          .getSingleOrNull();
      return waiting != null;
    }
    return row.srvJmapId == null &&
        row.srvUid == null &&
        (await _bulkAccount(row.accountId))?.type ==
            account_model.AccountType.jmap;
  }

  /// The virtual row for Message-ID [mid] on [accountId] that is — or is not,
  /// per [sentCopy] — the Sent-folder copy of a message we sent (#918), as
  /// opposed to a self-send inbox note (#545). Null when there is none. A
  /// hidden one counts (a parked delete for good hides it): its server copy
  /// still has to be matched to it, and deleted.
  Future<Email?> _localRowFor(
    String accountId,
    String mid, {
    required bool sentCopy,
  }) async {
    final rows = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.isLocal.equals(true) &
                (t.messageId.equals(mid) | t.messageId.equals('<$mid>')),
          ))
        .get();
    for (final row in rows) {
      if (row.isVirtualSentCopy == sentCopy) return row;
    }
    return null;
  }

  /// The RFC 8621 / RFC 6154 role of the mailbox at [path] on [accountId], or
  /// null for a role-less custom folder.
  Future<String?> _mailboxRole(String accountId, String path) async {
    final row = await (_db.selectOnly(_db.mailboxes)
          ..addColumns([_db.mailboxes.role])
          ..where(
            _db.mailboxes.accountId.equals(accountId) &
                _db.mailboxes.path.equals(path),
          )
          ..limit(1))
        .getSingleOrNull();
    return row?.read(_db.mailboxes.role);
  }

  /// Mirrors a move (Archive / Spam / plain move) onto the matching message in
  /// every counterpart account — the same server mailbox connected via the
  /// other protocol (see [AccountComparison]).
  ///
  /// The destination path cannot simply be copied across: the IMAP and JMAP
  /// copies of the same server mailbox live under different [Mailbox.path]s. So
  /// the source destination's semantic [Mailbox.role] (e.g. `archive`, `junk`,
  /// `trash`) is resolved on each counterpart and used to locate the equivalent
  /// mailbox there; role-less custom folders fall back to a case-insensitive
  /// name match.
  ///
  /// Best-effort: counterparts that haven't synced the message yet, that have
  /// no equivalent destination mailbox, or that already hold the message in the
  /// destination are skipped so no redundant change is enqueued.
  Future<void> _mirrorMoveToCounterparts(
    String sourceAccountId,
    String? messageId,
    String destMailboxPath, {
    required String sourceRowId,
  }) async {
    // The move queued on the source row, which the twin's shadow follows.
    // None (the row is in the destination already, e.g. Undo's reverse move
    // after cancelling the original took its shadows along): nothing to
    // mirror.
    final targets = await _mirrorTargets(
      sourceAccountId,
      messageId,
      sourceRowId: sourceRowId,
      opTypes: _moveOpTypes,
    );
    if (targets == null || targets.twins.isEmpty) return;
    final (:primary, :twins) = targets;

    // Resolve the destination's role/name on the source account so the same
    // logical mailbox can be found on each counterpart.
    final sourceDest = await (_db.select(_db.mailboxes)
          ..where(
            (t) =>
                t.accountId.equals(sourceAccountId) &
                t.path.equals(destMailboxPath),
          )
          ..limit(1))
        .getSingleOrNull();
    final destRole = sourceDest?.role;
    final destName = sourceDest?.name ?? destMailboxPath;

    for (final row in twins) {
      final counterpartDest = await _resolveCounterpartMailboxPath(
        row.accountId,
        role: destRole,
        name: destName,
      );
      if (counterpartDest == null) {
        // The counterpart has no equivalent destination mailbox yet — e.g. an
        // Archive folder the primary account just created but that the
        // counterpart discovers only on a later mailbox sync. Both accounts
        // point at the same server, so the primary's move relocates the shared
        // message there and the counterpart will observe it leave the inbox on
        // its next sync. Until then, hide the now-stale local copy so the
        // combined inbox doesn't re-surface it as a duplicate of the message
        // the user just acted on (see #478).
        await _dropStaleCounterpartRow(row, primary);
        continue;
      }
      // Already in the destination → nothing to mirror.
      if (row.mailboxPath == counterpartDest) continue;

      await _asShadowOf(primary, () => _moveRow(row, counterpartDest));
    }
  }

  /// Hides a stale counterpart email [row] whose new folder the counterpart
  /// does not know yet, until its account's sync sees the mail leave
  /// (SYNC-REDESIGN.md §6): a shadow `delete` of [primarySeq], the move
  /// the primary account performs on the shared server message. It hides
  /// the row (the row and its body stay), is never sent, and settles like
  /// any shadow: dropped with its primary (the row shows again), or acked
  /// with it and dropped once a read of the counterpart finds the mail
  /// gone from (or elsewhere than) [Email.srvMailboxPath] ([awayFromKey]);
  /// the clean-up rule then deletes a gone row. Before, the row was deleted
  /// at once: a failed or undone move left the counterpart without it.
  Future<void> _dropStaleCounterpartRow(Email row, int primarySeq) async {
    await _asShadowOf(
      primarySeq,
      () => _enqueueChange(
        row.accountId,
        row.id,
        'delete',
        jsonEncode({awayFromKey: row.srvMailboxPath ?? row.mailboxPath}),
      ),
    );
    await _updateThread(row.accountId, row.mailboxPath, row.threadId ?? row.id);
  }

  /// Mirrors a delete onto the matching message in every counterpart account.
  /// Each counterpart runs its own [_UserActions._deleteRow] as a shadow of
  /// the source row's queued move to Trash or delete for good, so it shows
  /// the message in its own Trash when it has one, or hides it otherwise —
  /// robust when only one side of the pair has a Trash folder.
  Future<void> _mirrorDeleteToCounterparts(
    String sourceAccountId,
    String? messageId, {
    required String sourceRowId,
  }) async {
    final targets = await _mirrorTargets(
      sourceAccountId,
      messageId,
      sourceRowId: sourceRowId,
      opTypes: _deleteOpTypes,
    );
    if (targets == null) return;
    for (final row in targets.twins) {
      await _asShadowOf(targets.primary, () => _deleteRow(row));
    }
  }

  /// Finds the path of the mailbox on [accountId] that corresponds to a move
  /// whose source destination had the given [role] / [name]. Matches in the
  /// same order [AccountComparison] pairs the two protocol views of one server:
  /// exact (role, name) first, then role alone (roles are protocol-independent),
  /// then a case-insensitive name match for role-less custom folders. Returns
  /// null when the counterpart has no equivalent mailbox.
  ///
  /// The exact pass matters because a role is not unique: Stalwart ships
  /// "Deleted Items" as its trash folder, so a mailbox the user (or a test)
  /// creates as "Trash" carries role `trash` too. Matching on the role alone
  /// picked whichever of the two came first out of the DB, mirroring the move
  /// into the *sibling* trash folder — the shared server message then sat in
  /// both folders at once, which the single-folder local model cannot
  /// represent, and the two accounts diverged for good (#910).
  Future<String?> _resolveCounterpartMailboxPath(
    String accountId, {
    required String? role,
    required String name,
  }) async {
    final mailboxes = await (_db.select(_db.mailboxes)
          ..where((t) => t.accountId.equals(accountId)))
        .get();
    final lowerName = name.toLowerCase();
    for (final m in mailboxes) {
      if (m.role == role && m.name.toLowerCase() == lowerName) return m.path;
    }
    if (role != null) {
      for (final m in mailboxes) {
        if (m.role == role) return m.path;
      }
    }
    for (final m in mailboxes) {
      if (m.name.toLowerCase() == lowerName) return m.path;
    }
    return null;
  }
}
