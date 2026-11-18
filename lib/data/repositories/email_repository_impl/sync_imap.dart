part of '../email_repository_impl.dart';

// IMAP sync: fetch and upsert, flag refresh (CONDSTORE) and periodic flag
// reconcile, size backfill, deletion reconcile and UIDVALIDITY checkpoints.
// Every read/star/snooze value and every location read here goes through
// the server-write gate ([EmailStateWriter.beginRead]).

const _imapFlagReconcileInterval = Duration(minutes: 15);

const _imapSizeBackfillBatch = 500;

/// Marks an IMAP checkpoint whose next sync must be a full fetch (a force
/// resync): it keeps the folder's UIDVALIDITY, so a change is still seen.
const _forceFullKey = 'forceFull';

extension _SyncImap on EmailRepositoryImpl {
  Future<model.ImapMailboxState?> _lastImapMailboxState(
    String accountId,
    String mailboxPath,
  ) async {
    final checkpoint =
        await _loadImapCheckpoint(accountId, 'IMAP:$mailboxPath');
    if (checkpoint == null) return null;
    return model.ImapMailboxState(
      uidNext: checkpoint['uidNext'] as int?,
      exists: checkpoint['exists'] as int?,
      highestModSeq: checkpoint['highestModSeq'] as int?,
    );
  }

  /// A new IMAP connection to [account], logged in with [password].
  Future<imap.ImapClient> _connectImapAs(
    account_model.Account account,
    String password,
  ) =>
      _imapConnect(account, _effectiveUsername(account), password);

