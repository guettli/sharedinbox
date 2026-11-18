part of '../email_repository_impl.dart';

// Counterpart mirroring: copies of the same message in other folders and
// accounts (by Message-ID), and dissolving a local self-sent row into the
// server copy.

extension _Counterparts on EmailRepositoryImpl {
  /// Mirrors a snooze (or an un-snooze when [until] is null) onto the matching
  /// message in every counterpart account — the same server mailbox connected
  /// via the other protocol (see [AccountComparison]).
  ///
  /// A user who connects to one server via both IMAP and JMAP has two
  /// independent [Account] rows, each with its own copy of every message, so
  /// snoozing on one account leaves the other untouched. This bridges them:
  /// messages are correlated by their normalised RFC 2822 Message-ID and the
  /// same optimistic update + pending change is applied to the counterpart,
  /// which then flushes through that account's own protocol path.
  ///
  /// Best-effort: counterparts that haven't synced the message yet are skipped
  /// (their next sync reconstructs the snooze from the shared server-side
  /// `snz:` keyword anyway), and rows already in the requested state are left
  /// alone so no redundant change is enqueued.
  Future<void> _mirrorSnoozeToCounterparts(
    String sourceAccountId,
    String? messageId, {
    required DateTime? until,
  }) async {
    final mid = normaliseMessageId(messageId);
    if (mid == null) return;

    final source = await _accounts.getAccount(sourceAccountId);
    if (source == null) return;
    final all = await _accounts.observeAccounts().first;
    final counterparts = AccountComparison.counterpartsOf(source, all);
    if (counterparts.isEmpty) return;

    for (final counterpart in counterparts) {
      final row = await _findEmailRowByNormalisedMessageId(counterpart.id, mid);
      if (row == null) continue;

      if (until != null) {
        // Already snoozed to (about) the same time → nothing to mirror.
        final current = row.snoozedUntil;
        if (current != null &&
            current.difference(until).abs() < const Duration(seconds: 1)) {
          continue;
        }
        await _snoozeRow(row, until);
      } else {
        // Already awake → nothing to mirror.
        if (row.snoozedUntil == null) continue;
        await _unsnoozeRow(row);
      }
    }
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

  /// Dissolves a local self-sent "virtual" message once its real counterpart
  /// [realEmailId] arrives in [arrivalMailboxPath] via sync: transfers the
  /// star, read state and folder the user set on the virtual copy onto the
  /// real message, then removes the virtual row. Notes need no migration —
  /// they are keyed by Message-ID, which both rows share. No-op when there is
  /// no matching local row, so it is safe to call for every synced message
  /// and safe to replay. See #545.
  Future<void> _maybeDissolveLocalMessageForTest(
    String accountId,
    String arrivalMailboxPath,
    String realEmailId,
    String? messageId,
  ) =>
      _maybeDissolveLocalMessage(
        accountId,
        arrivalMailboxPath,
        realEmailId,
        messageId,
      );

  /// Replays the user's earlier actions on a virtual row onto the real
  /// message: queued as automatic changes ([_ChangeQueue._asAutomaticChange]).
  Future<void> _maybeDissolveLocalMessage(
    String accountId,
    String arrivalMailboxPath,
    String realEmailId,
    String? messageId,
  ) =>
      _asAutomaticChange(
        () => _dissolveLocalMessage(
          accountId,
          arrivalMailboxPath,
          realEmailId,
          messageId,
        ),
      );

  Future<void> _dissolveLocalMessage(
    String accountId,
    String arrivalMailboxPath,
    String realEmailId,
    String? messageId,
  ) async {
    final mid = normaliseMessageId(messageId);
    if (mid == null) return;

    // A send can leave two virtual rows behind: the self-send note in the
    // inbox (#545) and, when the server gave us no APPENDUID, the Sent copy
    // (#918). Pair each with the arrival it actually is, keyed off
    // `isVirtualSentCopy` rather than its current folder — the user may well
    // have filed the note into Trash, and that move is exactly what
    // dissolving carries over.
    // Matching the wrong one would move an inbox arrival into Sent.
    final arrivalIsSent =
        await _mailboxRole(accountId, arrivalMailboxPath) == 'sent';
    final local = await _localRowFor(accountId, mid, sentCopy: arrivalIsSent);
    if (local == null || local.id == realEmailId) return;

    final targetMailbox = local.mailboxPath;
    final wantFlagged = local.isFlagged;
    final wantSeen = local.isSeen;
    final localThreadId = local.threadId ?? local.id;

    // Remove the virtual row first so thread aggregates count only the real
    // message from here on.
    await _state.deleteRow(local.id);
    await (_db.delete(_db.emailBodies)
          ..where((t) => t.emailId.equals(local.id)))
        .go();
    await _updateThread(accountId, local.mailboxPath, localThreadId);

    final real = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(realEmailId)))
        .getSingleOrNull();
    if (real == null) return;

