import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/models/account.dart' as account_model;
import 'package:sharedinbox/core/models/email.dart' as model;
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/repositories/outbox_repository.dart';
import 'package:sharedinbox/core/sieve/sieve_interpreter.dart';
import 'package:sharedinbox/core/sieve/sieve_parser.dart';
import 'package:sharedinbox/core/sieve/sieve_rule.dart';
import 'package:sharedinbox/core/utils/cid_utils.dart';
import 'package:sharedinbox/core/utils/logger.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:sharedinbox/data/imap/imap_errors.dart';
import 'package:sharedinbox/data/jmap/jmap_client.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart'
    show removeLocalMailbox;
import 'package:sharedinbox/data/repositories/outbox_repository_impl.dart';

typedef SmtpConnectFn = Future<imap.SmtpClient> Function(
  account_model.Account account,
  String username,
  String password,
);
typedef GetCacheDirFn = Future<Directory> Function();

class EmailRepositoryImpl implements EmailRepository {
  EmailRepositoryImpl(
    AppDatabase db,
    this._accounts, {
    ImapConnectFn imapConnect = connectImap,
    SmtpConnectFn smtpConnect = connectSmtp,
    GetCacheDirFn getCacheDir = getTemporaryDirectory,
    http.Client? httpClient,
    OutboxRepository? outbox,
    Duration sendOperationTimeout = const Duration(seconds: 50),
  })  : _db = db,
        _imapConnect = imapConnect,
        _smtpConnect = smtpConnect,
        _getCacheDir = getCacheDir,
        _httpClient = httpClient ?? http.Client(),
        _outbox = outbox ?? OutboxRepositoryImpl(db),
        _sendOperationTimeout = sendOperationTimeout;

  final AppDatabase _db;
  final AccountRepository _accounts;
  final ImapConnectFn _imapConnect;
  final SmtpConnectFn _smtpConnect;
  final GetCacheDirFn _getCacheDir;
  final http.Client _httpClient;
  final OutboxRepository _outbox;

  /// Upper bound on each network call inside [_sendEmailImap]. `SmtpClient`
  /// has no built-in response timeout and `ImapClient.appendMessage` does not
  /// pick up the client's `defaultResponseTimeout` unless `responseTimeout`
  /// is passed explicitly — without these guards a stalled server wedges the
  /// caller indefinitely. This covers the SMTP connect/auth, sendMessage,
  /// the IMAP connect/login, createMailbox, and appendMessage paths so a
  /// hang anywhere along the send pipeline fails fast instead of running
  /// out the wall clock (surfaced by the nightly chaos monkey at #191/#193).
  final Duration _sendOperationTimeout;

  final _changeCtrl = StreamController<String>.broadcast();

  @override
  Stream<String> get onChangesQueued => _changeCtrl.stream;

  String _effectiveUsername(account_model.Account account) =>
      account.username.isNotEmpty ? account.username : account.email;

  // ── Observe ────────────────────────────────────────────────────────────────

