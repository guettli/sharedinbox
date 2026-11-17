part of '../email_repository_impl.dart';

// IMAP sync: fetch and upsert, flag refresh (CONDSTORE) and periodic flag
// reconcile, size backfill, deletion reconcile, UIDVALIDITY checkpoints and
// the guard against a stale new-mail FETCH bringing back a moved mail. Every
// read/star/snooze value read here goes through the server-write gate
// ([EmailStateWriter.beginRead]).

/// A new-mail FETCH in progress (see [_SyncImap._startFetchGuard]): its
/// answer reflects the server at some point after [_seq] was taken, so it
/// must not bring back a mail that was moved or deleted locally since
/// (#1269).
class _FetchLocationGuard {
  _FetchLocationGuard(this._seq, this._editByLocation);

  final int _seq;
  final Map<_ImapLocation, (int, String)> _editByLocation;

  /// The id of the row whose mail the server had at [uid] in [mailboxPath]
  /// when a move, snooze, unsnooze or delete of it was queued (or retried)
  /// after the FETCH started; null when there is none.
  String? editedAt(String accountId, String mailboxPath, int uid) {
    final edit = _editByLocation[(accountId, mailboxPath, uid)];
    if (edit == null || edit.$1 <= _seq) return null;
    return edit.$2;
  }
}

const _imapFlagReconcileInterval = Duration(minutes: 15);