  Future<model.SyncEmailsResult> _syncEmailsImap(
    account_model.Account account,
    String password,
    String mailboxPath,
  ) async {
    // Read before this run's reads: a contradiction one of them finds makes
    // the reconcile due for the *next* run (see
    // [_maybeReconcileImapFlagsMailbox]).
    final reconcileDue = await _loadSyncState(
      account.id,
      _flagReconcileDueKey(mailboxPath, jmap: false),
    );
    final client = await _connectImapAs(account, password);
    try {
      // Only request CONDSTORE if the server advertises it. Servers that don't
      // support the extension may reject SELECT with (CONDSTORE) with BAD.
      final supportsCondStore = client.serverInfo.supports('CONDSTORE') ||
          client.serverInfo.supports('QRESYNC');
      final imap.Mailbox selectedMailbox;
      try {
        selectedMailbox = await client.selectUnicodeMailboxByPath(
          mailboxPath,
          enableCondStore: supportsCondStore,
        );
      } catch (e) {
        if (isImapMailboxNotFound(e)) {
          // The folder was deleted on the server between mailbox-sync and
          // email-sync of this cycle. Drop the local cache so subsequent
          // syncs don't keep retrying the same SELECT.
          log(
            'IMAP SELECT failed for "$mailboxPath" (folder deleted on '
            'server) — pruning local cache: $e',
          );
          await removeLocalMailbox(
            _db,
            account.id,
            mailboxPath,
            appLogger: _appLogger,
          );
          return model.SyncEmailsResult.zero;
        }
        rethrow;
      }
      final uidValidity = selectedMailbox.uidValidity ?? 0;
      final serverModSeq = selectedMailbox.highestModSequence;
      final resourceType = 'IMAP:$mailboxPath';
      final checkpoint = await _loadImapCheckpoint(account.id, resourceType);
      // Move-stable server id source (RFC 8474 EMAILID / Gmail X-GM-MSGID),
      // null when the server advertises neither (#589).
      final objectIdKind = resolveObjectIdKind(client.serverInfo);
      // What SELECT reported, with the highest UID fetched.
      Future<void> saveCheckpoint(int maxUid) => _saveImapCheckpoint(
            account.id,
            resourceType,
            uidValidity,
            maxUid,
            highestModSeq: serverModSeq,
            uidNext: selectedMailbox.uidNext,
            exists: selectedMailbox.messagesExists,
          );

      final validityChanged =
          checkpoint != null && checkpoint['uidValidity'] != uidValidity;
      // A force resync keeps the UIDVALIDITY and asks for a full fetch
      // ([_Sync._forceFullImapCheckpoints]).
      if (checkpoint == null ||
          validityChanged ||
          checkpoint[_forceFullKey] == true) {
        // First run, UID validity changed, or a force resync — full sync.
        // UID validity changed: the folder's UIDs name other mails now.
        // Its rows are gone; one with a queued change stays (hidden, or
        // where the change shows it) until the change settles. Without a
        // known previous UIDVALIDITY, the rows stamped with another one
        // than the server's are gone the same way.
        final kept = validityChanged
            ? await _state.markFolderGone(account.id, mailboxPath)
            : uidValidity == 0
                ? const <String>{}
                : await _state.markFolderGone(
                    account.id,
                    mailboxPath,
                    exceptUidValidity: uidValidity,
                  );
        if (kept.isNotEmpty) {
          unawaited(
            _appLogger?.warn(
              'sync.uidvalidity_changed',
              'The server renumbered $mailboxPath: ${kept.length} '
                  'mail(s) with a queued change are kept until the change '
                  'is applied or fails; the folder is fetched again',
              accountId: account.id,
              mailboxPath: mailboxPath,
              data: {'keptEmailIds': kept.take(100).toList()},
            ),
          );
        }
        // Use UID SEARCH ALL + UID FETCH so every message gets a reliable UID.
        // Regular FETCH 1:* may not populate msg.uid on all servers. The
        // read sequence is taken before the search: the sweep below applies
        // absence only to rows no later read (the fetch, an ack) placed.
        final enumeration = await _state.beginRead(account.id);
        final allUids = (await client.uidSearchMessages(
              searchCriteria: 'ALL',
            ))
                .matchingSequence
                ?.toList() ??
            [];
        var bytes = 0;
        if (allUids.isNotEmpty) {
          bytes = await _fetchAndUpsertImap(
            client,
            account,
            mailboxPath,
            imap.MessageSequence.fromIds(allUids, isUid: true),
            objectIdKind: objectIdKind,
            uidValidity: selectedMailbox.uidValidity,
          );
        }
        // The sweep of a complete refetch (a force resync, which keeps the
        // rows and forgets the checkpoint, SYNC-REDESIGN.md §6): a cached
        // row the fetch did not find is gone, and deleted unless the user
        // has a change of it.
        final swept = await _reconcileDeletedImap(
          account.id,
          mailboxPath,
          allUids,
          serverMessageCount: selectedMailbox.messagesExists,
          read: enumeration,
          complete: true,
          uidValidity: uidValidity == 0 ? null : uidValidity,
        );
        _logSwept(account.id, mailboxPath, swept);
        final maxUid = allUids.isEmpty ? 0 : allUids.reduce(math.max);
        await saveCheckpoint(maxUid);
        // Record that we've just fetched every flag so the periodic reconcile
        // in _maybeReconcileImapFlagsMailbox doesn't repeat it immediately.
        await _saveSyncState(
          account.id,
          'IMAP:FlagReconcile:$mailboxPath',
          DateTime.now().toIso8601String(),
        );
        await _sweepOrphanThreads(account.id, mailboxPath);
        return model.SyncEmailsResult(
          fetched: allUids.length,
          skipped: 0,
          bytesTransferred: bytes,
        );
      } else {
        // Incremental sync.
        final lastUid = checkpoint['lastUid'] as int;
        final storedModSeq = checkpoint['highestModSeq'] as int?;

        // Always search for new messages by UID. We intentionally do NOT use
        // CONDSTORE as a "skip everything" fast-path here because some servers
        // (including Stalwart 0.14.x) do not increment HIGHESTMODSEQ when new
        // mail is delivered via SMTP, causing newly arrived messages to be
        // silently missed when modseq values appear equal.
        // RFC 3501 §6.4.4 reads `n:*` as `*:n` when n is past the largest
        // UID, so with nothing new this still matches the newest message.
        // Without the filter every sync fetched that message again and
        // reported it as "1 new".
        final newUids = ((await client.uidSearchMessages(
                  searchCriteria: 'UID ${lastUid + 1}:*',
                ))
                    .matchingSequence
                    ?.toList() ??
                [])
            .where((uid) => uid > lastUid)
            .toList();
        var bytes = 0;
        if (newUids.isNotEmpty) {
          bytes = await _fetchAndUpsertImap(
            client,
            account,
            mailboxPath,
            imap.MessageSequence.fromIds(newUids, isUid: true),
            objectIdKind: objectIdKind,
            uidValidity: selectedMailbox.uidValidity,
          );
        }

        // CONDSTORE flag update: refresh flags only when something changed.
        if (serverModSeq != null &&
            storedModSeq != null &&
            serverModSeq != storedModSeq) {
          await _refreshFlagsImap(client, account, mailboxPath, storedModSeq);
        }

        // Belt-and-braces: periodically re-fetch every FLAGS in the mailbox
        // and rewrite `isSeen`/`isFlagged` from server truth. Catches drift
        // when CONDSTORE misreports — Stalwart 0.14.x does not always bump
        // HIGHESTMODSEQ when a flag is toggled via JMAP on the same account,
        // so IMAP would otherwise never see the change (#407).
        await _maybeReconcileImapFlagsMailbox(
          client,
          account.id,
          mailboxPath,
          dueValue: reconcileDue,
        );

        // Detect remote deletions. The read sequence is taken before the
        // search: absence it reports is applied only to rows whose location
        // no later read (or ack) wrote.
        final enumeration = await _state.beginRead(account.id);
        final serverUids = (await client.uidSearchMessages(
              searchCriteria: 'ALL',
            ))
                .matchingSequence
                ?.toList() ??
            [];
        await _reconcileDeletedImap(
          account.id,
          mailboxPath,
          serverUids,
          serverMessageCount: selectedMailbox.messagesExists,
          read: enumeration,
        );
        // Advance only past what was searched for and fetched above. Mail
        // that arrived after that search already shows up in [serverUids];
        // taking their maximum skipped it for good, since the next search
        // starts after the checkpoint. This relies on every UID in [newUids]
        // having been fetched above; if that fetch is ever capped or
        // chunked, advance only to the highest UID actually fetched.
        final maxUid = newUids.fold(lastUid, math.max);
        await saveCheckpoint(maxUid);
        await _sweepOrphanThreads(account.id, mailboxPath);
        return model.SyncEmailsResult(
          fetched: newUids.length,
          skipped: serverUids.length - newUids.length,
          bytesTransferred: bytes,
        );
      }
    } finally {
      await closeImapClient(client);
    }
  }

