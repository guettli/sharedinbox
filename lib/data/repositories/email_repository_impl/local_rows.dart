part of '../email_repository_impl.dart';

// Local row creation: the Sent copy stored after a send and the virtual
// self-sent rows that have no server answer yet.

/// The read/star/snooze state of mail the user just sent: read, not
/// starred, not snoozed.
const _ownMailKeywords =
    ServerKeywords(seen: true, flagged: false, snoozedUntil: null);

extension _LocalRows on EmailRepositoryImpl {
  /// Mirrors a message we just sent into the local `emails` table so it shows
  /// up in Sent immediately, instead of only once the background sync next
  /// visits that folder (#918).
  ///
  /// With a [uid] (IMAP UIDPLUS `APPENDUID`) or a [jmapId] the row records
  /// that server location, so a sync of [mailboxPath] finds and updates this
  /// row rather than inserting a duplicate. With neither, the row is
  /// inserted as a virtual `isLocal` one (`isVirtualSentCopy`) that
  /// [_Counterparts._maybeDissolveLocalMessage] folds into the real message later — the
  /// same machinery self-send notes use (#545) — which needs a [messageId]
  /// to match on, so a message without one is skipped rather than left as a
  /// permanent duplicate. A mail sent to yourself gets both rows, the inbox
  /// note and the Sent copy: they must not dissolve against each other's
  /// arrival.
  Future<void> _storeSentCopyLocally({
    required String accountId,
    required String mailboxPath,
    required model.EmailDraft draft,
    required String? messageId,
    int? uid,
    String? jmapId,
  }) async {
    final mid = normaliseMessageId(messageId);
    // With the server's location the copy is a real server row: the next
    // sync of this folder finds it by that location and updates it instead
    // of adding a second one.
    final isLocal = uid == null && jmapId == null;
    if (isLocal && mid == null) return;
    final uidValidity =
        uid == null ? null : await _knownUidValidity(accountId, mailboxPath);
    // One transaction: a sync storing the mail, or another send of it,
    // must not insert a row between the lookup and the write.
    await _db.transaction(() async {
      // A row a sync already stored there, or the virtual copy of an earlier
      // send of this message, is reused.
      final known = uid != null
          ? await _rowAtImapLocation(
              accountId,
              mailboxPath,
              uid,
              uidValidity: uidValidity,
            )
          : (jmapId != null
              ? await _rowByJmapId(accountId, jmapId)
              : await _localRowFor(accountId, mid!, sentCopy: true));
      final emailId = known?.id ?? _newId(accountId);

      final now = DateTime.now();
      final threadId =
          _computeThreadId(messageId: mid, inReplyTo: null, references: null) ??
              emailId;
      final body = draft.body;
      final preview = body.length > 200 ? body.substring(0, 200) : body;

      final copy = EmailsCompanion(
        uid: Value(uid ?? 0),
        subject: Value(draft.subject),
        sentAt: Value(now),
        receivedAt: Value(now),
        fromJson: Value(_encodeModelAddresses([draft.from])),
        toAddresses: Value(_encodeModelAddresses(draft.to)),
        ccJson: Value(_encodeModelAddresses(draft.cc)),
        bccJson: Value(_encodeModelAddresses(draft.bcc)),
        preview: Value(preview),
        hasAttachment: Value(draft.attachmentFilePaths.isNotEmpty),
        threadId: Value(threadId),
        messageId: Value(mid),
        isLocal: Value(isLocal),
        isVirtualSentCopy: Value(isLocal),
        srvUid: Value(uid),
        srvUidValidity: Value(uidValidity),
        srvJmapId: Value(uid == null ? jmapId : null),
      );
      // You wrote it — mirrors the \Seen flag the APPEND sets, and never
      // nags with an unread badge on your own mail. A row sync already
      // stored keeps the state (and folder) the server-write gate gave it.
      // A virtual copy (no server location yet) has the Sent folder as its
      // own folder.
      if (known == null) {
        await _db.into(_db.emails).insert(
              EmailStateWriter.newRow(
                copy,
                id: emailId,
                accountId: accountId,
                mailboxPath: mailboxPath,
                keywords: _ownMailKeywords,
                seq: 0,
              ),
            );
      } else {
        await (_db.update(_db.emails)..where((t) => t.id.equals(emailId)))
            .write(copy);
      }
      await _db.into(_db.emailBodies).insertOnConflictUpdate(
            EmailBodiesCompanion.insert(
              emailId: emailId,
              textBody: Value(body),
              cachedAt: Value(now),
              bodySize: Value(_bodySize(body, null)),
            ),
          );
      await _updateThread(accountId, mailboxPath, threadId);
    });
  }