const _imapSizeBackfillBatch = 500;

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

      if (checkpoint == null || checkpoint['uidValidity'] != uidValidity) {
        // First run or UID validity changed — full sync.
        if (checkpoint != null) {
          // UID validity changed: remove stale local emails for this mailbox.
          await (_db.delete(_db.emails)
                ..where(
                  (t) =>
                      t.accountId.equals(account.id) &
                      t.mailboxPath.equals(mailboxPath),
                ))
              .go();
        }
        // Use UID SEARCH ALL + UID FETCH so every message gets a reliable UID.
        // Regular FETCH 1:* may not populate msg.uid on all servers.
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
        await _maybeReconcileImapFlagsMailbox(client, account.id, mailboxPath);

        // Detect remote deletions.
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

  /// Remembers, while a new-mail FETCH runs, that the mail of row
  /// [emailId] at IMAP location [at] was moved, snoozed, unsnoozed or
  /// deleted locally (see [_FetchLocationGuard]).
  void _noteLocationEdit(String emailId, _ImapLocation? at) {
    _localEditSeq++;
    // With no FETCH running, any later one starts at or above this value.
    if (_activeFetches == 0 || at == null) return;
    _localEditByLocation[at] = (_localEditSeq, emailId);
  }

  /// Call right before a new-mail FETCH, and [_endFetchGuard] when done
  /// with its answer (use try/finally).
  _FetchLocationGuard _startFetchGuard() {
    _activeFetches++;
    return _FetchLocationGuard(_localEditSeq, _localEditByLocation);
  }

  void _endFetchGuard() {
    _activeFetches--;
    // No FETCH can still need the edits; keep the map small.
    if (_activeFetches > 0) return;
    _localEditByLocation.clear();
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
        final written =
            await read.write(row.id, ServerKeywords.imap(msg.flags));
        if (written.changed) {
          affectedThreads.add((row.mailboxPath, row.threadId ?? row.id));
        }
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
  Future<void> _maybeReconcileImapFlagsMailbox(
    imap.ImapClient client,
    String accountId,
    String mailboxPath,
  ) async {
    final key = 'IMAP:FlagReconcile:$mailboxPath';
    final last = await _loadSyncState(accountId, key);
    final dueValue = await _loadSyncState(
      accountId,
      _flagReconcileDueKey(mailboxPath, jmap: false),
    );
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

    await _db.transaction(() async {
      for (final row in localRows) {
        final keywords = byUid[row.srvUid];
        if (keywords == null) continue; // handled by _reconcileDeletedImap
        // Every row is written, also an unchanged one: the stamp keeps a
        // slower, older read from overwriting it. A read/star change made
        // meanwhile folds over the server's value.
        final written = await read.write(row.id, keywords);
        if (!written.changed) continue;
        affectedThreads.add((row.mailboxPath, row.threadId ?? row.id));
        corrected++;
      }
    });

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
    if (sizeById.isEmpty) return;
    await _db.batch((b) {
      for (final MapEntry(key: id, value: size) in sizeById.entries) {
        b.update(
          _db.emails,
          EmailsCompanion(sizeBytes: Value(size)),
          where: (t) => t.id.equals(id),
        );
      }
    });
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
    // a move, or a full sync without a checkpoint): its FLAGS go through the
    // server-write gate, so a read/star change made meanwhile keeps showing.
    final guard = _startFetchGuard();
    try {
      return await _fetchAndUpsertImapGuarded(
        client,
        account,
        mailboxPath,
        sequence,
        fetchItems,
        guard,
        objectIdKind: objectIdKind,
        uidValidity: uidValidity,
      );
    } finally {
      _endFetchGuard();
    }
  }

  Future<int> _fetchAndUpsertImapGuarded(
    imap.ImapClient client,
    account_model.Account account,
    String mailboxPath,
    imap.MessageSequence sequence,
    String fetchItems,
    _FetchLocationGuard guard, {
    ObjectIdKind? objectIdKind,
    int? uidValidity,
  }) async {
    // Taken before the FETCH as well as after it: a move or delete queued
    // before the FETCH and sent by a flush while its answer was on the way
    // is no longer queued afterwards, yet the answer still lists the mail
    // here (#1269).
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
    final failedResourceIds = {for (final c in failedNow) c.resourceId};
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
    // (realEmailId, messageId) of each row we just wrote — checked afterwards
    // for a local self-sent "virtual" counterpart to dissolve (#545).
    final dissolveCandidates = <(String, String?)>[];
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
        // Don't resurrect a row the user has already removed locally via a
        // pending delete or move. The IMAP server still has the message
        // until the next flushPendingChanges, and `UID lastUid+1:*` can
        // even return a UID smaller than `lastUid+1` because RFC 3501
        // §6.4.4 reverses `n:*` to `*:n` when `n` exceeds the largest UID.
        if (pendingByUid.containsKey(uid)) {
          log(
            'IMAP: skipping insert for uid=$uid in $mailboxPath '
            '(pending ${pendingByUid[uid]!.changeType})',
          );
          continue;
        }
        bytes += msg.size ?? 0;
        // The row the server's message already has, found by where the
        // server has it, never by the shown folder: behind a queued move
        // that is already the destination (SYNC-REDESIGN.md §8 phase 2).
        // Without one, the message gets a new row with a new id.
        final known = await _rowAtImapLocation(
          account.id,
          mailboxPath,
          uid,
          uidValidity: uidValidity,
        );
        final emailId = known?.id ?? _newId(account.id);
        final serverEmailId = serverEmailIdByUid[uid];
        final msgId = normaliseMessageId(envelope.messageId);
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
        // No row, but the user changed the mail that was here since the
        // FETCH was sent: it was moved or deleted meanwhile, and maybe
        // already sent, so the answer predates that. Inserting it would
        // duplicate the mail in its old folder (#1269). If a move fails, its
        // revert brings the row back.
        final editedId =
            isNew ? guard.editedAt(account.id, mailboxPath, uid) : null;
        if (editedId != null && !failedResourceIds.contains(editedId)) {
          log(
            'IMAP: skipping insert for uid=$uid in $mailboxPath '
            '(changed locally while the FETCH ran)',
          );
          continue;
        }
        final upsert = EmailsCompanion.insert(
          id: emailId,
          accountId: account.id,
          mailboxPath: mailboxPath,
          uid: uid,
          subject: Value(subject),
          sentAt: Value(envelope.date),
          // The server's arrival time, like JMAP `receivedAt`. Never
          // the local fetch time when the server knows better: mail
          // without a Date header used to be re-dated to "now" on every
          // re-fetch, so a resync or reinstall moved it to the top.
          receivedAt: parseImapDateTime(msg.internalDate) ??
              envelope.date ??
              DateTime.now(),
          fromJson: Value(_encodeAddresses(envelope.from)),
          toAddresses: Value(_encodeAddresses(envelope.to)),
          ccJson: Value(_encodeAddresses(envelope.cc)),
          replyToJson: Value(_encodeAddresses(envelope.replyTo)),
          bccJson: Value(_encodeAddresses(envelope.bcc)),
          sizeBytes: msg.size == null ? const Value.absent() : Value(msg.size),
          preview: Value(
            previewFromSnippet(msg, previewSnippetByUid[uid]),
          ),
          // enough_mail counts parts with Content-Disposition: attachment;
          // JMAP's hasAttachment (below) is server-defined, so the two
          // protocols may disagree on e.g. inline images.
          hasAttachment: Value(msg.hasAttachments()),
          threadId: Value(threadId),
          messageId: Value(msgId),
          inReplyTo: Value(inReplyTo),
          references: Value(refs),
          listUnsubscribeHeader: Value(listUnsubscribe),
          // Preserve a previously captured id if this fetch couldn't
          // read one, rather than clobbering it with null.
          serverEmailId: serverEmailId == null
              ? const Value.absent()
              : Value(serverEmailId),
          srvMailboxPath: Value(mailboxPath),
          srvUid: Value(uid),
          srvUidValidity: Value(
            uidValidity == null || uidValidity == 0 ? null : uidValidity,
          ),
        );
        // The read/star/snooze state only through the server-write gate:
        // with the row's other server facts for a new row, else on its own
        // (a whole-row write would also overwrite the user's pending values).
        await _db.into(_db.emails).insertOnConflictUpdate(
              isNew
                  ? EmailStateWriter.withServerKeywords(
                      upsert,
                      keywords,
                      seq: read.seq,
                    )
                  : upsert,
            );
        if (!isNew) await read.write(emailId, keywords);
        if (msgId != null) dissolveCandidates.add((emailId, msgId));
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
    if (dissolveCandidates.isNotEmpty && await _hasLocalMessages(account.id)) {
      for (final (emailId, msgId) in dissolveCandidates) {
        await _maybeDissolveLocalMessage(
          account.id,
          mailboxPath,
          emailId,
          msgId,
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

  /// Whether [accountId] has any local self-sent "virtual" rows awaiting a real
  /// counterpart (#545). A one-shot guard so sync's per-message dissolve scan is
  /// skipped entirely for the common case of no pending self-sends.
  Future<bool> _hasLocalMessages(String accountId) async {
    final row = await (_db.select(_db.emails)
          ..where((t) => t.accountId.equals(accountId) & t.isLocal.equals(true))
          ..limit(1))
        .getSingleOrNull();
    return row != null;
  }

  // UIDs in [mailboxPath] that have a pending local delete, move, snooze or
  // unsnooze queued, with that change. Used by the IMAP fetch path to avoid
  // re-inserting rows the user has already removed from view but whose
  // change has not yet flushed. A failed change is not counted: the
  // server's copy is shown again. Neither is one stamped with another
  // [uidValidity] than the folder's current one: its UID names another
  // mail now.
  Future<Map<int, PendingChangeRow>> _pendingDeleteOrMoveUids(
    String accountId,
    String mailboxPath, {
    int? uidValidity,
  }) async {
    final rows = await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.state.isIn(_liveStates) &
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
  }) =>
      _reconcileDeletedImap(
        accountId,
        mailboxPath,
        serverUids,
        serverMessageCount: serverMessageCount,
      );

  Future<void> _reconcileDeletedImap(
    String accountId,
    String mailboxPath,
    List<int> serverUids, {
    int? serverMessageCount,
  }) async {
    final localRows = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.mailboxPath.equals(mailboxPath),
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
      return;
    }

    // Email IDs that still have a queued move/snooze/unsnooze waiting to be
    // flushed. The optimistic local move has already updated mailbox_path, so
    // these rows look orphaned from both the old and new mailbox until the
    // server applies the change and we remap to the destination UID. Skipping
    // them here avoids wiping the row mid-flight.
    final inFlightSet = await _rowsWithUnflushedMoveOrSnooze(accountId);

    final serverUidSet = serverUids.toSet();
    final affectedThreads = <String>{};
    for (final row in localRows) {
      // Local self-sent "virtual" rows have no server UID and must survive
      // until the real message arrives and dissolves them (#545).
      if (row.isLocal) continue;
      if (!serverUidSet.contains(row.uid)) {
        if (inFlightSet.contains(row.id)) continue;
        // A message that vanished from this folder but reappeared under a
        // different folder with the same move-stable server id (RFC 8474
        // EMAILID / Gmail X-GM-MSGID) was moved, not deleted. Its row
        // carries over to the new location with its id, body and
        // references, as after a move we made ourselves (#589); the row
        // sync stored there is merged into it. Correct for Gmail/COPY too:
        // those keep the message in the source folder, so no vanish fires.
        affectedThreads.add(row.threadId ?? row.id);
        final copy = await _movedCopyOf(row, mailboxPath, serverUidSet);
        if (copy != null) {
          final carried = await _carryOverMovedRow(
            row: row,
            copy: copy,
            vanishedFrom: mailboxPath,
          );
          if (carried.dropped case final dropped?) {
            _logMovedRowCarriedOver(row, dropped);
          }
          if (carried.kept) continue;
        }
        await (_db.delete(_db.emails)..where((t) => t.id.equals(row.id))).go();
      }
    }
    for (final tid in affectedThreads) {
      await _updateThread(accountId, mailboxPath, tid);
    }
  }
}