  /// Fetches FLAGS for all messages modified since [sinceModSeq] and writes
  /// them through the server-write gate. Only messages whose modseq is >
  /// [sinceModSeq] are returned by the server (RFC 7162 §3.2). A queued or
  /// just-sent read/star change keeps showing: it folds over the server's
  /// value until a read after its ack confirms it.
  Future<void> _refreshFlagsImap(
    imap.ImapClient client,
    account_model.Account account,
    String mailboxPath,
    int sinceModSeq,
  ) async {
    final read = await _state.beginRead(account.id);
    final result = await client.uidFetchMessages(
      imap.MessageSequence.fromAll(),
      'FLAGS',
      changedSinceModSequence: sinceModSeq,
    );
    // One transaction: CHANGEDSINCE can return thousands of messages after
    // a long time offline.
    final affectedThreads = <(String, String)>{};
    await _db.transaction(() async {
      final uidValidity = await _knownUidValidity(account.id, mailboxPath);
      final rows = <String, Email>{};
      final byRow = <String, ServerKeywords>{};
      for (final msg in result.messages) {
        final uid = msg.uid;
        if (uid == null) continue;
        final row = await _rowAtImapLocation(
          account.id,
          mailboxPath,
          uid,
          uidValidity: uidValidity,
        );
        if (row == null) continue;
        rows[row.id] = row;
        byRow[row.id] = ServerKeywords.imap(msg.flags);
      }
      for (final id in await read.writeAll(byRow)) {
        final row = rows[id]!;
        affectedThreads.add((row.mailboxPath, row.threadId ?? row.id));
      }
    });
    // The message list reads unread/starred state from the thread row, so
    // a mail read, unread, starred or unstarred on another device kept its
    // old look here although its own row was already up to date.
    for (final (shownIn, tid) in affectedThreads) {
      await _updateThread(account.id, shownIn, tid);
    }
  }