  @override
  Stream<List<model.Email>> observeEmails(
    String accountId,
    String mailboxPath, {
    int limit = 50,
  }) {
    return (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.mailboxPath.equals(mailboxPath),
          )
          ..orderBy([(t) => OrderingTerm.desc(t.receivedAt)])
          ..limit(limit))
        .watch()
        .map((rows) => rows.map(_toModel).toList());
  }

  @override
  Stream<List<model.EmailThread>> observeThreads(
    String accountId,
    String mailboxPath, {
    int limit = 50,
  }) {
    return (_db.select(_db.threads)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.mailboxPath.equals(mailboxPath),
          )
          ..orderBy([(t) => OrderingTerm.desc(t.latestDate)])
          ..limit(limit))
        .watch()
        .map((rows) => rows.map(_threadRowToModel).toList());
  }

  @override
  Stream<List<model.EmailThread>> observeAllInboxThreads({int limit = 50}) {
    final query = _db.select(_db.threads).join([
      innerJoin(
        _db.mailboxes,
        _db.mailboxes.accountId.equalsExp(_db.threads.accountId) &
            _db.mailboxes.path.equalsExp(_db.threads.mailboxPath),
      ),
    ]);
    query
      ..where(_db.mailboxes.role.equals('inbox'))
      ..orderBy([OrderingTerm.desc(_db.threads.latestDate)])
      ..limit(limit);
    return query.watch().map(
          (rows) => rows
              .map((row) => _threadRowToModel(row.readTable(_db.threads)))
              .toList(),
        );
  }

  model.EmailThread _threadRowToModel(ThreadRow row) {
    List<model.EmailAddress> parseAddresses(String json) {
      final list = jsonDecode(json) as List<dynamic>;
      return list
          .map(
            (e) => model.EmailAddress(
              name: (e as Map<String, dynamic>)['name'] as String?,
              email: e['email'] as String,
            ),
          )
          .toList();
    }

    return model.EmailThread(
      threadId: row.id,
      accountId: row.accountId,
      mailboxPath: row.mailboxPath,
      subject: row.subject,
      latestDate: row.latestDate,
      messageCount: row.messageCount,
      hasUnread: row.hasUnread,
      isFlagged: row.isFlagged,
      participants: parseAddresses(row.participantsJson),
      preview: row.preview,
      latestEmailId: row.latestEmailId,
      emailIds: List<String>.from(jsonDecode(row.emailIdsJson) as List),
    );
  }

  /// Recalculates and updates the [Threads] table for [threadId].
  /// Called after any change to the [Emails] table.
  Future<void> _updateThread(
    String accountId,
    String mailboxPath,
    String threadId,
  ) async {
    final threadEmails = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.mailboxPath.equals(mailboxPath) &
                t.threadId.equals(threadId),
          )
          ..orderBy([
            (t) => OrderingTerm.asc(t.sentAt),
            (t) => OrderingTerm.asc(t.receivedAt),
          ]))
        .get();

    if (threadEmails.isEmpty) {
      await (_db.delete(_db.threads)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.mailboxPath.equals(mailboxPath) &
                  t.id.equals(threadId),
            ))
          .go();
      return;
    }

    if (threadEmails.isEmpty) return;
    final latest = threadEmails.last;

    // Collect unique participants across the whole thread.
    final seen = <String>{};
    final participants = <Map<String, dynamic>>[];
    for (final e in threadEmails) {
      final from = jsonDecode(e.fromJson) as List<dynamic>;
      for (final a in from.cast<Map<String, dynamic>>()) {
        final email = a['email'] as String;
        if (seen.add(email)) {
          participants.add({'name': a['name'], 'email': email});
        }
      }
    }

    await _db.into(_db.threads).insertOnConflictUpdate(
          ThreadsCompanion.insert(
            id: threadId,
            accountId: accountId,
            mailboxPath: mailboxPath,
            subject: Value(latest.subject),
            latestDate: latest.sentAt ?? latest.receivedAt,
            messageCount: Value(threadEmails.length),
            hasUnread: Value(threadEmails.any((e) => !e.isSeen)),
            isFlagged: Value(threadEmails.any((e) => e.isFlagged)),
            participantsJson: Value(jsonEncode(participants)),
            preview: Value(latest.preview),
            latestEmailId: latest.id,
            emailIdsJson: Value(
              jsonEncode(threadEmails.map((e) => e.id).toList()),
            ),
          ),
        );
  }

  @override
  Future<model.Email?> getEmail(String emailId) async {
    final row = await (_db.select(
      _db.emails,
    )..where((t) => t.id.equals(emailId)))
        .getSingleOrNull();
    return row == null ? null : _toModel(row);
  }

  // ── Body (on-demand) ───────────────────────────────────────────────────────

  static const _bodyCacheTtl = Duration(days: 7);

  @override
  Future<model.EmailBody> getEmailBody(
    String emailId, {
    bool forceRefresh = false,
  }) async {
    final cached = await (_db.select(
      _db.emailBodies,
    )..where((t) => t.emailId.equals(emailId)))
        .getSingleOrNull();
    if (cached != null && !forceRefresh) {
      // Re-fetch if cachedAt is null (legacy row) or older than the TTL.
      final age = cached.cachedAt == null
          ? _bodyCacheTtl + const Duration(seconds: 1)
          : DateTime.now().difference(cached.cachedAt!);
      // Also re-fetch when mimeTreeJson/headersJson are missing: such rows
      // were cached before the structure fetch existed (or before the server
      // returned bodyStructure). Without this, "Show Mail Structure" stays
      // empty for up to 7 days even after we start asking for it.
      final isMissingExtras =
          cached.mimeTreeJson == null || cached.headersJson == null;
      if (age <= _bodyCacheTtl && !isMissingExtras) {
        return _bodyRowToModel(cached);
      }
    }

    final emailRow = await (_db.select(
      _db.emails,
    )..where((t) => t.id.equals(emailId)))
        .getSingle();
    final account = (await _accounts.getAccount(emailRow.accountId))!;
    final password = await _accounts.getPassword(account.id);

    if (account.type == account_model.AccountType.jmap) {
      return _getEmailBodyJmap(emailId, account, password);
    }

    final client = await _imapConnect(
      account,
      _effectiveUsername(account),
      password,
    );
    try {
      await client.selectMailboxByPath(emailRow.mailboxPath);
      final fetch = await client.uidFetchMessage(emailRow.uid, '(BODY.PEEK[])');
      final msg = fetch.messages.firstOrNull;
      if (msg == null) {
        throw StateError(
          'IMAP server returned no message for UID ${emailRow.uid}.',
        );
      }
      final textBody = msg.decodeTextPlainPart();
      final rawHtml = msg.decodeTextHtmlPart();
      final htmlBody =
          rawHtml == null ? null : injectInlineImages(rawHtml, msg);
      final contentInfos = msg.findContentInfo();

      final attachmentsJson = jsonEncode(
        contentInfos
            .map(
              (a) => {
                'filename': a.fileName ?? '',
                'contentType': a.contentType?.mediaType.text ?? '',
                // ContentInfo.fetchId is empty for parts that aren't addressable
                // (e.g. a non-multipart message whose top-level part is itself
                // marked as an attachment). MimeMessage.getPart() throws on an
                // empty fetchId, so guard before calling it.
                'size': a.size ??
                    (a.fetchId.isNotEmpty
                        ? msg.getPart(a.fetchId)?.decodeContentBinary()?.length
                        : null) ??
                    0,
                'fetchPartId': a.fetchId,
              },
            )
            .toList(),
      );

      final headersJson = jsonEncode(
        (msg.headers ?? [])
            .map((h) => {'name': h.name, 'value': h.value})
            .toList(),
      );

      final mimeTreeJson = _buildMimeTreeJson(msg);

      await _db.into(_db.emailBodies).insertOnConflictUpdate(
            EmailBodiesCompanion.insert(
              emailId: emailId,
              textBody: Value(textBody),
              htmlBody: Value(htmlBody),
              attachmentsJson: Value(attachmentsJson),
              headersJson: Value(headersJson),
              mimeTreeJson: Value(mimeTreeJson),
              cachedAt: Value(DateTime.now()),
            ),
          );
      return model.EmailBody(
        emailId: emailId,
        textBody: textBody,
        htmlBody: htmlBody,
        attachments: _parseAttachments(attachmentsJson),
        headers: _parseHeaders(headersJson),
        mimeTree: _parseMimeTree(mimeTreeJson),
      );
    } finally {
      await client.logout();
    }
  }

  Future<model.EmailBody> _getEmailBodyJmap(
    String emailId,
    account_model.Account account,
    String password,
  ) async {
    final jmapUrl = account.jmapUrl!;
    final jmap = await JmapClient.connect(
      httpClient: _httpClient,
      jmapUrl: Uri.parse(jmapUrl),
      username: _effectiveUsername(account),
      password: password,
    );

    final jmapEmailId = emailId.contains(':')
        ? emailId.substring(emailId.indexOf(':') + 1)
        : emailId;

    final responses = await jmap.call([
      [
        'Email/get',
        {
          'accountId': jmap.accountId,
          'ids': [jmapEmailId],
          'properties': [
            'id',
            'headers',
            'textBody',
            'htmlBody',
            'bodyValues',
            'attachments',
            'bodyStructure',
          ],
          'fetchHTMLBodyValues': true,
          'fetchTextBodyValues': true,
          'bodyProperties': ['partId', 'type', 'name', 'size', 'subParts'],
        },
        '0',
      ],
    ]);

    final result = _responseArgs(responses, 0, 'Email/get');
    final emailData =
        (result['list'] as List<dynamic>).first as Map<String, dynamic>;

    final (textBody, htmlBody, attachmentsJson) = _parseJmapBody(emailData);

    final rawHeaders = emailData['headers'] as List<dynamic>? ?? [];
    final headersJson = jsonEncode(
      rawHeaders.map((h) {
        final map = h as Map<String, dynamic>;
        return {'name': map['name'] ?? '', 'value': map['value'] ?? ''};
      }).toList(),
    );

    final rawBodyStructure =
        emailData['bodyStructure'] as Map<String, dynamic>?;
    final mimeTreeJson = rawBodyStructure != null
        ? jsonEncode(_jmapBodyStructureToJson(rawBodyStructure))
        : null;

    await _db.into(_db.emailBodies).insertOnConflictUpdate(
          EmailBodiesCompanion.insert(
            emailId: emailId,
            textBody: Value(textBody),
            htmlBody: Value(htmlBody),
            attachmentsJson: Value(attachmentsJson),
            headersJson: Value(headersJson),
            mimeTreeJson: Value(mimeTreeJson),
            cachedAt: Value(DateTime.now()),
          ),
        );

    return model.EmailBody(
      emailId: emailId,
      textBody: textBody,
      htmlBody: htmlBody,
      attachments: _parseAttachments(attachmentsJson),
      headers: _parseHeaders(headersJson),
      mimeTree: _parseMimeTree(mimeTreeJson),
    );
  }

  // ── Sync ───────────────────────────────────────────────────────────────────

  @override
  Future<model.SyncEmailsResult> syncEmails(
    String accountId,
    String mailboxPath,
  ) async {
    final account = (await _accounts.getAccount(accountId))!;
    final password = await _accounts.getPassword(accountId);
    switch (account.type) {
      case account_model.AccountType.imap:
        return _syncEmailsImap(account, password, mailboxPath);
      case account_model.AccountType.jmap:
        return _syncEmailsJmap(account, password, mailboxPath);
    }
  }

  Future<model.SyncEmailsResult> _syncEmailsImap(
    account_model.Account account,
    String password,
    String mailboxPath,
  ) async {
    final client = await _imapConnect(
      account,
      _effectiveUsername(account),
      password,
    );
    try {
      // Only request CONDSTORE if the server advertises it. Servers that don't
      // support the extension may reject SELECT with (CONDSTORE) with BAD.
      final supportsCondStore = client.serverInfo.supports('CONDSTORE') ||
          client.serverInfo.supports('QRESYNC');
      final imap.Mailbox selectedMailbox;
      try {
        selectedMailbox = await client.selectMailboxByPath(
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
          await removeLocalMailbox(_db, account.id, mailboxPath);
          return model.SyncEmailsResult.zero;
        }
        rethrow;
      }
      final uidValidity = selectedMailbox.uidValidity ?? 0;
      final serverModSeq = selectedMailbox.highestModSequence;
      final resourceType = 'IMAP:$mailboxPath';
      final checkpoint = await _loadImapCheckpoint(account.id, resourceType);

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
          );
        }
        final maxUid = allUids.isEmpty ? 0 : allUids.reduce(math.max);
        await _saveImapCheckpoint(
          account.id,
          resourceType,
          uidValidity,
          maxUid,
          highestModSeq: serverModSeq,
        );
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
        final newUids = (await client.uidSearchMessages(
              searchCriteria: 'UID ${lastUid + 1}:*',
            ))
                .matchingSequence
                ?.toList() ??
            [];
        var bytes = 0;
        if (newUids.isNotEmpty) {
          bytes = await _fetchAndUpsertImap(
            client,
            account,
            mailboxPath,
            imap.MessageSequence.fromIds(newUids, isUid: true),
          );
        }

        // CONDSTORE flag update: refresh flags only when something changed.
        if (serverModSeq != null &&
            storedModSeq != null &&
            serverModSeq != storedModSeq) {
          await _refreshFlagsImap(client, account, mailboxPath, storedModSeq);
        }

        // Detect remote deletions.
        final serverUids = (await client.uidSearchMessages(
              searchCriteria: 'ALL',
            ))
                .matchingSequence
                ?.toList() ??
            [];
        await _reconcileDeletedImap(account.id, mailboxPath, serverUids);
        final maxUid =
            serverUids.isEmpty ? lastUid : serverUids.reduce(math.max);
        await _saveImapCheckpoint(
          account.id,
          resourceType,
          uidValidity,
          maxUid,
          highestModSeq: serverModSeq,
        );
        return model.SyncEmailsResult(
          fetched: newUids.length,
          skipped: serverUids.length - newUids.length,
          bytesTransferred: bytes,
        );
      }
    } finally {
      await client.logout();
    }
  }

  /// Fetches FLAGS for all messages modified since [sinceModSeq] and updates
  /// the local DB. Only messages whose modseq is > [sinceModSeq] are returned
  /// by the server (RFC 7162 §3.2).
  Future<void> _refreshFlagsImap(
    imap.ImapClient client,
    account_model.Account account,
    String mailboxPath,
    int sinceModSeq,
  ) async {
    final result = await client.uidFetchMessages(
      imap.MessageSequence.fromAll(),
      'FLAGS',
      changedSinceModSequence: sinceModSeq,
    );
    for (final msg in result.messages) {
      final uid = msg.uid;
      if (uid == null) continue;
      final emailId = '${account.id}:$mailboxPath:$uid';
      await (_db.update(_db.emails)..where((t) => t.id.equals(emailId))).write(
        EmailsCompanion(
          isSeen: Value(msg.flags?.contains(r'\Seen') ?? false),
          isFlagged: Value(msg.flags?.contains(r'\Flagged') ?? false),
        ),
      );
    }
  }

  // Returns the total bytes transferred (sum of RFC822.SIZE for each message).
  Future<int> _fetchAndUpsertImap(
    imap.ImapClient client,
    account_model.Account account,
    String mailboxPath,
    imap.MessageSequence sequence,
  ) async {
    const fetchItems =
        '(UID FLAGS ENVELOPE BODYSTRUCTURE RFC822.SIZE BODY.PEEK[HEADER.FIELDS (REFERENCES LIST-UNSUBSCRIBE)])';
    final fetch = sequence.isUidSequence
        ? await client.uidFetchMessages(sequence, fetchItems)
        : await client.fetchMessages(sequence, fetchItems);
    final pendingByUid = await _pendingDeleteOrMoveUids(
      account.id,
      mailboxPath,
    );
    var bytes = 0;
    final affectedThreads = <String>{};
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
            '(pending ${pendingByUid[uid]})',
          );
          continue;
        }
        bytes += msg.size ?? 0;
        final emailId = '${account.id}:$mailboxPath:$uid';
        final msgId = _cleanMessageId(envelope.messageId);
        final inReplyTo = _cleanMessageId(envelope.inReplyTo);
        final refs = _cleanReferences(msg.getHeaderValue('References'));
        final listUnsubscribe = msg.getHeaderValue('List-Unsubscribe')?.trim();
        final threadId = _computeThreadId(
              emailId: emailId,
              messageId: msgId,
              inReplyTo: inReplyTo,
              references: refs,
            ) ??
            emailId;
        affectedThreads.add(threadId);

        DateTime? snoozedUntil;
        for (final String flag in msg.flags ?? <String>[]) {
          if (flag.startsWith('snz:')) {
            final ts = flag.substring(4);
            // Format: YYYYMMDDTHHMMSSZ (no dashes/colons)
            if (ts.length >= 15) {
              final formatted =
                  '${ts.substring(0, 4)}-${ts.substring(4, 6)}-${ts.substring(6, 8)}T${ts.substring(9, 11)}:${ts.substring(11, 13)}:${ts.substring(13, 15)}Z';
              snoozedUntil = DateTime.tryParse(formatted);
            }
            break;
          }
        }

        await _db.into(_db.emails).insertOnConflictUpdate(
              EmailsCompanion.insert(
                id: emailId,
                accountId: account.id,
                mailboxPath: mailboxPath,
                uid: uid,
                subject: Value(envelope.subject),
                sentAt: Value(envelope.date),
                receivedAt: envelope.date ?? DateTime.now(),
                fromJson: Value(_encodeAddresses(envelope.from)),
                toAddresses: Value(_encodeAddresses(envelope.to)),
                ccJson: Value(_encodeAddresses(envelope.cc)),
                isSeen: Value(msg.flags?.contains(r'\Seen') ?? false),
                isFlagged: Value(msg.flags?.contains(r'\Flagged') ?? false),
                hasAttachment: Value(msg.hasAttachments()),
                threadId: Value(threadId),
                messageId: Value(msgId),
                inReplyTo: Value(inReplyTo),
                references: Value(refs),
                snoozedUntil: Value(snoozedUntil),
                listUnsubscribeHeader: Value(listUnsubscribe),
              ),
            );
      }
    });
    for (final tid in affectedThreads) {
      await _updateThread(account.id, mailboxPath, tid);
    }
    return bytes;
  }

  // UIDs in [mailboxPath] that have a pending local delete or move queued.
  // Used by the IMAP fetch path to avoid re-inserting rows the user has
  // already removed from view but whose change has not yet flushed.
  Future<Map<int, String>> _pendingDeleteOrMoveUids(
    String accountId,
    String mailboxPath,
  ) async {
    final rows = await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.resourceType.equals('Email') &
                (t.changeType.equals('delete') | t.changeType.equals('move')),
          ))
        .get();
    final result = <int, String>{};
    for (final r in rows) {
      try {
        final payload = jsonDecode(r.payload) as Map<String, dynamic>;
        if (payload['mailboxPath'] != mailboxPath) continue;
        final uid = payload['uid'];
        if (uid is int) result[uid] = r.changeType;
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

  Future<void> _saveImapCheckpoint(
    String accountId,
    String resourceType,
    int uidValidity,
    int lastUid, {
    int? highestModSeq,
  }) async {
    final data = <String, dynamic>{
      'uidValidity': uidValidity,
      'lastUid': lastUid,
    };
    if (highestModSeq != null) data['highestModSeq'] = highestModSeq;
    await _saveSyncState(accountId, resourceType, jsonEncode(data));
  }

  @visibleForTesting
  Future<void> reconcileDeletedImapForTest(
    String accountId,
    String mailboxPath,
    List<int> serverUids,
  ) =>
      _reconcileDeletedImap(accountId, mailboxPath, serverUids);

  Future<void> _reconcileDeletedImap(
    String accountId,
    String mailboxPath,
    List<int> serverUids,
  ) async {
    final localRows = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.mailboxPath.equals(mailboxPath),
          ))
        .get();

    // Guard: if the server returned no UIDs but we have local emails, the
    // server response is likely incomplete (network glitch, buggy IMAP server).
    // Skip reconciliation to avoid wiping the local cache unnecessarily.
    if (serverUids.isEmpty && localRows.isNotEmpty) {
      log(
        '_reconcileDeletedImap: skipping — server returned 0 UIDs for '
        '$mailboxPath but local DB has ${localRows.length} emails',
      );
      return;
    }

    // Email IDs that still have a queued move/snooze/unsnooze waiting to be
    // flushed. The optimistic local move has already updated mailbox_path, so
    // these rows look orphaned from both the old and new mailbox until the
    // server applies the change and we remap to the destination UID. Skipping
    // them here avoids wiping the row mid-flight.
    final inFlightIds = await (_db.selectOnly(_db.pendingChanges)
          ..addColumns([_db.pendingChanges.resourceId])
          ..where(
            _db.pendingChanges.accountId.equals(accountId) &
                _db.pendingChanges.changeType.isIn(
                  const ['move', 'snooze', 'unsnooze'],
                ),
          ))
        .map((row) => row.read(_db.pendingChanges.resourceId)!)
        .get();
    final inFlightSet = inFlightIds.toSet();

    final serverUidSet = serverUids.toSet();
    final affectedThreads = <String>{};
    for (final row in localRows) {
      if (!serverUidSet.contains(row.uid)) {
        if (inFlightSet.contains(row.id)) continue;
        affectedThreads.add(row.threadId ?? row.id);
        await (_db.delete(_db.emails)..where((t) => t.id.equals(row.id))).go();
      }
    }
    for (final tid in affectedThreads) {
      await _updateThread(accountId, mailboxPath, tid);
    }
  }

  // ── Sync Reliability ──────────────────────────────────────────────────────

  @override
  Future<model.ReliabilityResult> verifySyncReliability(
    String accountId,
    String mailboxPath,
  ) async {
    final account = (await _accounts.getAccount(accountId))!;
    final password = await _accounts.getPassword(accountId);

    switch (account.type) {
      case account_model.AccountType.imap:
        return _verifyReliabilityImap(account, password, mailboxPath);
      case account_model.AccountType.jmap:
        return _verifyReliabilityJmap(account, password, mailboxPath);
    }
  }

  Future<model.ReliabilityResult> _verifyReliabilityImap(
    account_model.Account account,
    String password,
    String mailboxPath,
  ) async {
    final client = await _imapConnect(
      account,
      _effectiveUsername(account),
      password,
    );
    try {
      await client.selectMailboxByPath(mailboxPath);
      final serverUids = (await client.uidSearchMessages(
            searchCriteria: 'ALL',
          ))
              .matchingSequence
              ?.toList() ??
          [];
      final serverUidSet = serverUids.toSet();

      final localRows = await (_db.select(_db.emails)
            ..where(
              (t) =>
                  t.accountId.equals(account.id) &
                  t.mailboxPath.equals(mailboxPath),
            ))
          .get();
      final localUidSet = localRows.map((r) => r.uid).toSet();

      final missingLocally = <String>[];
      for (final uid in serverUids) {
        if (!localUidSet.contains(uid)) {
          missingLocally.add(uid.toString());
        }
      }

      final missingOnServer = <String>[];
      for (final row in localRows) {
        if (!serverUidSet.contains(row.uid)) {
          missingOnServer.add(row.id);
        }
      }

      final flagMismatches = <model.FlagMismatch>[];
      // To avoid fetching thousands of flags, we only check if there aren't too many.
      if (serverUids.isNotEmpty && serverUids.length < 5000) {
        final fetch = await client.uidFetchMessages(
          imap.MessageSequence.fromAll(),
          'FLAGS',
        );
        final localMap = {for (final r in localRows) r.uid: r};
        for (final msg in fetch.messages) {
          final uid = msg.uid;
          if (uid == null) continue;
          final local = localMap[uid];
          if (local == null) continue;

          final serverSeen = msg.flags?.contains(r'\Seen') ?? false;
          final serverFlagged = msg.flags?.contains(r'\Flagged') ?? false;

          if (serverSeen != local.isSeen || serverFlagged != local.isFlagged) {
            flagMismatches.add(
              model.FlagMismatch(
                id: local.id,
                serverSeen: serverSeen,
                localSeen: local.isSeen,
                serverFlagged: serverFlagged,
                localFlagged: local.isFlagged,
              ),
            );
          }
        }
      }

      return model.ReliabilityResult(
        missingLocally: missingLocally,
        missingOnServer: missingOnServer,
        flagMismatches: flagMismatches,
      );
    } finally {
      await client.logout();
    }
  }

  Future<model.ReliabilityResult> _verifyReliabilityJmap(
    account_model.Account account,
    String password,
    String mailboxJmapId,
  ) async {
    final jmapUrl = account.jmapUrl!;
    final jmap = await JmapClient.connect(
      httpClient: _httpClient,
      jmapUrl: Uri.parse(jmapUrl),
      username: _effectiveUsername(account),
      password: password,
    );

    final allServerIds = <String>[];
    int position = 0;
    while (true) {
      final responses = await jmap.call([
        [
          'Email/query',
          {
            'accountId': jmap.accountId,
            'filter': {'inMailbox': mailboxJmapId},
            'limit': 1000,
            'position': position,
          },
          '0',
        ],
      ]);
      final queryResult = _responseArgs(responses, 0, 'Email/query');
      final ids = List<String>.from(queryResult['ids'] as List);
      allServerIds.addAll(ids);
      if (ids.length < 1000) break;
      position += ids.length;
    }
    final serverIdSet = allServerIds.toSet();

    final localRows = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(account.id) &
                t.mailboxPath.equals(mailboxJmapId),
          ))
        .get();
    final localIdSet = localRows.map((r) => r.id.split(':').last).toSet();

    final missingLocally = <String>[];
    for (final id in allServerIds) {
      if (!localIdSet.contains(id)) {
        missingLocally.add(id);
      }
    }

    final missingOnServer = <String>[];
    for (final row in localRows) {
      final jmapId = row.id.split(':').last;
      if (!serverIdSet.contains(jmapId)) {
        missingOnServer.add(row.id);
      }
    }

    final flagMismatches = <model.FlagMismatch>[];
    if (allServerIds.isNotEmpty && allServerIds.length < 5000) {
      final responses = await jmap.call([
        [
          'Email/get',
          {
            'accountId': jmap.accountId,
            'ids': allServerIds,
            'properties': ['id', 'keywords'],
          },
          '0',
        ],
      ]);
      final getResult = _responseArgs(responses, 0, 'Email/get');
      final list = getResult['list'] as List<dynamic>;
      final localMap = {for (final r in localRows) r.id.split(':').last: r};

      for (final e in list) {
        final m = e as Map<String, dynamic>;
        final id = m['id'] as String;
        final local = localMap[id];
        if (local == null) continue;

        final keywords = (m['keywords'] as Map<String, dynamic>?) ?? {};
        final serverSeen = keywords.containsKey(r'$seen');
        final serverFlagged = keywords.containsKey(r'$flagged');

        if (serverSeen != local.isSeen || serverFlagged != local.isFlagged) {
          flagMismatches.add(
            model.FlagMismatch(
              id: local.id,
              serverSeen: serverSeen,
              localSeen: local.isSeen,
              serverFlagged: serverFlagged,
              localFlagged: local.isFlagged,
            ),
          );
        }
      }
    }

    return model.ReliabilityResult(
      missingLocally: missingLocally,
      missingOnServer: missingOnServer,
      flagMismatches: flagMismatches,
    );
  }

  // ── JMAP email sync ────────────────────────────────────────────────────────

  static const _jmapPageSize = 500;

  /// Pending changes exceeding this attempt count are evicted rather than
  /// retried, preventing unbounded queue growth from permanent server errors.
  static const _maxChangeAttempts = 5;

  static const _emailProperties = [
    'id',
    'threadId',
    'mailboxIds',
    'subject',
    'sentAt',
    'receivedAt',
    'from',
    'to',
    'cc',
    'keywords',
    'hasAttachment',
    'preview',
    'messageId',
    'inReplyTo',
    'references',
    'textBody',
    'htmlBody',
    'bodyValues',
    'attachments',
    'header:List-Unsubscribe:asText',
  ];

  static const _emailGetBodyOptions = {
    'fetchHTMLBodyValues': true,
    'fetchTextBodyValues': true,
  };

  Future<model.SyncEmailsResult> _syncEmailsJmap(
    account_model.Account account,
    String password,
    String mailboxJmapId,
  ) async {
    final jmapUrl = account.jmapUrl;
    if (jmapUrl == null || jmapUrl.isEmpty) {
      throw Exception('JMAP account ${account.id} has no jmapUrl');
    }

    final jmap = await JmapClient.connect(
      httpClient: _httpClient,
      jmapUrl: Uri.parse(jmapUrl),
      username: _effectiveUsername(account),
      password: password,
    );

    final mailboxResourceType = 'JMAP:Email:$mailboxJmapId';
    var storedMailboxState =
        await _loadSyncState(account.id, mailboxResourceType);

    if (storedMailboxState == null) {
      // Fallback to global 'Email' state
      final globalState = await _loadSyncState(account.id, 'Email');
      if (globalState != null) {
        storedMailboxState = globalState;
        await _saveSyncState(account.id, mailboxResourceType, globalState);
      }
    }

    if (storedMailboxState == null) {
      return _jmapFullEmailSync(account.id, jmap, mailboxJmapId);
    } else {
      return _jmapIncrementalEmailSync(
        account.id,
        jmap,
        storedMailboxState,
        mailboxJmapId: mailboxJmapId,
      );
    }
  }

  Future<model.SyncEmailsResult> _jmapFullEmailSync(
    String accountId,
    JmapClient jmap,
    String mailboxJmapId,
  ) async {
    int position = 0;
    String? firstState;
    var fetched = 0;
    var bytes = 0;

    while (true) {
      final responses = await jmap.call([
        [
          'Email/query',
          {
            'accountId': jmap.accountId,
            'filter': {'inMailbox': mailboxJmapId},
            'sort': [
              {'property': 'receivedAt', 'isAscending': false},
            ],
            'limit': _jmapPageSize,
            'position': position,
            'calculateTotal': true,
          },
          '0',
        ],
        [
          'Email/get',
          {
            'accountId': jmap.accountId,
            '#ids': {'resultOf': '0', 'name': 'Email/query', 'path': '/ids'},
            'properties': _emailProperties,
            ..._emailGetBodyOptions,
          },
          '1',
        ],
      ]);

      final queryResult = _responseArgs(responses, 0, 'Email/query');
      final ids = queryResult['ids'] as List<dynamic>;
      final total = queryResult['total'] as int?;

      final getResult = _responseArgs(responses, 1, 'Email/get');
      firstState ??= getResult['state'] as String;
      final list = getResult['list'] as List<dynamic>;
      bytes += await _upsertJmapEmails(accountId, list);
      fetched += list.length;

      position += ids.length;
      if (ids.isEmpty || total == null || position >= total) break;
    }

    await _saveSyncState(accountId, 'JMAP:Email:$mailboxJmapId', firstState);
    return model.SyncEmailsResult(
      fetched: fetched,
      skipped: 0,
      bytesTransferred: bytes,
    );
  }

  Future<model.SyncEmailsResult> _jmapIncrementalEmailSync(
    String accountId,
    JmapClient jmap,
    String sinceState, {
    String? mailboxJmapId,
  }) async {
    final responses = await jmap.call([
      [
        'Email/changes',
        {'accountId': jmap.accountId, 'sinceState': sinceState},
        '0',
      ],
    ]);

    final changes = _responseArgs(responses, 0, 'Email/changes');
    final newState = changes['newState'] as String;
    final created = List<String>.from(changes['created'] as List? ?? []);
    final updated = List<String>.from(changes['updated'] as List? ?? []);
    final destroyed = List<String>.from(changes['destroyed'] as List? ?? []);

    var fetched = 0;
    var bytes = 0;
    final toFetch = [...created, ...updated];
    if (toFetch.isNotEmpty) {
      final getResponses = await jmap.call([
        [
          'Email/get',
          {
            'accountId': jmap.accountId,
            'ids': toFetch,
            'properties': _emailProperties,
            ..._emailGetBodyOptions,
          },
          '1',
        ],
      ]);
      final getResult = _responseArgs(getResponses, 0, 'Email/get');
      final list = getResult['list'] as List<dynamic>;
      bytes += await _upsertJmapEmails(accountId, list);
      fetched += list.length;
    }

    for (final jmapId in destroyed) {
      final dbId = '$accountId:$jmapId';
      final email = await getEmail(dbId);
      if (email != null) {
        final tid = email.threadId ?? dbId;
        final mailbox = email.mailboxPath;
        await (_db.delete(_db.emails)..where((t) => t.id.equals(dbId))).go();
        await _updateThread(accountId, mailbox, tid);
      }
    }

    await _saveSyncState(accountId, 'Email', newState);
    if (mailboxJmapId != null) {
      await _saveSyncState(accountId, 'JMAP:Email:$mailboxJmapId', newState);
    }
    return model.SyncEmailsResult(
      fetched: fetched,
      skipped: 0,
      bytesTransferred: bytes,
    );
  }

  // Returns total bytes transferred (sum of JMAP `size` fields).
  Future<int> _upsertJmapEmails(String accountId, List<dynamic> emails) async {
    var bytes = 0;
    final affectedByMailbox = <String, Set<String>>{};
    for (final e in emails) {
      final m = e as Map<String, dynamic>;
      final jmapId = m['id'] as String;
      final dbId = '$accountId:$jmapId';
      bytes += (m['size'] as int?) ?? 0;

      // Use first mailbox ID as the primary mailboxPath.
      final mailboxIds = m['mailboxIds'] as Map<String, dynamic>?;
      final mailboxPath = mailboxIds?.keys.firstOrNull ?? '';

      final keywords = m['keywords'] as Map<String, dynamic>? ?? {};
      DateTime? snoozedUntil;
      for (final String k in keywords.keys) {
        if (k.startsWith('snz:')) {
          final ts = k.substring(4);
          if (ts.length >= 15) {
            final formatted =
                '${ts.substring(0, 4)}-${ts.substring(4, 6)}-${ts.substring(6, 8)}T${ts.substring(9, 11)}:${ts.substring(11, 13)}:${ts.substring(13, 15)}Z';
            snoozedUntil = DateTime.tryParse(formatted);
          }
          break;
        }
      }

      final from = _encodeJmapAddresses(m['from'] as List<dynamic>?);
      final to = _encodeJmapAddresses(m['to'] as List<dynamic>?);
      final cc = _encodeJmapAddresses(m['cc'] as List<dynamic>?);
      final sentAt = _parseDate(m['sentAt'] as String?);
      final receivedAt =
          _parseDate(m['receivedAt'] as String?) ?? DateTime.now();

      final jmapThreadId = m['threadId'] as String? ?? dbId;
      affectedByMailbox.putIfAbsent(mailboxPath, () => {}).add(jmapThreadId);

      // JMAP messageId/inReplyTo/references are arrays; join to space-separated.
      final jmapMessageId = _joinJmapStringList(
        m['messageId'] as List<dynamic>?,
      );
      final jmapInReplyTo = _joinJmapStringList(
        m['inReplyTo'] as List<dynamic>?,
      );
      final jmapReferences = _joinJmapStringList(
        m['references'] as List<dynamic>?,
      );
      final jmapListUnsubscribe =
          (m['header:List-Unsubscribe:asText'] as String?)?.trim();

      await _db.into(_db.emails).insertOnConflictUpdate(
            EmailsCompanion.insert(
              id: dbId,
              accountId: accountId,
              mailboxPath: mailboxPath,
              uid: 0, // not used for JMAP accounts
              subject: Value(m['subject'] as String?),
              sentAt: Value(sentAt),
              receivedAt: receivedAt,
              fromJson: Value(from),
              toAddresses: Value(to),
              ccJson: Value(cc),
              preview: Value(m['preview'] as String?),
              isSeen: Value(keywords.containsKey(r'$seen')),
              isFlagged: Value(keywords.containsKey(r'$flagged')),
              hasAttachment: Value((m['hasAttachment'] as bool?) ?? false),
              threadId: Value(jmapThreadId),
              messageId: Value(jmapMessageId),
              inReplyTo: Value(jmapInReplyTo),
              references: Value(jmapReferences),
              snoozedUntil: Value(snoozedUntil),
              listUnsubscribeHeader: Value(jmapListUnsubscribe),
            ),
          );

      // Cache body if the server included bodyValues in this response.
      if (m.containsKey('bodyValues')) {
        final (textBody, htmlBody, attachmentsJson) = _parseJmapBody(m);
        await _db.into(_db.emailBodies).insertOnConflictUpdate(
              EmailBodiesCompanion.insert(
                emailId: dbId,
                textBody: Value(textBody),
                htmlBody: Value(htmlBody),
                attachmentsJson: Value(attachmentsJson),
                cachedAt: Value(DateTime.now()),
              ),
            );
      }
    }

    for (final mailboxPath in affectedByMailbox.keys) {
      for (final tid in affectedByMailbox[mailboxPath]!) {
        await _updateThread(accountId, mailboxPath, tid);
      }
    }
    return bytes;
  }

  /// Extracts text body, HTML body, and attachments JSON from a JMAP Email object
  /// that was fetched with fetchHTMLBodyValues/fetchTextBodyValues.
  (String? textBody, String? htmlBody, String attachmentsJson) _parseJmapBody(
    Map<String, dynamic> m,
  ) {
    final bodyValues = m['bodyValues'] as Map<String, dynamic>? ?? {};
    final textBodyParts = m['textBody'] as List<dynamic>? ?? [];
    final htmlBodyParts = m['htmlBody'] as List<dynamic>? ?? [];
    final jmapAttachments = m['attachments'] as List<dynamic>? ?? [];

    String? textBody;
    if (textBodyParts.isNotEmpty) {
      final partId =
          (textBodyParts.first as Map<String, dynamic>)['partId'] as String?;
      if (partId != null) {
        textBody =
            (bodyValues[partId] as Map<String, dynamic>?)?['value'] as String?;
      }
    }

    String? htmlBody;
    if (htmlBodyParts.isNotEmpty) {
      final partId =
          (htmlBodyParts.first as Map<String, dynamic>)['partId'] as String?;
      if (partId != null) {
        htmlBody =
            (bodyValues[partId] as Map<String, dynamic>?)?['value'] as String?;
      }
    }

    final attachmentsJson = jsonEncode(
      jmapAttachments.map((a) {
        final att = a as Map<String, dynamic>;
        return {
          'filename': att['name'] ?? '',
          'contentType': att['type'] ?? '',
          'size': att['size'] ?? 0,
          'fetchPartId': att['blobId'] ?? '',
        };
      }).toList(),
    );

    return (textBody, htmlBody, attachmentsJson);
  }

  // ── Pending-change helpers ────────────────────────────────────────────────

  /// Records a failure for [row]: increments attempt count and stores the
  /// error message. When attempts reach [_maxChangeAttempts] the row is
  /// deleted instead — the change is permanently abandoned.
  Future<void> _recordChangeError(PendingChangeRow row, Object error) async {
    final next = row.attempts + 1;
    if (next >= _maxChangeAttempts) {
      await (_db.delete(
        _db.pendingChanges,
      )..where((t) => t.id.equals(row.id)))
          .go();
    } else {
      await (_db.update(
        _db.pendingChanges,
      )..where((t) => t.id.equals(row.id)))
          .write(
        PendingChangesCompanion(
          attempts: Value(next),
          lastError: Value(error.toString()),
        ),
      );
    }
  }

  // ── sync_state helpers ────────────────────────────────────────────────────

  Future<String?> _loadSyncState(String accountId, String resourceType) async {
    final row = await (_db.select(_db.syncStates)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.resourceType.equals(resourceType),
          ))
        .getSingleOrNull();
    return row?.state;
  }

  Future<void> _saveSyncState(
    String accountId,
    String resourceType,
    String state,
  ) async {
    await _db.into(_db.syncStates).insertOnConflictUpdate(
          SyncStatesCompanion.insert(
            accountId: accountId,
            resourceType: resourceType,
            state: state,
            syncedAt: DateTime.now(),
          ),
        );
  }

  Future<String?> _loadLatestJmapState(String accountId) async {
    final rows = await (_db.select(_db.syncStates)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                (t.resourceType.equals('Email') |
                    t.resourceType.like('JMAP:Email:%')),
          ))
        .get();
    if (rows.isEmpty) return null;
    rows.sort((a, b) => b.syncedAt.compareTo(a.syncedAt));
    return rows.first.state;
  }

  Future<void> _updateAllJmapStates(String accountId, String newState) async {
    await (_db.update(_db.syncStates)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                (t.resourceType.equals('Email') |
                    t.resourceType.like('JMAP:Email:%')),
          ))
        .write(
      SyncStatesCompanion(
        state: Value(newState),
        syncedAt: Value(DateTime.now()),
      ),
    );
  }

  // ── JMAP push ────────────────────────────────────────────────────────────

  @override
  Stream<void> watchJmapPush(String accountId, String password) {
    final controller = StreamController<void>();
    StreamSubscription<String>? innerSub;

    controller.onCancel = () => innerSub?.cancel();

    unawaited(() async {
      try {
        final account = await _accounts.getAccount(accountId);
        if (account == null || account.type != account_model.AccountType.jmap) {
          await controller.close();
          return;
        }

        final jmapUrl = account.jmapUrl;
        if (jmapUrl == null || jmapUrl.isEmpty) {
          await controller.close();
          return;
        }

        final JmapClient jmap;
        try {
          jmap = await JmapClient.connect(
            httpClient: _httpClient,
            jmapUrl: Uri.parse(jmapUrl),
            username: _effectiveUsername(account),
            password: password,
          );
        } catch (e) {
          log('JMAP push: connect failed: $e');
          await controller.close();
          return;
        }

        final sseUrl = jmap.eventSourceUrl;
        if (sseUrl == null) {
          await controller.close();
          return;
        }

        final credentials = base64.encode(
          utf8.encode('${_effectiveUsername(account)}:$password'),
        );

        http.StreamedResponse response;
        try {
          final request = http.Request('GET', Uri.parse(sseUrl));
          request.headers['Accept'] = 'text/event-stream';
          request.headers['Authorization'] = 'Basic $credentials';
          response = await _httpClient
              .send(request)
              .timeout(const Duration(seconds: 10));
          if (response.statusCode != 200) {
            await controller.close();
            return;
          }
        } catch (e) {
          log('JMAP push: SSE request failed: $e');
          await controller.close();
          return;
        }

        var buffer = '';
        innerSub = response.stream
            .transform(utf8.decoder)
            .timeout(const Duration(minutes: 25))
            .listen(
          (chunk) {
            buffer += chunk;
            final lines = buffer.split('\n');
            buffer = lines.removeLast();
            for (final line in lines) {
              if (!line.startsWith('data:')) continue;
              final data = line.substring(5).trim();
              try {
                final decoded = jsonDecode(data) as Map<String, dynamic>;
                if (decoded['@type'] == 'StateChange') {
                  controller.add(null);
                }
              } catch (_) {
                // Malformed JSON — ignore line
              }
            }
          },
          onDone: () => controller.close(),
          onError: (_) => controller.close(),
          cancelOnError: true,
        );
      } catch (e) {
        log('JMAP push: unexpected error: $e');
        await controller.close();
      }
    }());

    return controller.stream;
  }

  // ── JMAP helpers ─────────────────────────────────────────────────────────

  Map<String, dynamic> _responseArgs(
    List<dynamic> responses,
    int index,
    String expectedMethod,
  ) {
    final triple = responses[index] as List<dynamic>;
    final method = triple[0] as String;
    if (method == 'error') {
      final err = triple[1] as Map<String, dynamic>;
      throw JmapException('$expectedMethod error: ${err['type']}');
    }
    return triple[1] as Map<String, dynamic>;
  }

  String _encodeJmapAddresses(dynamic addressList) {
    if (addressList == null) return '[]';
    final list = addressList as List<dynamic>;
    return jsonEncode(
      list
          .map(
            (a) => {
              'name': (a as Map<String, dynamic>)['name'],
              'email': a['email'],
            },
          )
          .toList(),
    );
  }

  DateTime? _parseDate(String? iso) =>
      iso == null ? null : DateTime.tryParse(iso);

  // ── Mutations ──────────────────────────────────────────────────────────────

  @override
  Future<void> setFlag(String emailId, {bool? seen, bool? flagged}) async {
    final row = await (_db.select(
      _db.emails,
    )..where((t) => t.id.equals(emailId)))
        .getSingleOrNull();
    if (row == null) return;
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
  }

  @override
  Future<void> markAllAsRead(String accountId, String mailboxPath) async {
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
  }

  @override
  Future<void> moveEmail(String emailId, String destMailboxPath) async {
    final row = await (_db.select(
      _db.emails,
    )..where((t) => t.id.equals(emailId)))
        .getSingleOrNull();
    if (row == null) return;
    final account = (await _accounts.getAccount(row.accountId))!;

    if (row.mailboxPath == destMailboxPath) {
      return;
    }

    if (account.type == account_model.AccountType.jmap) {
      await _enqueueChange(
        account.id,
        emailId,
        'move',
        jsonEncode({'src': row.mailboxPath, 'dest': destMailboxPath}),
      );
      // Optimistic: move the cached row so it disappears from the current
      // mailbox immediately and is visible in the destination mailbox.
      await (_db.update(_db.emails)..where((t) => t.id.equals(emailId))).write(
        EmailsCompanion(mailboxPath: Value(destMailboxPath)),
      );
      await _updateThread(
        row.accountId,
        row.mailboxPath,
        row.threadId ?? emailId,
      );
      await _updateThread(
        row.accountId,
        destMailboxPath,
        row.threadId ?? emailId,
      );
      return;
    }

    await _enqueueChange(
      account.id,
      emailId,
      'move',
      jsonEncode({
        'uid': row.uid,
        'mailboxPath': row.mailboxPath,
        'dest': destMailboxPath,
      }),
    );
    // Optimistic: move the cached row locally instead of hard-deleting.
    await (_db.update(_db.emails)..where((t) => t.id.equals(emailId))).write(
      EmailsCompanion(
        mailboxPath: Value(destMailboxPath),
        snoozedUntil: const Value(null),
        snoozedFromMailboxPath: const Value(null),
      ),
    );
    await _updateThread(
      row.accountId,
      row.mailboxPath,
      row.threadId ?? emailId,
    );
    await _updateThread(
      row.accountId,
      destMailboxPath,
      row.threadId ?? emailId,
    );
    // Destination UID will be updated when synced (IMAP move is a delete + copy).
  }

  @override
  Future<String?> deleteEmail(String emailId) async {
    final row = await (_db.select(
      _db.emails,
    )..where((t) => t.id.equals(emailId)))
        .getSingleOrNull();
    if (row == null) return null;
    final account = (await _accounts.getAccount(row.accountId))!;

    // Move to Trash when possible so the user can recover the message.
    final trashRow = await (_db.select(_db.mailboxes)
          ..where(
            (t) => t.accountId.equals(account.id) & t.role.equals('trash'),
          )
          ..limit(1))
        .getSingleOrNull();

    if (trashRow != null && trashRow.path != row.mailboxPath) {
      await moveEmail(emailId, trashRow.path);
      return trashRow.path;
    }

    // Already in Trash or no Trash folder — hard delete.
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

  // ── pending_changes queue ──────────────────────────────────────────────────

  Future<void> _enqueueChange(
    String accountId,
    String resourceId,
    String changeType,
    String payload,
  ) async {
    await _db.into(_db.pendingChanges).insert(
          PendingChangesCompanion.insert(
            accountId: accountId,
            resourceType: 'Email',
            resourceId: resourceId,
            changeType: changeType,
            payload: payload,
            createdAt: DateTime.now(),
          ),
        );
    _changeCtrl.add(accountId);
  }

  @override
  Future<bool> cancelPendingChange(String emailId, String changeType) async {
    // Find the latest pending change for this email/type that hasn't been
    // attempted yet.
    final query = _db.select(_db.pendingChanges)
      ..where(
        (t) =>
            t.resourceId.equals(emailId) &
            t.changeType.equals(changeType) &
            t.attempts.equals(0),
      )
      ..orderBy([(t) => OrderingTerm.desc(t.id)])
      ..limit(1);

    final row = await query.getSingleOrNull();
    if (row != null) {
      final count = await (_db.delete(
        _db.pendingChanges,
      )..where((t) => t.id.equals(row.id)))
          .go();
      return count > 0;
    }
    return false;
  }

  @override
  Future<void> snoozeEmail(String emailId, DateTime until) async {
    final row = await (_db.select(
      _db.emails,
    )..where((t) => t.id.equals(emailId)))
        .getSingle();
    final account = (await _accounts.getAccount(row.accountId))!;

    // Find or create Snoozed mailbox.
    var snoozedMailbox = await (_db.select(_db.mailboxes)
          ..where(
            (t) => t.accountId.equals(account.id) & t.role.equals('snoozed'),
          )
          ..limit(1))
        .getSingleOrNull();

    snoozedMailbox ??= await (_db.select(_db.mailboxes)
          ..where(
            (t) => t.accountId.equals(account.id) & t.name.equals('Snoozed'),
          )
          ..limit(1))
        .getSingleOrNull();

    // Default path if not found; flush logic will attempt to create it.
    final destPath = snoozedMailbox?.path ?? 'Snoozed';

    // Optimistic local update.
    await (_db.update(_db.emails)..where((t) => t.id.equals(emailId))).write(
      EmailsCompanion(
        mailboxPath: Value(destPath),
        snoozedUntil: Value(until),
        snoozedFromMailboxPath: Value(row.mailboxPath),
      ),
    );

    await _enqueueChange(
      account.id,
      emailId,
      'snooze',
      jsonEncode({
        'uid': row.uid,
        'src': row.mailboxPath,
        'dest': destPath,
        'until': until.toIso8601String(),
      }),
    );

    await _updateThread(
      row.accountId,
      row.mailboxPath,
      row.threadId ?? emailId,
    );
    await _updateThread(row.accountId, destPath, row.threadId ?? emailId);
  }

  @override
  Future<int> wakeUpEmails(String accountId) async {
    final now = DateTime.now();
    final expired = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.snoozedUntil.isSmallerOrEqualValue(now),
          ))
        .get();

    if (expired.isEmpty) return 0;

    for (final row in expired) {
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
        jsonEncode({'uid': row.uid, 'src': row.mailboxPath, 'dest': dest}),
      );

      // Optimistic local update.
      await (_db.update(_db.emails)..where((t) => t.id.equals(row.id))).write(
        EmailsCompanion(
          mailboxPath: Value(dest),
          snoozedUntil: const Value(null),
          snoozedFromMailboxPath: const Value(null),
        ),
      );

      await _updateThread(accountId, row.mailboxPath, row.threadId ?? row.id);
      await _updateThread(accountId, dest, row.threadId ?? row.id);
    }
    return expired.length;
  }

  @override
  @override
  Future<model.Email?> findEmailByMessageId(
    String accountId,
    String messageId,
  ) async {
    final row = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) & t.messageId.equals(messageId),
          )
          ..limit(1))
        .getSingleOrNull();
    return row == null ? null : _toModel(row);
  }

  @override
  Future<void> restoreEmails(List<model.Email> emails) async {
    for (final e in emails) {
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
            ),
          );
      await _updateThread(e.accountId, e.mailboxPath, e.threadId ?? e.id);
    }
  }

  /// Applies locally stored active Sieve rules to INBOX emails that have not
  /// been processed yet. See [EmailRepository.applySieveRules] for details.
  @override
  Future<int> applySieveRules(String accountId) async {
    final scriptRow = await (_db.select(_db.localSieveScripts)
          ..where(
            (t) => t.accountId.equals(accountId) & t.isActive.equals(true),
          )
          ..limit(1))
        .getSingleOrNull();
    if (scriptRow == null) return 0;

    List<SieveRule> rules;
    try {
      rules = SieveParser().parse(scriptRow.content);
    } catch (e) {
      log('Sieve parse error for account $accountId: $e');
      return 0;
    }
    if (rules.isEmpty) return 0;

    final inboxMailbox = await (_db.select(_db.mailboxes)
          ..where(
            (t) => t.accountId.equals(accountId) & t.role.equals('inbox'),
          )
          ..limit(1))
        .getSingleOrNull();
    final inboxPath = inboxMailbox?.path ?? 'INBOX';

    final alreadyApplied = await (_db.select(
      _db.localSieveApplied,
    )..where((t) => t.accountId.equals(accountId)))
        .get();
    final appliedIds = alreadyApplied.map((r) => r.messageId).toSet();

    final inboxEmails = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.mailboxPath.equals(inboxPath) &
                t.messageId.isNotNull(),
          ))
        .get();

    final account = (await _accounts.getAccount(accountId))!;
    final interpreter = SieveInterpreter();
    var matched = 0;

    for (final row in inboxEmails) {
      final msgId = row.messageId!;
      if (appliedIds.contains(msgId)) continue;

      final emailCtx = _buildSieveContext(row);

      SieveExecutionContext result;
      try {
        result = interpreter.execute(rules, emailCtx);
      } catch (e) {
        log('Sieve interpreter error for message $msgId: $e');
        await _markSieveApplied(accountId, msgId);
        continue;
      }

      await _markSieveApplied(accountId, msgId);

      if (result.isCancelled) {
        await _enqueueSieveDelete(account, row);
        matched++;
      } else if (result.targetFolders.isNotEmpty) {
        final dest = result.targetFolders.first;
        await _enqueueSieveMove(account, row, dest);
        matched++;
      } else if (result.flagsToAdd.isNotEmpty) {
        await _enqueueSieveFlagSeen(account, row);
        matched++;
      }
    }
    return matched;
  }

  SieveEmailContext _buildSieveContext(Email row) {
    String formatAddrs(String json) {
      try {
        final list = jsonDecode(json) as List<dynamic>;
        return list.map((e) {
          final m = e as Map<String, dynamic>;
          final name = m['name'] as String? ?? '';
          final email = m['email'] as String? ?? '';
          return name.isEmpty ? email : '$name <$email>';
        }).join(', ');
      } catch (_) {
        return '';
      }
    }

    return SieveEmailContext(
      headers: {
        if (row.subject != null && row.subject!.isNotEmpty)
          'subject': [row.subject!],
        'from': [formatAddrs(row.fromJson)],
        'to': [formatAddrs(row.toAddresses)],
        'cc': [formatAddrs(row.ccJson)],
        if (row.messageId != null) 'message-id': [row.messageId!],
      },
    );
  }

  Future<void> _markSieveApplied(String accountId, String messageId) async {
    await _db.into(_db.localSieveApplied).insertOnConflictUpdate(
          LocalSieveAppliedCompanion.insert(
            accountId: accountId,
            messageId: messageId,
            appliedAt: DateTime.now(),
          ),
        );
  }

  Future<void> _enqueueSieveMove(
    account_model.Account account,
    Email row,
    String folder,
  ) async {
    String destPath;
    if (account.type == account_model.AccountType.jmap) {
      final destMailbox = await (_db.select(_db.mailboxes)
            ..where(
              (t) => t.accountId.equals(account.id) & t.name.equals(folder),
            )
            ..limit(1))
          .getSingleOrNull();
      if (destMailbox == null) {
        log(
          'Sieve: JMAP mailbox "$folder" not found for account ${account.id}',
        );
        return;
      }
      destPath = destMailbox.path;
      await _enqueueChange(
        account.id,
        row.id,
        'move',
        jsonEncode({'src': row.mailboxPath, 'dest': destPath}),
      );
    } else {
      destPath = folder;
      await _enqueueChange(
        account.id,
        row.id,
        'move',
        jsonEncode({
          'uid': row.uid,
          'mailboxPath': row.mailboxPath,
          'dest': destPath,
        }),
      );
    }
    await (_db.update(_db.emails)..where((t) => t.id.equals(row.id))).write(
      EmailsCompanion(mailboxPath: Value(destPath)),
    );
    await _updateThread(account.id, row.mailboxPath, row.threadId ?? row.id);
    await _updateThread(account.id, destPath, row.threadId ?? row.id);
  }

  Future<void> _enqueueSieveDelete(
    account_model.Account account,
    Email row,
  ) async {
    if (account.type == account_model.AccountType.jmap) {
      await _enqueueChange(
        account.id,
        row.id,
        'delete',
        jsonEncode(<String, dynamic>{}),
      );
    } else {
      await _enqueueChange(
        account.id,
        row.id,
        'delete',
        jsonEncode({'uid': row.uid, 'mailboxPath': row.mailboxPath}),
      );
    }
    await (_db.delete(_db.emails)..where((t) => t.id.equals(row.id))).go();
    await _updateThread(account.id, row.mailboxPath, row.threadId ?? row.id);
  }

  Future<void> _enqueueSieveFlagSeen(
    account_model.Account account,
    Email row,
  ) async {
    if (account.type == account_model.AccountType.jmap) {
      await _enqueueChange(
        account.id,
        row.id,
        'flag_seen',
        jsonEncode({'seen': true}),
      );
    } else {
      await _enqueueChange(
        account.id,
        row.id,
        'flag_seen',
        jsonEncode({
          'uid': row.uid,
          'mailboxPath': row.mailboxPath,
          'seen': true,
        }),
      );
    }
    await (_db.update(_db.emails)..where((t) => t.id.equals(row.id))).write(
      const EmailsCompanion(isSeen: Value(true)),
    );
    await _updateThread(account.id, row.mailboxPath, row.threadId ?? row.id);
  }

  /// Drains pending changes for [accountId] via the appropriate protocol.
  /// Called at the start of each sync cycle. Returns count of applied changes.
  @override
  Future<int> flushPendingChanges(String accountId, String password) async {
    final rows = await (_db.select(_db.pendingChanges)
          ..where((t) => t.accountId.equals(accountId))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();
    if (rows.isEmpty) return 0;

    final account = (await _accounts.getAccount(accountId))!;
    switch (account.type) {
      case account_model.AccountType.imap:
        return _flushPendingChangesImap(account, password, rows);
      case account_model.AccountType.jmap:
        return _flushPendingChangesJmap(account, password, rows);
    }
  }

  Future<int> _flushPendingChangesJmap(
    account_model.Account account,
    String password,
    List<PendingChangeRow> rows,
  ) async {
    final jmapUrl = account.jmapUrl;
    if (jmapUrl == null || jmapUrl.isEmpty) return 0;

    final jmap = await JmapClient.connect(
      httpClient: _httpClient,
      jmapUrl: Uri.parse(jmapUrl),
      username: _effectiveUsername(account),
      password: password,
    );

    final ifInState = await _loadSyncState(account.id, 'Email') ??
        await _loadLatestJmapState(account.id);
    var applied = 0;

    for (final row in rows) {
      try {
        final newState = await _applyPendingChangeJmap(
          jmap,
          row,
          ifInState: ifInState,
        );
        await (_db.delete(
          _db.pendingChanges,
        )..where((t) => t.id.equals(row.id)))
            .go();
        applied++;
        // Keep our checkpoint in sync with whatever the server returned.
        if (newState != null) {
          await _saveSyncState(account.id, 'Email', newState);
          await _updateAllJmapStates(account.id, newState);
        }
      } on JmapStateMismatchException {
        // Server rejected the mutation because our state token is stale.
        // Drop the cached state so the next sync cycle does a full re-fetch,
        // after which this change will be retried with a fresh token.
        await (_db.delete(_db.syncStates)
              ..where(
                (t) =>
                    t.accountId.equals(account.id) &
                    (t.resourceType.equals('Email') |
                        t.resourceType.like('JMAP:Email:%')),
              ))
            .go();
        await _recordChangeError(
          row,
          'stateMismatch — will retry after re-sync',
        );
        // State is now stale for all remaining rows too; stop processing.
        break;
      } on JmapSetItemException catch (e) {
        // Permanent per-item rejection (e.g. notFound, forbidden) — discard
        // the change so the queue doesn't grow unboundedly.
        await (_db.delete(
          _db.pendingChanges,
        )..where((t) => t.id.equals(row.id)))
            .go();
        log('JMAP permanent error for change ${row.id}: $e');
      } catch (e) {
        await _recordChangeError(row, e);
      }
    }
    return applied;
  }

  Future<int> _flushPendingChangesImap(
    account_model.Account account,
    String password,
    List<PendingChangeRow> rows,
  ) async {
    imap.ImapClient? client;
    try {
      client = await _imapConnect(
        account,
        _effectiveUsername(account),
        password,
      );
    } catch (e) {
      // Connection-level failure — bump all rows, they'll retry next cycle.
      for (final row in rows) {
        await _recordChangeError(row, e);
      }
      return 0;
    }
    var applied = 0;
    try {
      for (final row in rows) {
        try {
          await _applyPendingChangeImap(client, row);
          await (_db.delete(
            _db.pendingChanges,
          )..where((t) => t.id.equals(row.id)))
              .go();
          applied++;
        } catch (e) {
          if (isImapMailboxNotFound(e)) {
            // Email already gone on the server — treat as success so the
            // pending change doesn't accumulate or block future changes.
            await (_db.delete(
              _db.pendingChanges,
            )..where((t) => t.id.equals(row.id)))
                .go();
            applied++;
            log('IMAP change ${row.id} skipped: message already gone ($e)');
          } else {
            await _recordChangeError(row, e);
          }
        }
      }
    } finally {
      await client.logout();
    }
    return applied;
  }

  Future<void> _applyPendingChangeImap(
    imap.ImapClient client,
    PendingChangeRow row,
  ) async {
    final payload = jsonDecode(row.payload) as Map<String, dynamic>;
    final uid = payload['uid'] as int;
    // snooze/unsnooze payloads use 'src' for the source folder; all others use 'mailboxPath'.
    final mailboxPath = (payload['mailboxPath'] ?? payload['src']) as String;
    final seq = imap.MessageSequence.fromId(uid, isUid: true);
    await client.selectMailboxByPath(mailboxPath);

    switch (row.changeType) {
      case 'flag_seen':
        final seen = payload['seen'] as bool;
        seen ? await client.uidMarkSeen(seq) : await client.uidMarkUnseen(seq);
      case 'flag_flagged':
        final flagged = payload['flagged'] as bool;
        flagged
            ? await client.uidMarkFlagged(seq)
            : await client.uidMarkUnflagged(seq);
      case 'move':
        final dest = payload['dest'] as String;
        final result = await client.uidMove(seq, targetMailboxPath: dest);
        await _remapEmailAfterImapMove(
          client,
          oldId: row.resourceId,
          sourceUid: uid,
          destMailboxPath: dest,
          moveResult: result,
        );
      case 'delete':
        await client.uidMarkDeleted(seq);
        await client.uidExpunge(seq);
      case 'snooze':
        final until = payload['until'] as String;
        // ISO8601 with colons is fine for IMAP atoms, but we use a cleaner
        // format just in case.
        final timestamp = until.replaceAll(':', '').replaceAll('-', '');
        final keyword = 'snz:$timestamp';
        final dest = payload['dest'] as String;
        try {
          await client.createMailbox(dest);
        } catch (_) {}
        await client.uidStore(seq, [keyword], action: imap.StoreAction.add);
        final snoozeResult = await client.uidMove(seq, targetMailboxPath: dest);
        await _remapEmailAfterImapMove(
          client,
          oldId: row.resourceId,
          sourceUid: uid,
          destMailboxPath: dest,
          moveResult: snoozeResult,
        );
      case 'unsnooze':
        final dest = payload['dest'] as String;
        try {
          await client.createMailbox(dest);
        } catch (_) {}
        // Remove any existing snooze flags.
        final fetch = await client.uidFetchMessages(seq, 'FLAGS');
        if (fetch.messages.isNotEmpty) {
          final flags = fetch.messages.first.flags ?? [];
          final snzFlags = flags.where((f) => f.startsWith('snz:')).toList();
          if (snzFlags.isNotEmpty) {
            await client.uidStore(
              seq,
              snzFlags,
              action: imap.StoreAction.remove,
            );
          }
        }
        final unsnoozeResult =
            await client.uidMove(seq, targetMailboxPath: dest);
        await _remapEmailAfterImapMove(
          client,
          oldId: row.resourceId,
          sourceUid: uid,
          destMailboxPath: dest,
          moveResult: unsnoozeResult,
        );
    }
  }

  /// Rewrites the local row identity after an IMAP MOVE so the cache keeps
  /// tracking the same physical message under its new (mailbox, UID).
  ///
  /// The new UID is taken from the RFC 4315 `COPYUID` response code first
  /// (every modern server advertises `UIDPLUS`). If that's missing we fall
  /// back to `UID SEARCH HEADER Message-ID …` in the destination mailbox.
  /// When neither yields a UID we leave the row in place; the next sync
  /// cycle will re-fetch it as a new message and reconciliation will drop
  /// the stale source-side row.
  Future<void> _remapEmailAfterImapMove(
    imap.ImapClient client, {
    required String oldId,
    required int sourceUid,
    required String destMailboxPath,
    required imap.GenericImapResult moveResult,
  }) async {
    final row = await (_db.select(_db.emails)..where((t) => t.id.equals(oldId)))
        .getSingleOrNull();
    if (row == null) return;

    final newUid = _resolveCopyUid(moveResult, sourceUid) ??
        await _searchUidByMessageId(
          client,
          destMailboxPath,
          row.messageId,
        );
    if (newUid == null) {
      log(
        '_remapEmailAfterImapMove: could not resolve new UID for $oldId '
        'after move to $destMailboxPath (no COPYUID, '
        'messageId=${row.messageId}); row will be re-fetched on next sync',
      );
      return;
    }

    final newId = '${row.accountId}:$destMailboxPath:$newUid';
    if (newId == oldId) return;

    await _db.transaction(() async {
      await _db.customStatement('PRAGMA defer_foreign_keys = ON');

      await _db.customStatement(
        'UPDATE email_bodies SET email_id = ?1 WHERE email_id = ?2',
        [newId, oldId],
      );

      await (_db.update(_db.emails)..where((t) => t.id.equals(oldId))).write(
        EmailsCompanion(
          id: Value(newId),
          uid: Value(newUid),
          mailboxPath: Value(destMailboxPath),
        ),
      );

      await (_db.update(_db.pendingChanges)
            ..where((t) => t.resourceId.equals(oldId)))
          .write(PendingChangesCompanion(resourceId: Value(newId)));

      // threads.latest_email_id is a plain equality match; threads.email_ids_json
      // is a JSON array of email IDs — both are safe to update via REPLACE()
      // because email IDs are unique opaque strings.
      await _db.customStatement(
        'UPDATE threads SET latest_email_id = ?1 '
        'WHERE latest_email_id = ?2',
        [newId, oldId],
      );
      await _db.customStatement(
        'UPDATE threads SET email_ids_json = '
        'REPLACE(email_ids_json, ?1, ?2) '
        'WHERE email_ids_json LIKE ?3',
        ['"$oldId"', '"$newId"', '%"$oldId"%'],
      );

      // UndoAction.toJson() embeds email IDs as quoted JSON strings in both
      // emailIds and originalEmails[].id, so the same REPLACE() works.
      await _db.customStatement(
        'UPDATE undo_actions SET data_json = '
        'REPLACE(data_json, ?1, ?2) '
        'WHERE data_json LIKE ?3',
        ['"$oldId"', '"$newId"', '%"$oldId"%'],
      );
    });

    // Rebuild thread aggregates in both mailboxes from the now-updated emails.
    final threadId = row.threadId ?? newId;
    await _updateThread(row.accountId, row.mailboxPath, threadId);
    await _updateThread(row.accountId, destMailboxPath, threadId);
  }

  /// Extracts the destination UID for [sourceUid] from a MOVE/COPY result's
  /// `COPYUID` response code (RFC 4315). Returns null when the server did not
  /// advertise UIDPLUS or the response code is malformed.
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
  Future<int?> _searchUidByMessageId(
    imap.ImapClient client,
    String mailboxPath,
    String? messageId,
  ) async {
    if (messageId == null || messageId.isEmpty) return null;
    try {
      await client.selectMailboxByPath(mailboxPath);
      // RFC 3501 SEARCH HEADER uses an astring for the value; quoting is safe
      // for typical Message-ID syntax (no embedded quotes or backslashes).
      final escaped = messageId.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
      final result = await client.uidSearchMessages(
        searchCriteria: 'HEADER Message-ID "$escaped"',
      );
      final uids = result.matchingSequence?.toList() ?? const <int>[];
      if (uids.isEmpty) return null;
      return uids.reduce((a, b) => a > b ? a : b);
    } catch (e) {
      log('_searchUidByMessageId failed for $messageId in $mailboxPath: $e');
      return null;
    }
  }

  /// Applies a single pending change to the JMAP server.
  ///
  /// Returns the `newState` from the server's `Email/set` response so the
  /// caller can keep the local checkpoint in sync.
  ///
  /// Throws [JmapStateMismatchException] when the server rejects the request
  /// because [ifInState] is stale (RFC 8620 §5.3 `stateMismatch`).
  Future<String?> _applyPendingChangeJmap(
    JmapClient jmap,
    PendingChangeRow row, {
    String? ifInState,
  }) async {
    final payload = jsonDecode(row.payload) as Map<String, dynamic>;
    // Extract the JMAP email ID from the DB id (format: "accountId:jmapId").
    final jmapEmailId = row.resourceId.contains(':')
        ? row.resourceId.substring(row.resourceId.indexOf(':') + 1)
        : row.resourceId;

    Map<String, dynamic> setArgs(Map<String, dynamic> extra) => {
          'accountId': jmap.accountId,
          if (ifInState != null) 'ifInState': ifInState,
          ...extra,
        };

    List<dynamic> responses;
    switch (row.changeType) {
      case 'flag_seen':
        final seen = payload['seen'] as bool;
        responses = await jmap.call([
          [
            'Email/set',
            setArgs({
              'update': {
                jmapEmailId: {'keywords/\$seen': seen},
              },
            }),
            '0',
          ],
        ]);

      case 'flag_flagged':
        final flagged = payload['flagged'] as bool;
        responses = await jmap.call([
          [
            'Email/set',
            setArgs({
              'update': {
                jmapEmailId: {'keywords/\$flagged': flagged},
              },
            }),
            '0',
          ],
        ]);

      case 'move':
        final destMailboxId = payload['dest'] as String;
        final srcMailboxId = payload['src'] as String;
        responses = await jmap.call([
          [
            'Email/set',
            setArgs({
              'update': {
                jmapEmailId: {
                  'mailboxIds/$destMailboxId': true,
                  'mailboxIds/$srcMailboxId': null,
                },
              },
            }),
            '0',
          ],
        ]);

      case 'delete':
        responses = await jmap.call([
          [
            'Email/set',
            setArgs({
              'destroy': [jmapEmailId],
            }),
            '0',
          ],
        ]);

      case 'snooze':
        final until = payload['until'] as String;
        final timestamp = until.replaceAll(':', '').replaceAll('-', '');
        final keyword = 'snz:$timestamp';
        var destMailboxId = payload['dest'] as String;
        final srcMailboxId = payload['src'] as String;
        // When the Snoozed folder didn't exist at enqueue time, 'dest' holds
        // the literal name 'Snoozed' rather than a JMAP mailbox ID.  Create it.
        if (destMailboxId == 'Snoozed') {
          final createResps = await jmap.call([
            [
              'Mailbox/set',
              {
                'accountId': jmap.accountId,
                'create': {
                  'new-snoozed': {'name': 'Snoozed', 'role': 'snoozed'},
                },
              },
              '0',
            ],
          ]);
          final createResult = _responseArgs(createResps, 0, 'Mailbox/set');
          final created = createResult['created'] as Map<String, dynamic>?;
          final newId = (created?['new-snoozed']
              as Map<String, dynamic>?)?['id'] as String?;
          if (newId != null) destMailboxId = newId;
        }
        responses = await jmap.call([
          [
            'Email/set',
            setArgs({
              'update': {
                jmapEmailId: {
                  'keywords/$keyword': true,
                  'mailboxIds/$destMailboxId': true,
                  'mailboxIds/$srcMailboxId': null,
                },
              },
            }),
            '0',
          ],
        ]);

      case 'unsnooze':
        final destMailboxId = payload['dest'] as String;
        final srcMailboxId = payload['src'] as String;
        // Fetch current keywords to identify which snz: keywords to remove.
        final getResponses = await jmap.call([
          [
            'Email/get',
            {
              'accountId': jmap.accountId,
              'ids': [jmapEmailId],
              'properties': ['keywords'],
            },
            '0',
          ],
        ]);
        final getResult = _responseArgs(getResponses, 0, 'Email/get');
        final email = (getResult['list'] as List).firstOrNull as Map?;
        final keywords = (email?['keywords'] as Map?) ?? {};
        final toRemove = keywords.keys.where(
          (k) => k.toString().startsWith('snz:'),
        );

        final update = {
          'mailboxIds/$destMailboxId': true,
          'mailboxIds/$srcMailboxId': null,
        };
        for (final k in toRemove) {
          update['keywords/$k'] = null;
        }

        responses = await jmap.call([
          [
            'Email/set',
            setArgs({
              'update': {jmapEmailId: update},
            }),
            '0',
          ],
        ]);

      default:
        return null;
    }

    final result = _responseArgs(responses, 0, 'Email/set');

    // stateMismatch is returned as a top-level error in the Email/set response
    // (not the per-method error handled by _responseArgs).
    if (result['type'] == 'stateMismatch') {
      throw const JmapStateMismatchException();
    }

    // Check for per-item rejection (notUpdated / notDestroyed).
    final notUpdated = result['notUpdated'] as Map<String, dynamic>?;
    if (notUpdated != null && notUpdated.containsKey(jmapEmailId)) {
      final err = notUpdated[jmapEmailId] as Map<String, dynamic>;
      throw JmapSetItemException(
        err['type'] as String? ?? 'unknown',
        err['description'] as String?,
      );
    }
    final notDestroyed = result['notDestroyed'] as Map<String, dynamic>?;
    if (notDestroyed != null && notDestroyed.containsKey(jmapEmailId)) {
      final err = notDestroyed[jmapEmailId] as Map<String, dynamic>;
      throw JmapSetItemException(
        err['type'] as String? ?? 'unknown',
        err['description'] as String?,
      );
    }

    return result['newState'] as String?;
  }

  @override
  Future<void> sendEmail(String accountId, model.EmailDraft draft) async {
    final account = (await _accounts.getAccount(accountId))!;
    final password = await _accounts.getPassword(accountId);
    switch (account.type) {
      case account_model.AccountType.imap:
        await _sendEmailImap(account, password, draft);
      case account_model.AccountType.jmap:
        await _sendEmailJmap(account, password, draft);
    }
  }

  @override
  Future<int> enqueueSend(String accountId, model.EmailDraft draft) {
    return _outbox.enqueue(accountId, draft);
  }

  @override
  Future<int> flushOutbox(String accountId, String password) async {
    final account = (await _accounts.getAccount(accountId))!;
    return _outbox.flush(accountId, (job) async {
      // Re-validate any attachment file paths before touching the network so
      // an obviously-broken queue entry is failed-out fast.
      for (final filePath in job.draft.attachmentFilePaths) {
        if (!await File(filePath).exists()) {
          throw PermanentSendException(
            'Attachment file no longer exists: $filePath',
          );
        }
      }
      try {
        switch (account.type) {
          case account_model.AccountType.imap:
            await _sendEmailImap(account, password, job.draft);
          case account_model.AccountType.jmap:
            await _sendEmailJmap(account, password, job.draft);
        }
      } on imap.SmtpException catch (e) {
        // Permanent SMTP rejections come back as 5xx response codes — those
        // will fail the same way on every retry, so fail the row out.
        if (_isPermanentSmtpError(e)) {
          throw PermanentSendException('SMTP rejected: ${e.message}');
        }
        rethrow;
      } on JmapException catch (e) {
        // EmailSubmission errors that won't recover on retry (invalid
        // recipient, forbidden identity, missing mailbox).
        if (_isPermanentJmapError(e)) {
          throw PermanentSendException('JMAP rejected: ${e.message}');
        }
        rethrow;
      }
    });
  }

  bool _isPermanentSmtpError(imap.SmtpException e) {
    final code = e.response.code ?? 0;
    return code >= 500 && code < 600;
  }

  bool _isPermanentJmapError(JmapException e) {
    final m = e.message.toLowerCase();
    return m.contains('forbidden') ||
        m.contains('invalidemail') ||
        m.contains('noidentity') ||
        m.contains('cannotsend');
  }

  Future<void> _sendEmailImap(
    account_model.Account account,
    String password,
    model.EmailDraft draft,
  ) async {
    final builder = imap.MessageBuilder()
      ..from = [imap.MailAddress(draft.from.name, draft.from.email)]
      ..to = draft.to.map((a) => imap.MailAddress(a.name, a.email)).toList()
      ..cc = draft.cc.map((a) => imap.MailAddress(a.name, a.email)).toList()
      ..subject = draft.subject
      ..text = draft.body;
    for (final filePath in draft.attachmentFilePaths) {
      final file = File(filePath);
      final mediaType = imap.MediaType.guessFromFileName(filePath);
      await builder.addFile(file, mediaType);
    }
    final mimeMessage = builder.buildMimeMessage();
    final smtpClient = await _smtpConnect(
      account,
      _effectiveUsername(account),
      password,
    ).timeout(
      _sendOperationTimeout,
      onTimeout: () => throw TimeoutException(
        'SMTP connect/auth did not complete',
        _sendOperationTimeout,
      ),
    );
    try {
      await smtpClient.sendMessage(mimeMessage).timeout(
            _sendOperationTimeout,
            onTimeout: () => throw TimeoutException(
              'SMTP sendMessage did not complete',
              _sendOperationTimeout,
            ),
          );
    } finally {
      // Quit is a one-liner over the wire — bound it tightly so a wedged
      // server doesn't keep the caller hanging after the message is sent.
      try {
        await smtpClient.quit().timeout(const Duration(seconds: 10));
      } on TimeoutException {
        // Best-effort: the message is already sent.
      }
    }
    // Save a copy to the Sent folder via IMAP APPEND.
    // Create the folder first — many servers don't pre-create it.
    final imapClient = await _imapConnect(
      account,
      _effectiveUsername(account),
      password,
    ).timeout(
      _sendOperationTimeout,
      onTimeout: () => throw TimeoutException(
        'IMAP connect/login did not complete',
        _sendOperationTimeout,
      ),
    );
    try {
      try {
        await imapClient.createMailbox('Sent').timeout(
              _sendOperationTimeout,
              onTimeout: () => throw TimeoutException(
                'IMAP createMailbox(Sent) did not complete',
                _sendOperationTimeout,
              ),
            );
      } on TimeoutException {
        rethrow;
      } catch (_) {
        // Already exists — that's fine.
      }
      await imapClient.appendMessage(
        mimeMessage,
        targetMailboxPath: 'Sent',
        flags: [r'\Seen'],
        responseTimeout: _sendOperationTimeout,
      );
    } finally {
      // Logout is best-effort — bound it so a wedged server can't strand the
      // caller after the message is already appended to Sent.
      try {
        await imapClient.logout().timeout(const Duration(seconds: 10));
      } on TimeoutException {
        // Best-effort: the message is already saved to Sent.
      }
    }
  }

  Future<void> _sendEmailJmap(
    account_model.Account account,
    String password,
    model.EmailDraft draft,
  ) async {
    final jmapUrl = account.jmapUrl;
    if (jmapUrl == null || jmapUrl.isEmpty) {
      throw Exception('JMAP account ${account.id} has no jmapUrl');
    }
    final jmap = await JmapClient.connect(
      httpClient: _httpClient,
      jmapUrl: Uri.parse(jmapUrl),
      username: _effectiveUsername(account),
      password: password,
    );

    // Upload any file attachments and collect their blobIds.
    final attachments = <Map<String, dynamic>>[];
    for (final filePath in draft.attachmentFilePaths) {
      final file = File(filePath);
      final bytes = await file.readAsBytes();
      final contentType = imap.MediaType.guessFromFileName(filePath).text;
      final blobId = await jmap.uploadBlob(bytes, contentType);
      attachments.add({
        'blobId': blobId,
        'type': contentType,
        'name': p.basename(filePath),
        'size': bytes.length,
        'disposition': 'attachment',
      });
    }

    // Look up the Sent mailbox JMAP ID from the local DB.
    final sentMailbox = await (_db.select(_db.mailboxes)
          ..where(
            (t) => t.accountId.equals(account.id) & t.role.equals('sent'),
          )
          ..limit(1))
        .getSingleOrNull();
    final sentJmapId = sentMailbox?.path;

    // Build the email body.
    const bodyPartId = '1';
    final emailCreate = {
      'from': [
        {'name': draft.from.name, 'email': draft.from.email},
      ],
      'to': draft.to.map((a) => {'name': a.name, 'email': a.email}).toList(),
      if (draft.cc.isNotEmpty)
        'cc': draft.cc.map((a) => {'name': a.name, 'email': a.email}).toList(),
      'subject': draft.subject,
      'bodyValues': {
        bodyPartId: {
          'value': draft.body,
          'isEncodingProblem': false,
          'isTruncated': false,
        },
      },
      'textBody': [
        {'partId': bodyPartId, 'type': 'text/plain'},
      ],
      if (attachments.isNotEmpty) 'attachments': attachments,
      'keywords': {r'$seen': true},
      if (sentJmapId != null) 'mailboxIds': {sentJmapId: true},
    };

    // Build the recipient envelope for EmailSubmission.
    final allRecipients = [
      ...draft.to.map((a) => {'email': a.email}),
      ...draft.cc.map((a) => {'email': a.email}),
    ];

    // Fetch identities to get the required identityId for EmailSubmission.
    final identityResponses = await jmap.call([
      [
        'Identity/get',
        {'accountId': jmap.accountId, 'ids': null},
        'i',
      ],
    ]);
    final identityResult = _responseArgs(identityResponses, 0, 'Identity/get');
    final identityList = identityResult['list'] as List<dynamic>?;
    if (identityList == null || identityList.isEmpty) {
      throw JmapException('No identities found for JMAP account');
    }
    final identity = identityList.first as Map<String, dynamic>;
    final identityId = identity['id'] as String;
    final identityEmail = identity['email'] as String?;

    // Create the email first.
    final createResponses = await jmap.call([
      [
        'Email/set',
        {
          'accountId': jmap.accountId,
          'create': {'em1': emailCreate},
        },
        '0',
      ],
    ]);

    // Check Email/set for creation errors.
    final setResult = _responseArgs(createResponses, 0, 'Email/set');
    final notCreated = setResult['notCreated'] as Map<String, dynamic>?;
    if (notCreated != null && notCreated.containsKey('em1')) {
      final err = notCreated['em1'] as Map<String, dynamic>;
      throw JmapException('Email/set create failed: ${err['type']}');
    }

    final created = setResult['created'] as Map<String, dynamic>?;
    final createdEmail = created?['em1'] as Map<String, dynamic>?;
    final emailId = createdEmail?['id'] as String?;
    if (emailId == null || emailId.isEmpty) {
      throw JmapException('Email/set create failed: missing created email id');
    }

    // Then submit the created email.
    final submissionResponses = await jmap.call(
      [
        [
          'EmailSubmission/set',
          {
            'accountId': jmap.accountId,
            'create': {
              'sub1': {
                'emailId': emailId,
                'identityId': identityId,
                'envelope': {
                  'mailFrom': {'email': draft.from.email},
                  'rcptTo': allRecipients,
                },
              },
            },
          },
          '1',
        ],
      ],
      withSubmission: true,
    );

    // Check EmailSubmission/set for submission errors.
    final subResult = _responseArgs(
      submissionResponses,
      0,
      'EmailSubmission/set',
    );
    final notSubmitted = subResult['notCreated'] as Map<String, dynamic>?;
    if (notSubmitted != null && notSubmitted.containsKey('sub1')) {
      final err = notSubmitted['sub1'] as Map<String, dynamic>;
      throw JmapException(
        'EmailSubmission/set failed: ${err['type']} '
        '${err['description'] ?? ''} '
        '${err['properties'] ?? ''} '
        '(envelope mailFrom: ${draft.from.email}, '
        'identity email: ${identityEmail ?? 'unknown'})',
      );
    }
  }

  @override
  Future<String> downloadAttachment(
    String emailId,
    model.EmailAttachment attachment,
  ) async {
    final cacheDir = await _getCacheDir();
    final dir = Directory(
      p.join(
        cacheDir.path,
        'sharedinbox',
        'attachments',
        emailId.replaceAll(':', '_'),
      ),
    );
    await dir.create(recursive: true);

    final file = File(p.join(dir.path, attachment.filename));
    if (await file.exists()) return file.path;

    if (attachment.fetchPartId.isEmpty) {
      throw StateError(
        'Cannot download ${attachment.filename}: missing part ID. '
        'Open the email again to refresh.',
      );
    }

    final emailRow = await (_db.select(
      _db.emails,
    )..where((t) => t.id.equals(emailId)))
        .getSingle();
    final account = (await _accounts.getAccount(emailRow.accountId))!;
    final password = await _accounts.getPassword(account.id);

    if (account.type == account_model.AccountType.jmap) {
      final jmap = await JmapClient.connect(
        httpClient: _httpClient,
        jmapUrl: Uri.parse(account.jmapUrl!),
        username: _effectiveUsername(account),
        password: password,
      );
      final bytes = await jmap.downloadBlob(
        attachment.fetchPartId,
        name: attachment.filename,
        type: attachment.contentType,
      );
      await file.writeAsBytes(bytes);
      return file.path;
    }

    final client = await _imapConnect(
      account,
      _effectiveUsername(account),
      password,
    );
    try {
      await client.selectMailboxByPath(emailRow.mailboxPath);
      // Fetch the full message so enough_mail has MIME headers (including
      // Content-Transfer-Encoding) and getPart() can decode the part correctly.
      // A partial BODY.PEEK[n] fetch omits those headers, causing
      // decodeContentBinary() to return raw base64 instead of decoded bytes.
      final fetch = await client.uidFetchMessage(emailRow.uid, 'BODY.PEEK[]');
      final msg = fetch.messages.firstOrNull;
      if (msg == null) {
        throw StateError(
          'IMAP server returned no message for UID ${emailRow.uid}.',
        );
      }
      final part = msg.getPart(attachment.fetchPartId) ?? msg;
      final bytes = part.decodeContentBinary();
      if (bytes == null) {
        throw StateError('Failed to decode attachment ${attachment.filename}.');
      }
      await file.writeAsBytes(bytes);
      return file.path;
    } finally {
      await client.logout();
    }
  }

  @override
  Future<String> fetchRawRfc822(String emailId) async {
    final emailRow = await (_db.select(
      _db.emails,
    )..where((t) => t.id.equals(emailId)))
        .getSingle();
    final account = (await _accounts.getAccount(emailRow.accountId))!;
    final password = await _accounts.getPassword(account.id);

    if (account.type == account_model.AccountType.jmap) {
      final jmap = await JmapClient.connect(
        httpClient: _httpClient,
        jmapUrl: Uri.parse(account.jmapUrl!),
        username: _effectiveUsername(account),
        password: password,
      );
      final jmapEmailId = emailId.contains(':')
          ? emailId.substring(emailId.indexOf(':') + 1)
          : emailId;
      final responses = await jmap.call([
        [
          'Email/get',
          {
            'accountId': jmap.accountId,
            'ids': [jmapEmailId],
            'properties': ['id', 'blobId'],
          },
          '0',
        ],
      ]);
      final result = _responseArgs(responses, 0, 'Email/get');
      final emailData =
          (result['list'] as List<dynamic>).first as Map<String, dynamic>;
      final blobId = emailData['blobId'] as String;
      final bytes = await jmap.downloadBlob(
        blobId,
        name: 'email.eml',
        type: 'message/rfc822',
      );
      return utf8.decode(bytes, allowMalformed: true);
    }

    final client = await _imapConnect(
      account,
      _effectiveUsername(account),
      password,
    );
    try {
      await client.selectMailboxByPath(emailRow.mailboxPath);
      final fetch = await client.uidFetchMessage(emailRow.uid, 'BODY.PEEK[]');
      final msg = fetch.messages.firstOrNull;
      if (msg == null) {
        throw StateError(
          'IMAP server returned no message for UID ${emailRow.uid}.',
        );
      }
      return msg.renderMessage();
    } finally {
      await client.logout();
    }
  }

  @override
  Future<List<model.Email>> searchEmailsGlobal(
    String? accountId,
    String query,
  ) async {
    final ftsQuery = _toFtsQuery(query);
    if (ftsQuery.isEmpty) return [];

    final sql = accountId != null
        ? 'SELECT e.* FROM email_fts f JOIN emails e ON e.rowid = f.rowid'
            ' WHERE email_fts MATCH ? AND e.account_id = ? ORDER BY e.received_at DESC LIMIT 50'
        : 'SELECT e.* FROM email_fts f JOIN emails e ON e.rowid = f.rowid'
            ' WHERE email_fts MATCH ? ORDER BY e.received_at DESC LIMIT 50';
    final variables = accountId != null
        ? [Variable<String>(ftsQuery), Variable<String>(accountId)]
        : [Variable<String>(ftsQuery)];

    final queryRows = await _db
        .customSelect(sql, variables: variables, readsFrom: {_db.emails}).get();
    final emailRows = await Future.wait(
      queryRows.map((r) => _db.emails.mapFromRow(r)),
    );

    final noteRows = await _searchEmailsByNotes(accountId, null, query);

    final seen = <String>{};
    final merged = <model.Email>[];
    for (final e in [...emailRows.map(_toModel), ...noteRows]) {
      if (seen.add(e.id)) merged.add(e);
    }
    merged.sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    return merged;
  }

  /// Returns emails whose associated notes match [query] via the
  /// `email_notes_fts` FTS5 index. Optionally filtered by [accountId] and
  /// [mailboxPath].
  Future<List<model.Email>> _searchEmailsByNotes(
    String? accountId,
    String? mailboxPath,
    String query,
  ) async {
    final ftsQuery = _toFtsQuery(query);
    if (ftsQuery.isEmpty) return [];

    final extraConditions = StringBuffer();
    final extraVars = <Variable<String>>[];
    if (accountId != null) {
      extraConditions.write(' AND e.account_id = ?');
      extraVars.add(Variable<String>(accountId));
    }
    if (mailboxPath != null) {
      extraConditions.write(' AND e.mailbox_path = ?');
      extraVars.add(Variable<String>(mailboxPath));
    }

    final sql = 'SELECT DISTINCT e.* FROM email_notes_fts f'
        ' JOIN email_notes n ON n.rowid = f.rowid'
        ' JOIN emails e ON e.message_id = n.message_id'
        ' AND e.account_id = n.account_id'
        ' WHERE email_notes_fts MATCH ?$extraConditions'
        ' ORDER BY e.received_at DESC LIMIT 50';

    final rows = await _db.customSelect(
      sql,
      variables: [Variable<String>(ftsQuery), ...extraVars],
      readsFrom: {_db.emails, _db.emailNotes},
    ).get();
    final emailRows =
        await Future.wait(rows.map((r) => _db.emails.mapFromRow(r)));
    return emailRows.map(_toModel).toList();
  }

  @override
  Future<List<model.Email>> searchEmailsStructured(
    String? accountId,
    FilterGroup filter,
  ) async {
    final rows = await (_db.select(_db.emails)
          ..where((t) {
            final fe = _filterGroup(filter, t);
            if (accountId == null) return fe;
            return t.accountId.equals(accountId) & fe;
          })
          ..orderBy([(t) => OrderingTerm.desc(t.receivedAt)])
          ..limit(100))
        .get();
    return rows.map(_toModel).toList();
  }

  Expression<bool> _filterGroup(FilterGroup group, $EmailsTable t) {
    if (group.isEmpty) return const Constant(true);
    final exprs = group.children.map((c) => _filterNode(c, t)).toList();
    return switch (group.operator) {
      FilterOperator.and_ => exprs.reduce((a, b) => a & b),
      FilterOperator.or_ => exprs.reduce((a, b) => a | b),
    };
  }

  Expression<bool> _filterNode(FilterNode node, $EmailsTable t) =>
      switch (node) {
        final FilterLeaf l => _filterLeaf(l, t),
        final FilterGroup g => _filterGroup(g, t),
      };

  Expression<bool> _filterLeaf(FilterLeaf leaf, $EmailsTable t) {
    final val = leaf.value.toLowerCase();
    return switch (leaf.field) {
      FilterField.from_ => _jsonLike(t.fromJson, leaf.comparison, val),
      FilterField.to => _jsonLike(t.toAddresses, leaf.comparison, val),
      FilterField.cc => _jsonLike(t.ccJson, leaf.comparison, val),
      FilterField.subject => _textLike(t.subject, leaf.comparison, val),
      // Size is not stored in the local cache; skip silently.
      FilterField.size => const Constant(true),
    };
  }

  Expression<bool> _jsonLike(
    GeneratedColumn<String> col,
    FilterComparison comp,
    String val,
  ) =>
      switch (comp) {
        FilterComparison.contains => col.like('%$val%'),
        FilterComparison.is_ => col.like('%"email":"$val"%'),
        FilterComparison.matches => col.like(_globToLike(val)),
        _ => const Constant(true),
      };

  Expression<bool> _textLike(
    GeneratedColumn<String> col,
    FilterComparison comp,
    String val,
  ) =>
      switch (comp) {
        FilterComparison.contains => col.like('%$val%'),
        FilterComparison.is_ => col.like(val),
        FilterComparison.matches => col.like(_globToLike(val)),
        _ => const Constant(true),
      };

  static String _globToLike(String glob) {
    final buf = StringBuffer();
    for (var i = 0; i < glob.length; i++) {
      final ch = glob[i];
      if (ch == '%' || ch == '_') {
        buf.write('\\$ch');
      } else if (ch == '*') {
        buf.write('%');
      } else if (ch == '?') {
        buf.write('_');
      } else {
        buf.write(ch);
      }
    }
    return buf.toString();
  }

  /// Converts a user query string into an FTS5 match expression.
  /// Each whitespace-separated word becomes a prefix term (word*) so that
  /// partial words still match. Special FTS5 characters are stripped.
  static String _toFtsQuery(String query) {
    final words = query
        .trim()
        .split(RegExp(r'[^\w]+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return '';
    return words.map((w) => '$w*').join(' ');
  }

  @override
  Future<List<model.Email>> getEmailsByAddress(
    String? accountId,
    String address,
  ) async {
    final pattern = '%${address.toLowerCase()}%';
    final rows = await (_db.select(_db.emails)
          ..where((t) {
            Expression<bool> condition = const Constant(true);
            if (accountId != null) {
              condition = t.accountId.equals(accountId);
            }
            condition = condition &
                (t.fromJson.like(pattern) |
                    t.toAddresses.like(pattern) |
                    t.ccJson.like(pattern));
            return condition;
          })
          ..orderBy([(t) => OrderingTerm.desc(t.receivedAt)]))
        .get();
    return rows.map(_toModel).toList();
  }

  @override
  Future<List<model.EmailAddress>> searchAddresses(
    String? accountId,
    String query, {
    int limit = 10,
  }) async {
    if (query.length < 2) return [];
    final pattern = '%${query.toLowerCase()}%';

    // Addresses we deliberately wrote to (sent folder) should appear before
    // addresses that happened to email us (inbox/other folders).
    final sentMailboxes = await (_db.select(_db.mailboxes)
          ..where((t) {
            Expression<bool> cond = t.role.equals('sent');
            if (accountId != null) {
              cond = t.accountId.equals(accountId) & cond;
            }
            return cond;
          }))
        .get();
    final sentPaths = {for (final m in sentMailboxes) m.path};

    final rows = await (_db.select(_db.emails)
          ..where((t) {
            Expression<bool> cond = const Constant(true);
            if (accountId != null) cond = t.accountId.equals(accountId);
            cond = cond &
                (t.fromJson.like(pattern) |
                    t.toAddresses.like(pattern) |
                    t.ccJson.like(pattern));
            return cond;
          })
          ..orderBy([(t) => OrderingTerm.desc(t.receivedAt)])
          ..limit(100))
        .get();

    // Two passes: sent-folder rows first (prioritise recipients we chose),
    // then other rows (senders who contacted us).
    final sortedRows = [
      ...rows.where((r) => sentPaths.contains(r.mailboxPath)),
      ...rows.where((r) => !sentPaths.contains(r.mailboxPath)),
    ];

    final seen = <String>{};
    final results = <model.EmailAddress>[];
    final lowerQuery = query.toLowerCase();
    for (final row in sortedRows) {
      final isSent = sentPaths.contains(row.mailboxPath);
      final fields = isSent
          ? [row.toAddresses, row.ccJson, row.fromJson]
          : [row.fromJson, row.toAddresses, row.ccJson];
      for (final jsonStr in fields) {
        final list = jsonDecode(jsonStr) as List<dynamic>;
        for (final e in list) {
          final map = e as Map<String, dynamic>;
          final addr = model.EmailAddress(
            name: map['name'] as String?,
            email: map['email'] as String,
          );
          if ((addr.email.toLowerCase().contains(lowerQuery) ||
                  (addr.name?.toLowerCase().contains(lowerQuery) ?? false)) &&
              seen.add(addr.email.toLowerCase())) {
            results.add(addr);
            if (results.length >= limit) return results;
          }
        }
      }
    }
    return results;
  }

  @override
  // Results are limited to emails already synced into the local SQLite FTS5
  // index; call syncEmails first to ensure the index is up-to-date.
  Future<List<model.Email>> searchEmails(
    String accountId,
    String mailboxPath,
    String query,
  ) async {
    final ftsQuery = _toFtsQuery(query);
    if (ftsQuery.isEmpty) return [];

    const sql = 'SELECT e.* FROM email_fts f JOIN emails e ON e.rowid = f.rowid'
        ' WHERE email_fts MATCH ? AND e.account_id = ? AND e.mailbox_path = ?'
        ' ORDER BY e.received_at DESC LIMIT 50';
    final variables = [
      Variable<String>(ftsQuery),
      Variable<String>(accountId),
      Variable<String>(mailboxPath),
    ];

    final queryRows = await _db
        .customSelect(sql, variables: variables, readsFrom: {_db.emails}).get();
    final emailRows = await Future.wait(
      queryRows.map((r) => _db.emails.mapFromRow(r)),
    );

    final noteRows = await _searchEmailsByNotes(accountId, mailboxPath, query);

    final seen = <String>{};
    final merged = <model.Email>[];
    for (final e in [...emailRows.map(_toModel), ...noteRows]) {
      if (seen.add(e.id)) merged.add(e);
    }
    merged.sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    return merged;
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Computes a stable threadId from RFC 2822 headers.
  /// Uses the first entry in References (= oldest ancestor) so all messages
  /// in a thread share the same root Message-ID as their threadId.
  /// Falls back to In-Reply-To, then own Message-ID, then internal emailId.
  /// JMAP header fields like messageId/inReplyTo/references come as arrays.
  /// We join them space-separated to match the IMAP convention.
  static String? _joinJmapStringList(List<dynamic>? list) {
    if (list == null || list.isEmpty) return null;
    final joined = list.cast<String>().join(' ');
    return joined.isEmpty ? null : joined;
  }

  static String? _cleanMessageId(String? mid) {
    if (mid == null) return null;
    var s = mid.trim();
    if (s.startsWith('<') && s.endsWith('>')) {
      s = s.substring(1, s.length - 1);
    }
    return s.isEmpty ? null : s;
  }

  static String? _cleanReferences(String? refs) {
    if (refs == null) return null;
    final cleanTokens = refs
        .split(RegExp(r'\s+'))
        .map((t) => _cleanMessageId(t))
        .whereType<String>();
    return cleanTokens.isEmpty ? null : cleanTokens.join(' ');
  }

  static String? _computeThreadId({
    required String emailId,
    required String? messageId,
    required String? inReplyTo,
    required String? references,
  }) {
    if (references != null && references.isNotEmpty) {
      final first = references.trim().split(RegExp(r'\s+')).firstOrNull;
      if (first != null && first.isNotEmpty) return first;
    }
    if (inReplyTo != null && inReplyTo.isNotEmpty) return inReplyTo;
    return messageId; // null for messages with no Message-ID (rare)
  }

  String _encodeAddresses(List<imap.MailAddress>? addresses) => jsonEncode(
        (addresses ?? const [])
            .map((a) => {'name': a.personalName, 'email': a.email})
            .toList(),
      );

  @override
  Stream<List<model.Email>> observeEmailsInThread(
    String accountId,
    String mailboxPath,
    String threadId,
  ) {
    return (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.mailboxPath.equals(mailboxPath) &
                t.threadId.equals(threadId),
          )
          ..orderBy([
            (t) => OrderingTerm.asc(t.sentAt),
            (t) => OrderingTerm.asc(t.receivedAt),
          ]))
        .watch()
        .map((rows) => rows.map(_toModel).toList());
  }

  model.Email _toModel(Email row) {
    List<model.EmailAddress> parseAddresses(String json) {
      final list = jsonDecode(json) as List<dynamic>;
      return list
          .map(
            (e) => model.EmailAddress(
              name: (e as Map<String, dynamic>)['name'] as String?,
              email: e['email'] as String,
            ),
          )
          .toList();
    }

    return model.Email(
      id: row.id,
      accountId: row.accountId,
      mailboxPath: row.mailboxPath,
      uid: row.uid,
      subject: row.subject,
      sentAt: row.sentAt,
      receivedAt: row.receivedAt,
      from: parseAddresses(row.fromJson),
      to: parseAddresses(row.toAddresses),
      cc: parseAddresses(row.ccJson),
      preview: row.preview,
      isSeen: row.isSeen,
      isFlagged: row.isFlagged,
      hasAttachment: row.hasAttachment,
      threadId: row.threadId,
      messageId: row.messageId,
      inReplyTo: row.inReplyTo,
      references: row.references,
      snoozedUntil: row.snoozedUntil,
      snoozedFromMailboxPath: row.snoozedFromMailboxPath,
      listUnsubscribeHeader: row.listUnsubscribeHeader,
    );
  }

  model.EmailBody _bodyRowToModel(EmailBody row) => model.EmailBody(
        emailId: row.emailId,
        textBody: row.textBody,
        htmlBody: row.htmlBody,
        attachments: _parseAttachments(row.attachmentsJson),
        headers: _parseHeaders(row.headersJson),
        mimeTree: _parseMimeTree(row.mimeTreeJson),
      );

  model.MimePart? _parseMimeTree(String? jsonStr) {
    if (jsonStr == null || jsonStr.isEmpty) return null;
    try {
      return _mimePartFromJson(jsonDecode(jsonStr) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  model.MimePart _mimePartFromJson(Map<String, dynamic> m) => model.MimePart(
        contentType: m['contentType'] as String? ?? 'application/octet-stream',
        filename: m['filename'] as String?,
        size: m['size'] as int?,
        encoding: m['encoding'] as String?,
        children: ((m['children'] as List<dynamic>?) ?? [])
            .cast<Map<String, dynamic>>()
            .map(_mimePartFromJson)
            .toList(),
      );

  List<model.EmailHeader> _parseHeaders(String? jsonStr) {
    if (jsonStr == null || jsonStr.isEmpty) return [];
    try {
      final list = jsonDecode(jsonStr) as List;
      return list
          .cast<Map<String, dynamic>>()
          .map((m) => model.EmailHeader.fromJson(m))
          .toList();
    } catch (e) {
      return [];
    }
  }

  List<model.EmailAttachment> _parseAttachments(String json) {
    final list = jsonDecode(json) as List<dynamic>;
    return list
        .map(
          (e) => model.EmailAttachment(
            filename: (e as Map<String, dynamic>)['filename'] as String,
            contentType: e['contentType'] as String,
            size: e['size'] as int,
            fetchPartId: (e['fetchPartId'] as String?) ?? '',
          ),
        )
        .toList();
  }

  // ── Failed mutations (offline compose queue) ─────────────────────────────

  @override
  Stream<List<model.FailedMutation>> observeFailedMutations(String accountId) {
    return (_db.select(_db.pendingChanges)
          ..where(
            (t) => t.accountId.equals(accountId) & t.lastError.isNotNull(),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
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
                ),
              )
              .toList(),
        );
  }

  @override
  Future<void> discardMutation(int id) async {
    await (_db.delete(_db.pendingChanges)..where((t) => t.id.equals(id))).go();
  }

  @override
  Future<void> retryMutation(int id) async {
    await (_db.update(_db.pendingChanges)..where((t) => t.id.equals(id))).write(
      const PendingChangesCompanion(attempts: Value(0), lastError: Value(null)),
    );
  }

  @override
  Future<void> clearForResync(String accountId) async {
    // Disable FK constraints so EmailBodies rows survive the emails deletion.
    // When emails are re-inserted after the next sync with the same IDs, the
    // cached body content will be reused without a network round-trip.
    await _db.customStatement('PRAGMA foreign_keys = OFF');
    try {
      await _db.transaction(() async {
        await (_db.delete(
          _db.emails,
        )..where((t) => t.accountId.equals(accountId)))
            .go();
        await (_db.delete(
          _db.pendingChanges,
        )..where((t) => t.accountId.equals(accountId)))
            .go();
        await (_db.delete(
          _db.syncStates,
        )..where((t) => t.accountId.equals(accountId)))
            .go();
      });
    } finally {
      await _db.customStatement('PRAGMA foreign_keys = ON');
    }
  }
}

/// Recursively converts an [imap.MimePart] into a JSON-serialisable map.
Map<String, dynamic> _mimePartToJson(imap.MimePart part) {
  final ct = part.getHeaderContentType();
  final disposition = part.getHeaderContentDisposition();
  final rawEncoding =
      part.getHeader('content-transfer-encoding')?.firstOrNull?.value;
  final encoding = rawEncoding?.split(';').first.trim().toLowerCase();
  return {
    'contentType': ct?.mediaType.text ?? 'application/octet-stream',
    'filename': disposition?.filename ?? ct?.parameters['name'],
    'size': disposition?.size,
    'encoding': encoding,
    'children': (part.parts ?? []).map(_mimePartToJson).toList(),
  };
}

/// Builds a JSON string representing the MIME tree of [msg].
String _buildMimeTreeJson(imap.MimeMessage msg) =>
    jsonEncode(_mimePartToJson(msg));

/// Converts a JMAP `bodyStructure` object into the same JSON format used by
/// [_mimePartToJson], so [_parseMimeTree] can deserialise it uniformly.
Map<String, dynamic> _jmapBodyStructureToJson(Map<String, dynamic> m) => {
      'contentType': m['type'] as String? ?? 'application/octet-stream',
      'filename': m['name'],
      'size': m['size'],
      'encoding': null,
      'children': ((m['subParts'] as List<dynamic>?) ?? [])
          .cast<Map<String, dynamic>>()
          .map(_jmapBodyStructureToJson)
          .toList(),
    };
