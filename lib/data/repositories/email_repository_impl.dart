import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:sharedinbox/core/models/account.dart' as account_model;
import 'package:sharedinbox/core/models/email.dart' as model;
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/utils/logger.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:sharedinbox/data/jmap/jmap_client.dart';

typedef SmtpConnectFn = Future<imap.SmtpClient> Function(
  account_model.Account account,
  String username,
  String password,
);
typedef GetCacheDirFn = Future<Directory> Function();

class EmailRepositoryImpl implements EmailRepository {
  EmailRepositoryImpl(
    this._db,
    this._accounts, {
    ImapConnectFn imapConnect = connectImap,
    SmtpConnectFn smtpConnect = connectSmtp,
    GetCacheDirFn getCacheDir = getTemporaryDirectory,
    http.Client? httpClient,
  })  : _imapConnect = imapConnect,
        _smtpConnect = smtpConnect,
        _getCacheDir = getCacheDir,
        _httpClient = httpClient ?? http.Client();

  final AppDatabase _db;
  final AccountRepository _accounts;
  final ImapConnectFn _imapConnect;
  final SmtpConnectFn _smtpConnect;
  final GetCacheDirFn _getCacheDir;
  final http.Client _httpClient;

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
  Future<model.EmailBody> getEmailBody(String emailId) async {
    final cached = await (_db.select(
      _db.emailBodies,
    )..where((t) => t.emailId.equals(emailId)))
        .getSingleOrNull();
    if (cached != null) {
      // Re-fetch if cachedAt is null (legacy row) or older than the TTL.
      final age = cached.cachedAt == null
          ? _bodyCacheTtl + const Duration(seconds: 1)
          : DateTime.now().difference(cached.cachedAt!);
      if (age <= _bodyCacheTtl) return _bodyRowToModel(cached);
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
      final msg = fetch.messages.first;
      final textBody = msg.decodeTextPlainPart();
      final htmlBody = msg.decodeTextHtmlPart();
      final contentInfos = msg.findContentInfo();

      final attachmentsJson = jsonEncode(
        contentInfos
            .map(
              (a) => {
                'filename': a.fileName ?? '',
                'contentType': a.contentType?.mediaType.text ?? '',
                'size': a.size ??
                    msg.getPart(a.fetchId)?.decodeContentBinary()?.length ??
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

      await _db.into(_db.emailBodies).insertOnConflictUpdate(
            EmailBodiesCompanion.insert(
              emailId: emailId,
              textBody: Value(textBody),
              htmlBody: Value(htmlBody),
              attachmentsJson: Value(attachmentsJson),
              headersJson: Value(headersJson),
              cachedAt: Value(DateTime.now()),
            ),
          );
      return model.EmailBody(
        emailId: emailId,
        textBody: textBody,
        htmlBody: htmlBody,
        attachments: _parseAttachments(attachmentsJson),
        headers: _parseHeaders(headersJson),
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
          ],
          'fetchHTMLBodyValues': true,
          'fetchTextBodyValues': true,
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

    await _db.into(_db.emailBodies).insertOnConflictUpdate(
          EmailBodiesCompanion.insert(
            emailId: emailId,
            textBody: Value(textBody),
            htmlBody: Value(htmlBody),
            attachmentsJson: Value(attachmentsJson),
            headersJson: Value(headersJson),
            cachedAt: Value(DateTime.now()),
          ),
        );

    return model.EmailBody(
      emailId: emailId,
      textBody: textBody,
      htmlBody: htmlBody,
      attachments: _parseAttachments(attachmentsJson),
      headers: _parseHeaders(headersJson),
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
      final selectedMailbox = await client.selectMailboxByPath(
        mailboxPath,
        enableCondStore: supportsCondStore,
      );
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
      final emailId = '${account.id}:$uid';
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
        final emailId = '${account.id}:$uid';
        final msgId = envelope.messageId?.trim();
        final inReplyTo = envelope.inReplyTo?.trim();
        final refs = msg.getHeaderValue('References')?.trim();
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

    final serverUidSet = serverUids.toSet();
    final affectedThreads = <String>{};
    for (final row in localRows) {
      if (!serverUidSet.contains(row.uid)) {
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

    final storedState = await _loadSyncState(account.id, 'Email');

    if (storedState == null) {
      return _jmapFullEmailSync(account.id, jmap, mailboxJmapId);
    } else {
      return _jmapIncrementalEmailSync(account.id, jmap, storedState);
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

    await _saveSyncState(accountId, 'Email', firstState);
    return model.SyncEmailsResult(
      fetched: fetched,
      skipped: 0,
      bytesTransferred: bytes,
    );
  }

  Future<model.SyncEmailsResult> _jmapIncrementalEmailSync(
    String accountId,
    JmapClient jmap,
    String sinceState,
  ) async {
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
        .getSingle();
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
        .getSingle();
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
        .getSingle();
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

    final ifInState = await _loadSyncState(account.id, 'Email');
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
        }
      } on JmapStateMismatchException {
        // Server rejected the mutation because our state token is stale.
        // Drop the cached state so the next sync cycle does a full re-fetch,
        // after which this change will be retried with a fresh token.
        await (_db.delete(_db.syncStates)
              ..where(
                (t) =>
                    t.accountId.equals(account.id) &
                    t.resourceType.equals('Email'),
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
          await _recordChangeError(row, e);
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
    final mailboxPath = payload['mailboxPath'] as String;
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
        await client.uidMove(seq, targetMailboxPath: payload['dest'] as String);
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
        await client.uidMove(seq, targetMailboxPath: dest);
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
        await client.uidMove(seq, targetMailboxPath: dest);
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
        final destMailboxId = payload['dest'] as String;
        final srcMailboxId = payload['src'] as String;
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
    );
    try {
      await smtpClient.sendMessage(mimeMessage);
    } finally {
      await smtpClient.quit();
    }
    // Save a copy to the Sent folder via IMAP APPEND.
    // Create the folder first — many servers don't pre-create it.
    final imapClient = await _imapConnect(
      account,
      _effectiveUsername(account),
      password,
    );
    try {
      try {
        await imapClient.createMailbox('Sent');
      } catch (_) {
        // Already exists — that's fine.
      }
      await imapClient.appendMessage(
        mimeMessage,
        targetMailboxPath: 'Sent',
        flags: [r'\Seen'],
      );
    } finally {
      await imapClient.logout();
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
    final identityId =
        (identityList.first as Map<String, dynamic>)['id'] as String;

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
        '${err['properties'] ?? ''}',
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
      final fetch = await client.uidFetchMessage(
        emailRow.uid,
        'BODY.PEEK[]',
      );
      final msg = fetch.messages.first;
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
  Future<List<model.Email>> searchEmailsGlobal(
    String? accountId,
    String query,
  ) async {
    final ftsQuery = _toFtsQuery(query);
    if (ftsQuery.isEmpty) return [];

    final sql = accountId != null
        ? 'SELECT e.* FROM email_fts f JOIN emails e ON e.rowid = f.rowid'
            ' WHERE email_fts MATCH ? AND e.account_id = ? ORDER BY rank LIMIT 50'
        : 'SELECT e.* FROM email_fts f JOIN emails e ON e.rowid = f.rowid'
            ' WHERE email_fts MATCH ? ORDER BY rank LIMIT 50';
    final variables = accountId != null
        ? [Variable<String>(ftsQuery), Variable<String>(accountId)]
        : [Variable<String>(ftsQuery)];

    final queryRows = await _db
        .customSelect(sql, variables: variables, readsFrom: {_db.emails}).get();
    final emailRows = await Future.wait(
      queryRows.map((r) => _db.emails.mapFromRow(r)),
    );
    return emailRows.map(_toModel).toList();
  }

  /// Converts a user query string into an FTS5 match expression.
  /// Each whitespace-separated word becomes a prefix term (word*) so that
  /// partial words still match. Special FTS5 characters are stripped.
  static String _toFtsQuery(String query) {
    final words = query
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .map((w) => w.replaceAll(RegExp(r'[^\w]'), ''))
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
  Future<List<model.Email>> searchEmails(
    String accountId,
    String mailboxPath,
    String query,
  ) async {
    final account = (await _accounts.getAccount(accountId))!;
    final password = await _accounts.getPassword(accountId);
    final client = await _imapConnect(
      account,
      _effectiveUsername(account),
      password,
    );
    try {
      await client.selectMailboxByPath(mailboxPath);
      final terms =
          query.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
      final searchCriteria = terms.map((term) {
        final escaped = term.replaceAll('"', '\\"');
        return 'OR SUBJECT "$escaped" TEXT "$escaped"';
      }).join(' ');
      final result = await client.uidSearchMessages(
        searchCriteria: searchCriteria,
      );
      final uids = result.matchingSequence?.toList() ?? [];
      if (uids.isEmpty) return [];

      final fetch = await client.uidFetchMessages(
        imap.MessageSequence.fromIds(uids, isUid: true),
        '(UID FLAGS ENVELOPE)',
      );
      return fetch.messages
          .where((msg) => msg.uid != null && msg.envelope != null)
          .map((msg) {
        final envelope = msg.envelope!;
        final uid = msg.uid!;
        final emailId = '$accountId:$uid';
        return model.Email(
          id: emailId,
          accountId: accountId,
          mailboxPath: mailboxPath,
          uid: uid,
          subject: envelope.subject,
          sentAt: envelope.date,
          receivedAt: envelope.date ?? DateTime.now(),
          from: _toAddressList(envelope.from),
          to: _toAddressList(envelope.to),
          cc: _toAddressList(envelope.cc),
          isSeen: msg.flags?.contains(r'\Seen') ?? false,
          isFlagged: msg.flags?.contains(r'\Flagged') ?? false,
          hasAttachment: msg.hasAttachments(),
        );
      }).toList();
    } finally {
      await client.logout();
    }
  }

  List<model.EmailAddress> _toAddressList(List<imap.MailAddress>? addresses) =>
      (addresses ?? const [])
          .map((a) => model.EmailAddress(name: a.personalName, email: a.email))
          .toList();

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
        await (_db.delete(_db.emails)
              ..where((t) => t.accountId.equals(accountId)))
            .go();
        await (_db.delete(_db.pendingChanges)
              ..where((t) => t.accountId.equals(accountId)))
            .go();
        await (_db.delete(_db.syncStates)
              ..where((t) => t.accountId.equals(accountId)))
            .go();
      });
    } finally {
      await _db.customStatement('PRAGMA foreign_keys = ON');
    }
  }
}