    // Carry the user's star / read state onto the real message. setFlag also
    // enqueues the matching server mutation so the two converge.
    final seenArg = wantSeen != real.isSeen ? wantSeen : null;
    final flaggedArg = wantFlagged != real.isFlagged ? wantFlagged : null;
    if (seenArg != null || flaggedArg != null) {
      await setFlag(realEmailId, seen: seenArg, flagged: flaggedArg);
    }

    // Carry the folder the user filed the note into (e.g. Trash) onto the real
    // message. moveEmail enqueues the server move and refreshes threads.
    if (targetMailbox != real.mailboxPath) {
      await moveEmail(realEmailId, targetMailbox);
    }
  }

  /// The virtual row for Message-ID [mid] on [accountId] that is — or is not,
  /// per [sentCopy] — the Sent-folder copy of a message we sent (#918), as
  /// opposed to a self-send inbox note (#545). Null when there is none.
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
                (t.messageId.equals(mid) | t.messageId.equals('<$mid>')) &
                _visible(t),
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
    String destMailboxPath,
  ) async {
    final mid = normaliseMessageId(messageId);
    if (mid == null) return;

    final source = await _accounts.getAccount(sourceAccountId);
    if (source == null) return;
    final all = await _accounts.observeAccounts().first;
    final counterparts = AccountComparison.counterpartsOf(source, all);
    if (counterparts.isEmpty) return;

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

    for (final counterpart in counterparts) {
      final row = await _findEmailRowByNormalisedMessageId(counterpart.id, mid);
      if (row == null) continue;

      final counterpartDest = await _resolveCounterpartMailboxPath(
        counterpart.id,
        role: destRole,
        name: destName,
      );
      if (counterpartDest == null) {
        // The counterpart has no equivalent destination mailbox yet — e.g. an
        // Archive folder the primary account just created but that the
        // counterpart discovers only on a later mailbox sync. Both accounts
        // point at the same server, so the primary's move relocates the shared
        // message there and the counterpart will observe it leave the inbox on
        // its next sync. Until then, drop the now-stale local copy so the
        // combined inbox doesn't re-surface it as a duplicate of the message
        // the user just acted on (see #478).
        await _dropStaleCounterpartRow(row);
        continue;
      }
      // Already in the destination → nothing to mirror.
      if (row.mailboxPath == counterpartDest) continue;

      await _moveRow(row, counterpartDest);
    }
  }

  /// Removes a stale local counterpart email [row] from the cache without
  /// enqueuing a protocol change (the primary account already performs the
  /// real server move on the shared message) and refreshes its thread so the
  /// row stops appearing in the combined inbox until the next sync reconciles
  /// it to its true server location. See [_mirrorMoveToCounterparts].
  Future<void> _dropStaleCounterpartRow(Email row) async {
    await _state.deleteRow(row.id);
    await _updateThread(row.accountId, row.mailboxPath, row.threadId ?? row.id);
  }

  /// Mirrors a delete onto the matching message in every counterpart account.
  /// Each counterpart runs its own [_UserActions._deleteRow], so it independently moves the
  /// message to its own Trash when it has one, or hard-deletes otherwise —
  /// robust when only one side of the pair has a Trash folder.
  Future<void> _mirrorDeleteToCounterparts(
    String sourceAccountId,
    String? messageId,
  ) async {
    final mid = normaliseMessageId(messageId);
    if (mid == null) return;

    final source = await _accounts.getAccount(sourceAccountId);
    if (source == null) return;
    final all = await _accounts.observeAccounts().first;
    final counterparts = AccountComparison.counterpartsOf(source, all);
    if (counterparts.isEmpty) return;

    for (final counterpart in counterparts) {
      final row = await _findEmailRowByNormalisedMessageId(counterpart.id, mid);
      if (row == null) continue;
      await _deleteRow(row);
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