  /// For every configured account whose address is among [draft]'s recipients,
  /// insert a local "virtual" copy of the message into that account's inbox so
  /// it shows up right after sending for note-taking (#545), instead of only
  /// once the next sync of the inbox fetches it. Dissolved into the real
  /// message by [_Counterparts._maybeDissolveLocalMessage] once it arrives via sync.
  ///
  /// Only call this after the server accepted the message: a note for a mail
  /// that was rejected or discarded would be a phantom inbox message.
  Future<void> _createLocalSelfMessages(model.EmailDraft draft) async {
    final mid = normaliseMessageId(draft.messageId);
    if (mid == null) return;
    final recipients = <String>{
      for (final a in draft.to) a.email.toLowerCase().trim(),
      for (final a in draft.cc) a.email.toLowerCase().trim(),
      for (final a in draft.bcc) a.email.toLowerCase().trim(),
    };
    if (recipients.isEmpty) return;

    final accounts = await _accounts.observeAccounts().first;
    for (final account in accounts) {
      if (account.email.isEmpty) continue;
      if (!recipients.contains(account.email.toLowerCase().trim())) continue;

      // The inbox is where a mail-to-self lands; the local copy mirrors it.
      final inbox = await (_db.select(_db.mailboxes)
            ..where(
              (t) => t.accountId.equals(account.id) & t.role.equals('inbox'),
            )
            ..limit(1))
          .getSingleOrNull();
      if (inbox == null) continue;

      final now = DateTime.now();
      final emailId = _newId(account.id);
      final threadId =
          _computeThreadId(messageId: mid, inReplyTo: null, references: null) ??
              emailId;
      final body = draft.body;
      final preview = body.length > 200 ? body.substring(0, 200) : body;

      // One transaction: the arrival check and the insert must not interleave
      // with a sync storing the real message, and a note must never be left
      // half-written (row without body or thread aggregate).
      await _db.transaction(() async {
        // A fast server can deliver the real message, and a sync can store
        // it, before we get here. Its arrival found no note to dissolve, so a
        // note inserted now would stay behind as a permanent duplicate.
        if (await _hasArrivedOutsideSent(account.id, mid)) return;

        // A second successful send of the same draft (or a replay) must not
        // reset the star / read state / folder the user has already set on
        // the note, nor add a second one.
        if (await _localRowFor(account.id, mid, sentCopy: false) != null) {
          return;
        }
        await _db.into(_db.emails).insert(
              EmailStateWriter.newRow(
                EmailsCompanion(
                  uid: const Value(0),
                  subject: Value(draft.subject),
                  sentAt: Value(now),
                  receivedAt: Value(now),
                  fromJson: Value(_encodeModelAddresses([draft.from])),
                  toAddresses: Value(_encodeModelAddresses(draft.to)),
                  ccJson: Value(_encodeModelAddresses(draft.cc)),
                  preview: Value(preview),
                  hasAttachment: Value(draft.attachmentFilePaths.isNotEmpty),
                  threadId: Value(threadId),
                  messageId: Value(mid),
                  isLocal: const Value(true),
                ),
                id: emailId,
                accountId: account.id,
                // A virtual row has no server copy: its folder and its
                // read/star/snooze values are its own.
                mailboxPath: inbox.path,
                // Self-sent: you wrote it, so don't nag with an unread badge.
                keywords: _ownMailKeywords,
                seq: 0,
              ),
            );
        await _db.into(_db.emailBodies).insert(
              EmailBodiesCompanion.insert(
                emailId: emailId,
                textBody: Value(body),
                cachedAt: Value(now),
                bodySize: Value(_bodySize(body, null)),
              ),
              mode: InsertMode.insertOrIgnore,
            );
        await _updateThread(account.id, inbox.path, threadId);
      });
    }
  }

  /// Whether the real (synced, non-local) message with Message-ID [mid] is
  /// already stored on [accountId] in any folder but Sent. Mirrors which
  /// arrivals [_Counterparts._maybeDissolveLocalMessage] dissolves an inbox note against: a
  /// Sent-folder row is the copy of what we sent, not the delivered message,
  /// and a server rule may have filed the delivery somewhere other than INBOX.
  ///
  /// Only folders the mailbox list knows count: a sync only ever stores
  /// messages of such a folder, whereas the Sent copy we just appended may sit
  /// in a folder not synced yet (e.g. a freshly created "Sent"), whose missing
  /// role must not pass it off as the delivered message.
  Future<bool> _hasArrivedOutsideSent(String accountId, String mid) async {
    final rows = await (_db.selectOnly(_db.emails)
          ..addColumns([_db.emails.mailboxPath])
          ..where(
            _db.emails.accountId.equals(accountId) &
                _db.emails.isLocal.equals(false) &
                _db.emails.mailboxPath.equals('').not() &
                (_db.emails.messageId.equals(mid) |
                    _db.emails.messageId.equals('<$mid>')),
          ))
        .get();
    for (final row in rows) {
      final mailbox = await (_db.select(_db.mailboxes)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.path.equals(row.read(_db.emails.mailboxPath)!),
            )
            ..limit(1))
          .getSingleOrNull();
      if (mailbox != null && mailbox.role != 'sent') return true;
    }
    return false;
  }

  String _encodeModelAddresses(List<model.EmailAddress> addresses) =>
      jsonEncode(
        addresses.map((a) => {'name': a.name, 'email': a.email}).toList(),
      );
}