  /// Periodic safety net: at most once per [_imapFlagReconcileInterval] per
  /// mailbox, unconditionally `UID FETCH 1:* FLAGS` and write the server's
  /// read/star/snooze state through the server-write gate. Runs regardless
  /// of whether HIGHESTMODSEQ changed, so it catches drift when the server
  /// fails to advance MODSEQ on a flag mutation (Stalwart 0.14.x is known to
  /// do this for JMAP-side keyword changes, leaving the paired IMAP account
  /// permanently stale — #407). A queued change folds over the server's
  /// value, so an unflushed optimistic edit is not reverted.
  ///
  /// [dueValue] is the due marker as it was when the sync run started: one
  /// set during this run (an acked change a read just contradicted, SYNC.md
  /// §6a) waits for the next run, so the second read that may drop the
  /// change is a later one, not milliseconds later on the same connection.
  Future<void> _maybeReconcileImapFlagsMailbox(
    imap.ImapClient client,
    String accountId,
    String mailboxPath, {
    required String? dueValue,
  }) async {
    final key = 'IMAP:FlagReconcile:$mailboxPath';
    final last = await _loadSyncState(accountId, key);
    if (last != null && dueValue == null) {
      final lastAt = DateTime.tryParse(last);
      if (lastAt != null &&
          DateTime.now().difference(lastAt) < _imapFlagReconcileInterval) {
        return;
      }
    }

    final byUid = <int, ServerKeywords>{};
    // (shown folder, thread id) of each corrected row.
    final affectedThreads = <(String, String)>{};
    var corrected = 0;
    final read = await _state.beginRead(accountId);
    final fetch = await client.uidFetchMessages(
      imap.MessageSequence.fromAll(),
      'FLAGS',
    );
    for (final msg in fetch.messages) {
      final uid = msg.uid;
      if (uid == null) continue;
      byUid[uid] = ServerKeywords.imap(msg.flags);
    }

    // The rows the server has in this folder, wherever they are shown:
    // a UID names a message only in its server folder.
    final localRows = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.srvMailboxPath.equals(mailboxPath) &
                t.srvUid.isNotNull(),
          ))
        .get();

    // Every row is written, also an unchanged one: the stamp keeps a
    // slower, older read from overwriting it (unchanged rows in bulk). A
    // read/star change made meanwhile folds over the server's value. A
    // missing UID is handled by _reconcileDeletedImap.
    final rowsById = {
      for (final row in localRows)
        if (byUid.containsKey(row.srvUid)) row.id: row,
    };
    final changed = await read.writeAll({
      for (final row in rowsById.values) row.id: byUid[row.srvUid]!,
    });
    for (final id in changed) {
      final row = rowsById[id]!;
      affectedThreads.add((row.mailboxPath, row.threadId ?? row.id));
      corrected++;
    }

    for (final (shownIn, tid) in affectedThreads) {
      await _updateThread(accountId, shownIn, tid);
    }
    await _backfillImapSizes(
      client,
      [
        for (final row in localRows)
          if (row.sizeBytes == null && byUid.containsKey(row.srvUid)) row,
      ],
    );

    if (corrected > 0) {
      log(
        'IMAP-sync: flag-reconcile mailbox=$mailboxPath corrected=$corrected '
        '(local=${localRows.length}, server=${byUid.length})',
      );
    }
    await _saveSyncState(accountId, key, DateTime.now().toIso8601String());
    await _settleFlagReconcileDue(
      accountId,
      mailboxPath,
      jmap: false,
      dueValue: dueValue,
    );
  }

  /// Fetches RFC822.SIZE for [rows] (cached before schema v64, still on the
  /// server) in batches and stores it. Only these rows are asked for, so once
  /// a mailbox is backfilled the reconcile costs nothing extra.
  Future<void> _backfillImapSizes(
    imap.ImapClient client,
    List<Email> rows,
  ) async {
    // Rows of the selected folder, by the UID the server has them under.
    final idByUid = {for (final r in rows) r.srvUid!: r.id};
    final uids = idByUid.keys.toList();
    for (var i = 0; i < uids.length; i += _imapSizeBackfillBatch) {
      final batch =
          uids.sublist(i, math.min(i + _imapSizeBackfillBatch, uids.length));
      final fetch = await client.uidFetchMessages(
        imap.MessageSequence.fromIds(batch, isUid: true),
        'RFC822.SIZE',
      );
      await _backfillSizes({
        for (final msg in fetch.messages)
          if (idByUid[msg.uid] != null && msg.size != null)
            idByUid[msg.uid]!: msg.size!,
      });
    }
  }

  /// Stores the message sizes in [sizeById] (email row id → bytes) in one
  /// batch: rows cached before schema v64 have none, and the first
  /// reconcile after the upgrade can fill in a whole mailbox at once.
  Future<void> _backfillSizes(Map<String, int> sizeById) async {
    await _state.writeSizes(sizeById);
  }

  // Returns the total bytes transferred (sum of RFC822.SIZE for each message).
  Future<int> _fetchAndUpsertImap(
    imap.ImapClient client,
    account_model.Account account,
    String mailboxPath,
    imap.MessageSequence sequence, {
    ObjectIdKind? objectIdKind,
    int? uidValidity,
  }) async {
    // The offline preview snippet (matching the JMAP `preview` field, see
    // [_upsertJmapEmails] — IMAP has no standard preview property) is fetched
    // separately by [_fetchPreviewSnippetsSafely]: enough_mail's response
    // tokeniser mis-parses any partial `BODY.PEEK[…]<0.n>` item, so asking for
    // it here would set the message body to the literal string `0>` (#680).
    const fetchItems = '(UID FLAGS INTERNALDATE ENVELOPE BODYSTRUCTURE '
        'RFC822.SIZE BODY.PEEK[HEADER.FIELDS (REFERENCES LIST-UNSUBSCRIBE)])';
    // Usually new UIDs only, but a row can already exist (relocated after
    // a move, or a full sync without a checkpoint): its FLAGS and location
    // go through the server-write gate, so a change made meanwhile keeps
    // showing.
    return _fetchAndUpsertImapGuarded(
      client,
      account,
      mailboxPath,
      sequence,
      fetchItems,
      objectIdKind: objectIdKind,
      uidValidity: uidValidity,
    );
  }

  Future<int> _fetchAndUpsertImapGuarded(
    imap.ImapClient client,
    account_model.Account account,
    String mailboxPath,
    imap.MessageSequence sequence,
    String fetchItems, {
    ObjectIdKind? objectIdKind,
    int? uidValidity,
  }) async {
    // Taken before the FETCH as well as after it: a move or delete queued
    // before the FETCH may have been sent, acked and settled by a later
    // read while its answer was on the way, yet the answer still lists the
    // mail here (#1269). An applied change stays (acked) until a read
    // started after it confirms it, so the check after the FETCH sees one
    // sent meanwhile.
    final pendingBeforeFetch = await _pendingDeleteOrMoveUids(
      account.id,
      mailboxPath,
      uidValidity: uidValidity,
    );
    final read = await _state.beginRead(account.id);
    final fetch = sequence.isUidSequence
        ? await client.uidFetchMessages(sequence, fetchItems)
        : await client.fetchMessages(sequence, fetchItems);
    // enough_mail can't parse EMAILID/X-GM-MSGID, so pull the move-stable id
    // for the same sequence with a separate raw FETCH. Best-effort: any failure
    // leaves the map empty and the rows fall back to UID-only identity (#589).
    final serverEmailIdByUid = await _fetchServerEmailIds(
      client,
      sequence,
      objectIdKind,
    );
    final previewSnippetByUid = await _fetchPreviewSnippetsSafely(
      client,
      sequence,
    );
    // A change that failed meanwhile (e.g. a refused delete) no longer
    // hides the mail: the server's copy is shown again, as below for a
    // change made during the FETCH.
    final failedNow = await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.accountId.equals(account.id) &
                t.state.equals(_failedState) &
                t.changeType.isIn(_placementChangeTypes),
          ))
        .get();
    final failedIds = {for (final c in failedNow) c.id};
    final pendingByUid = {
      for (final MapEntry(:key, :value) in pendingBeforeFetch.entries)
        if (!failedIds.contains(value.id)) key: value,
      ...await _pendingDeleteOrMoveUids(
        account.id,
        mailboxPath,
        uidValidity: uidValidity,
      ),
    };
    var bytes = 0;
    final affectedThreads = <String>{};
    // (folder shown before, thread id) of existing rows whose folder changed.
    final hiddenOrMovedThreads = <(String, String)>{};
    // (emailId, messageId, isNew) of each row written: matched afterwards
    // with a row waiting for its server copy ([_Counterparts._matchArrival]).
    final dissolveCandidates = <(String, String?, bool)>[];
    // (emailId, subject, size) of each row stored for the first time — logged
    // after the transaction so "Show Logs" starts with the fetch (#920).
    final newlyStored = <(String, String?, int?)>[];
    await _db.transaction(() async {
      for (final msg in fetch.messages) {
        final envelope = msg.envelope;
        if (envelope == null) {
          log(
            'IMAP: skipping message with no envelope (uid=${msg.uid}, mailbox=$mailboxPath)',
          );
          continue;
        }
        final uid = msg.uid;
        if (uid == null) {
          log('IMAP: skipping message with no uid (mailbox=$mailboxPath)');
          continue;
        }
        // The row the server's message already has, found by where the
        // server has it, never by the shown folder: behind a queued move
        // that is already the destination (SYNC-REDESIGN.md §8 phase 2).
        // Without one, the message gets a new row with a new id.
        final msgId = normaliseMessageId(envelope.messageId);
        final atLocation = await _rowAtImapLocation(
          account.id,
          mailboxPath,
          uid,
          uidValidity: uidValidity,
        );
        // A row recorded without a UIDVALIDITY matches this UID under any
        // one; when it holds another mail (its Message-ID differs), the UID
        // was reused: it is not this mail's row, and must not take its
        // headers over its own body and attachments. The deletion
        // reconcile marks it gone once a stamped row holds the UID.
        final storedMsgId = normaliseMessageId(atLocation?.messageId);
        final reused = atLocation != null &&
            atLocation.srvUidValidity == null &&
            uidValidity != null &&
            uidValidity != 0 &&
            msgId != null &&
            storedMsgId != null &&
            storedMsgId != msgId;
        final known = reused ? null : atLocation;
        // Don't bring back, as a new row, a mail the user moved or deleted
        // from here: its row has left this location (a move's answer
        // relocated it), but the change is still queued, being sent or
        // acked. `UID lastUid+1:*` can even return a UID smaller than
        // `lastUid+1` because RFC 3501 §6.4.4 reverses `n:*` to `*:n` when
        // `n` exceeds the largest UID. A row still recorded here keeps its
        // pending change folded over what is written below.
        if (known == null && pendingByUid.containsKey(uid)) {
          log(
            'IMAP: skipping insert for uid=$uid in $mailboxPath '
            '(${pendingByUid[uid]!.state} ${pendingByUid[uid]!.changeType})',
          );
          continue;
        }
        bytes += msg.size ?? 0;
        final emailId = known?.id ?? _newId(account.id);
        final serverEmailId = serverEmailIdByUid[uid];
        final inReplyTo = normaliseMessageId(envelope.inReplyTo);
        final refs = normaliseReferences(msg.getHeaderValue('References'));
        final listUnsubscribe = msg.getHeaderValue('List-Unsubscribe')?.trim();
        // Re-decode Subject from the raw header enough_mail stashed on the
        // message during envelope parsing (#418). `envelope.subject` uses
        // MailCodec.decodeHeader, which leaves stray spaces around ü/ö/ä
        // when adjacent encoded-words differ in charset case or are folded
        // with a tab.
        final subject =
            decodeMailHeader(msg.getHeaderValue('Subject')) ?? envelope.subject;
        final threadId = _computeThreadId(
              messageId: msgId,
              inReplyTo: inReplyTo,
              references: refs,
              subject: subject,
              date: envelope.date,
            ) ??
            emailId;
        affectedThreads.add(threadId);

        final keywords = ServerKeywords.imap(msg.flags);

        final isNew = known == null;
        final headers = ServerRowHeaders(
          uid: uid,
          subject: subject,
          sentAt: envelope.date,
          // The server's arrival time, like JMAP `receivedAt`. Never
          // the local fetch time when the server knows better: mail
          // without a Date header used to be re-dated to "now" on every
          // re-fetch, so a resync or reinstall moved it to the top.
          receivedAt: parseImapDateTime(msg.internalDate) ??
              envelope.date ??
              DateTime.now(),
          fromJson: _encodeAddresses(envelope.from),
          toJson: _encodeAddresses(envelope.to),
          ccJson: _encodeAddresses(envelope.cc),
          replyToJson: _encodeAddresses(envelope.replyTo),
          bccJson: _encodeAddresses(envelope.bcc),
          sizeBytes: msg.size,
          preview: previewFromSnippet(msg, previewSnippetByUid[uid]),
          // enough_mail counts parts with Content-Disposition: attachment;
          // JMAP's hasAttachment (below) is server-defined, so the two
          // protocols may disagree on e.g. inline images.
          hasAttachment: msg.hasAttachments(),
          threadId: threadId,
          messageId: msgId,
          inReplyTo: inReplyTo,
          references: refs,
          listUnsubscribeHeader: listUnsubscribe,
          // A previously captured id stays when this fetch could not read
          // one (null is not written).
          serverEmailId: serverEmailId,
          srvUid: uid,
          srvUidValidity:
              uidValidity == null || uidValidity == 0 ? null : uidValidity,
        );
        // The read/star/snooze state and the folder only through the
        // server-write gate: with the row's other server facts for a new
        // row, else on their own (a whole-row write would also overwrite the
        // user's pending values, and a moved mail would jump back).
        if (isNew) {
          await _state.insertServerRow(
            headers,
            id: emailId,
            accountId: account.id,
            mailboxPath: mailboxPath,
            keywords: keywords,
            seq: read.seq,
          );
        } else {
          await _state.writeServerHeaders(emailId, headers);
          // The mail is here: a row marked gone by an older read shows again.
          final moved = await read.writeLocation(emailId, mailboxPath);
          if (moved != null && moved.changed) {
            hiddenOrMovedThreads
              ..add((moved.before, known.threadId ?? emailId))
              ..add((moved.after, threadId));
          }
          await read.write(emailId, keywords);
        }
        if (msgId != null) dissolveCandidates.add((emailId, msgId, isNew));
        if (isNew) newlyStored.add((emailId, subject, msg.size));
      }
    });
    // Outside the transaction: the app log writes through the same database.
    for (final (emailId, subject, size) in newlyStored) {
      _logEmailFetched(
        emailId: emailId,
        accountId: account.id,
        mailboxPath: mailboxPath,
        protocol: 'imap',
        subject: subject,
        bytes: size,
      );
    }
    for (final tid in affectedThreads) {
      await _updateThread(account.id, mailboxPath, tid);
    }
    for (final (shownIn, tid) in hiddenOrMovedThreads) {
      await _updateThread(account.id, shownIn, tid);
    }
    if (dissolveCandidates.isNotEmpty && await _hasWaitingRows(account.id)) {
      for (final (emailId, msgId, isNew) in dissolveCandidates) {
        await _matchArrival(
          account.id,
          mailboxPath,
          emailId,
          msgId,
          isNew: isNew,
        );
      }
    }
    return bytes;
  }

  /// Fetches the move-stable server id for every UID in [sequence] when the
  /// server advertises one ([objectIdKind] non-null). Returns an empty map when
  /// unsupported or on any error, so a server that mishandles the raw FETCH
  /// degrades to the UID-based identity scheme instead of failing the sync.
  Future<Map<int, String>> _fetchServerEmailIds(
    imap.ImapClient client,
    imap.MessageSequence sequence,
    ObjectIdKind? objectIdKind,
  ) async {
    if (objectIdKind == null) return const {};
    try {
      return await _fetchObjectIds(client, sequence, objectIdKind);
    } catch (e) {
      log('IMAP: ${objectIdKind.fetchItem} fetch failed, '
          'falling back to UID identity: $e');
      return const {};
    }
  }

  /// Fetches the body prefix used for the offline preview snippet, best-effort.
  ///
  /// Fail-open: a server that rejects the partial fetch leaves rows without a
  /// preview until [getEmailBody] backfills one, which beats failing the sync.
  Future<Map<int, Uint8List>> _fetchPreviewSnippetsSafely(
    imap.ImapClient client,
    imap.MessageSequence sequence,
  ) async {
    try {
      return await _fetchPreviewSnippets(
        client,
        sequence,
        kPreviewSnippetBytes,
      );
    } catch (e) {
      log('IMAP: preview snippet fetch failed, syncing without previews: $e');
      return const {};
    }
  }

  /// Whether [accountId] has any row that may wait for its server copy
  /// ([_Counterparts._matchArrival]): a local virtual row (#545, #918), a
  /// row gone from its source (an acked move waiting for its destination
  /// copy), or one without a server location (a JMAP mail whose id is
  /// unknown). A one-shot guard so sync's per-message match is skipped
  /// entirely in the common case.
  Future<bool> _hasWaitingRows(String accountId) async {
    final row = await (_db.selectOnly(_db.emails)
          ..addColumns([_db.emails.id])
          ..where(
            _db.emails.accountId.equals(accountId) &
                (_db.emails.isLocal.equals(true) |
                    _db.emails.srvGone.equals(true) |
                    (_db.emails.srvUid.isNull() &
                        _db.emails.srvJmapId.isNull())),
          )
          ..limit(1))
        .getSingleOrNull();
    return row != null;
  }

  // UIDs in [mailboxPath] that have a local delete, move, snooze or
  // unsnooze queued, being sent or acked (applied, not yet confirmed by a
  // later read), with that change. Used by the IMAP fetch path to avoid
  // re-inserting rows the user has already removed from there (#1269). A
  // failed change is not counted: the server's copy is shown again.
  // Neither is one stamped with another [uidValidity] than the folder's
  // current one: its UID names another mail now.
  Future<Map<int, PendingChangeRow>> _pendingDeleteOrMoveUids(
    String accountId,
    String mailboxPath, {
    int? uidValidity,
  }) async {
    final rows = await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.state.isIn(const [..._liveStates, _ackedState]) &
                t.resourceType.equals('Email') &
                t.changeType.isIn(_placementChangeTypes),
          ))
        .get();
    final result = <int, PendingChangeRow>{};
    for (final r in rows) {
      try {
        final payload = jsonDecode(r.payload) as Map<String, dynamic>;
        // Snooze and unsnooze name their source `src`.
        if ((payload['mailboxPath'] ?? payload['src']) != mailboxPath) {
          continue;
        }
        // Its UID is the one from before a queued move, not this folder's:
        // it may be another mail's here, which must not be skipped (#1266).
        if (payload[_uidAfterMoveKey] == true) continue;
        final stamped = payload['uidValidity'];
        if (uidValidity != null && stamped is int && stamped != uidValidity) {
          continue;
        }
        final uid = payload['uid'];
        if (uid is int) result[uid] = r;
      } catch (_) {
        // Malformed payload — skip.
      }
    }
    return result;
  }

  Future<Map<String, dynamic>?> _loadImapCheckpoint(
    String accountId,
    String resourceType,
  ) async {
    final raw = await _loadSyncState(accountId, resourceType);
    if (raw == null) return null;
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  /// The UIDVALIDITY of IMAP folder [mailboxPath] as its sync checkpoint
  /// knows it; null when unknown (never synced, or the server sent none).
  Future<int?> _knownUidValidity(String accountId, String mailboxPath) async {
    final checkpoint =
        await _loadImapCheckpoint(accountId, 'IMAP:$mailboxPath');
    final validity = checkpoint?['uidValidity'];
    return validity is int && validity != 0 ? validity : null;
  }

  Future<void> _saveImapCheckpoint(
    String accountId,
    String resourceType,
    int uidValidity,
    int lastUid, {
    int? highestModSeq,
    int? uidNext,
    int? exists,
  }) async {
    final data = <String, dynamic>{
      'uidValidity': uidValidity,
      'lastUid': lastUid,
    };
    if (highestModSeq != null) data['highestModSeq'] = highestModSeq;
    // What SELECT reported, for the IDLE wait's catch-up check
    // ([lastImapMailboxState]).
    if (uidNext != null) data['uidNext'] = uidNext;
    if (exists != null) data['exists'] = exists;
    await _saveSyncState(accountId, resourceType, jsonEncode(data));
  }

  Future<void> _reconcileDeletedImapForTest(
    String accountId,
    String mailboxPath,
    List<int> serverUids, {
    int? serverMessageCount,
  }) async {
    await _reconcileDeletedImap(
      accountId,
      mailboxPath,
      serverUids,
      serverMessageCount: serverMessageCount,
      read: await _state.beginRead(accountId),
    );
  }

  /// The location read of [mailboxPath]'s `UID SEARCH ALL` ([read], taken
  /// before the search): every row the server has there (by
  /// `srv_mailbox_path`, wherever it is shown) is confirmed present or,
  /// when its UID is missing, carried over to its moved copy or marked gone
  /// ([KeywordRead.markGone]); acked changes settle. A row marked gone is
  /// deleted only when it has no change left ([EmailStateWriter.cleanUpGone]):
  /// one the user still has a change queued for stays until that change
  /// settles (SYNC-REDESIGN.md §2, clean-up rule).
  ///
  /// A row counts as present only under the folder's UIDVALIDITY
  /// ([uidValidity], else the checkpoint's): a row stamped with another one
  /// is gone (its UID names another mail now), and an unstamped row only
  /// while no row stamped with the current one holds its UID (else it is a
  /// stale duplicate).
  ///
  /// [complete]: every UID of [serverUids] was fetched after [read] was
  /// taken (the full fetch), so each row the server still has there was
  /// written by a later read. The selection is then every row of the folder
  /// not marked gone yet (`srv_gone = 0`), not only the rows with a UID
  /// (`srv_uid IS NOT NULL`): a row without a UID could not be found by the
  /// fetch, so it is gone (or a stale duplicate of the row the fetch
  /// stored), unless a read after [read] placed it (SYNC-REDESIGN.md §6, the
  /// sweep of a force resync). Returns the rows marked gone, as read
  /// before.
  Future<List<Email>> _reconcileDeletedImap(
    String accountId,
    String mailboxPath,
    List<int> serverUids, {
    int? serverMessageCount,
    required KeywordRead read,
    bool complete = false,
    int? uidValidity,
  }) async {
    // The rows the server has in this folder, wherever they are shown: a
    // UID names a message only in its server folder. A row without a UID
    // (local, or its location taken by another mail) cannot be checked,
    // except after a complete fetch.
    final localRows = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.srvMailboxPath.equals(mailboxPath) &
                (complete ? t.srvGone.equals(false) : t.srvUid.isNotNull()) &
                t.isLocal.equals(false),
          ))
        .get();

    // Guard: an empty `UID SEARCH ALL` is ambiguous — it can mean the mailbox
    // really is empty, or that the response was incomplete (network glitch,
    // buggy IMAP server). Distinguish the two using the authoritative EXISTS
    // count from the SELECT response:
    //   • EXISTS == 0  → the folder genuinely has no messages. Trust it and
    //     reconcile, so a folder emptied on the server (e.g. the last message
    //     was deleted/moved to Trash via another account or client) also
    //     clears locally instead of leaving a phantom row behind.
    //   • EXISTS  > 0  (or unknown) → the server claims messages exist but the
    //     search returned none. That's the suspicious case; skip to avoid
    //     wiping the cache on a bad response.
    if (serverUids.isEmpty && localRows.isNotEmpty && serverMessageCount != 0) {
      log(
        '_reconcileDeletedImap: skipping — server returned 0 UIDs for '
        '$mailboxPath but local DB has ${localRows.length} emails '
        '(EXISTS=${serverMessageCount ?? '?'})',
      );
      return const [];
    }

    final serverUidSet = serverUids.toSet();
    final validity =
        uidValidity ?? await _knownUidValidity(accountId, mailboxPath);
    // UIDs a row stamped with the folder's UIDVALIDITY holds: an unstamped
    // row at one of them is a stale duplicate, not that mail.
    final stampedUids = {
      for (final row in localRows)
        if (validity != null && row.srvUidValidity == validity) row.srvUid,
    };
    bool isPresent(Email row) {
      if (!serverUidSet.contains(row.srvUid)) return false;
      if (validity == null) return true;
      final stamp = row.srvUidValidity;
      if (stamp == null) return !stampedUids.contains(row.srvUid);
      return stamp == validity;
    }

    final present = <Email>[];
    final gone = <Email>[];
    for (final row in localRows) {
      if (isPresent(row)) {
        present.add(row);
        continue;
      }
      // A message that vanished from this folder but reappeared under a
      // different folder with the same move-stable server id (RFC 8474
      // EMAILID / Gmail X-GM-MSGID) was moved, not deleted. Its row
      // carries over to the new location with its id, body and
      // references, as after a move we made ourselves (#589); the row
      // sync stored there is merged into it. Correct for Gmail/COPY too:
      // those keep the message in the source folder, so no vanish fires.
      final copy = await _movedCopyOf(row, mailboxPath, serverUidSet);
      if (copy != null) {
        final carried = await _carryOverMovedRow(
          row: row,
          copy: copy,
          vanishedFrom: mailboxPath,
        );
        if (carried.dropped case final dropped?) {
          _logMovedRowCarriedOver(row, dropped);
          await _updateThread(accountId, mailboxPath, row.threadId ?? row.id);
        }
        if (carried.kept) continue;
      }
      gone.add(row);
    }
    final shown =
        await read.confirmPresent([for (final row in present) row.id]);
    for (final row in present) {
      if (!shown.contains(row.id)) continue;
      await _rethreadRow(row.id);
    }
    final marked = await read.markGone([for (final row in gone) row.id]);
    await _settleGoneRows(accountId, gone, marked);
    return [
      for (final row in gone)
        if (marked.contains(row.id)) row,
    ];
  }
}
