import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:http/http.dart' as http;

import '../../core/models/account.dart' as account_model;
import '../../core/models/email.dart' as model;
import '../../core/repositories/account_repository.dart';
import '../../core/repositories/email_repository.dart';
import '../db/database.dart';
import '../imap/imap_client_factory.dart';
import '../jmap/jmap_client.dart';

typedef SmtpConnectFn = Future<imap.SmtpClient> Function(
    account_model.Account account, String username, String password);
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

  String _effectiveUsername(account_model.Account account) =>
      account.username.isNotEmpty ? account.username : account.email;

  // ── Observe ────────────────────────────────────────────────────────────────

  @override
  Stream<List<model.Email>> observeEmails(
    String accountId,
    String mailboxPath,
  ) {
    return (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.mailboxPath.equals(mailboxPath),
          )
          ..orderBy([(t) => OrderingTerm.desc(t.receivedAt)]))
        .watch()
        .map((rows) => rows.map(_toModel).toList());
  }

  @override
  Future<model.Email?> getEmail(String emailId) async {
    final row = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(emailId)))
        .getSingleOrNull();
    return row == null ? null : _toModel(row);
  }

  // ── Body (on-demand) ───────────────────────────────────────────────────────

  @override
  Future<model.EmailBody> getEmailBody(String emailId) async {
    final cached = await (_db.select(_db.emailBodies)
          ..where((t) => t.emailId.equals(emailId)))
        .getSingleOrNull();
    if (cached != null) return _bodyRowToModel(cached);

    final emailRow = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(emailId)))
        .getSingle();
    final account = (await _accounts.getAccount(emailRow.accountId))!;
    final password = await _accounts.getPassword(account.id);
    final client = await _imapConnect(account, _effectiveUsername(account), password);
    try {
      await client.selectMailboxByPath(emailRow.mailboxPath);
      final fetch = await client.uidFetchMessage(emailRow.uid, '(BODY[])');
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
                'size': a.size ?? 0,
                'fetchPartId': a.fetchId,
              },
            )
            .toList(),
      );

      await _db.into(_db.emailBodies).insertOnConflictUpdate(
            EmailBodiesCompanion.insert(
              emailId: emailId,
              textBody: Value(textBody),
              htmlBody: Value(htmlBody),
              attachmentsJson: Value(attachmentsJson),
            ),
          );
      return model.EmailBody(
        emailId: emailId,
        textBody: textBody,
        htmlBody: htmlBody,
        attachments: _parseAttachments(attachmentsJson),
      );
    } finally {
      await client.logout();
    }
  }

  // ── Sync ───────────────────────────────────────────────────────────────────

  @override
  Future<void> syncEmails(String accountId, String mailboxPath) async {
    final account = (await _accounts.getAccount(accountId))!;
    final password = await _accounts.getPassword(accountId);
    switch (account.type) {
      case account_model.AccountType.imap:
        await _syncEmailsImap(account, password, mailboxPath);
      case account_model.AccountType.jmap:
        await _syncEmailsJmap(account, password, mailboxPath);
    }
  }

  Future<void> _syncEmailsImap(
    account_model.Account account,
    String password,
    String mailboxPath,
  ) async {
    final client =
        await _imapConnect(account, _effectiveUsername(account), password);
    try {
      final selectedMailbox = await client.selectMailboxByPath(mailboxPath);
      final uidValidity = selectedMailbox.uidValidity ?? 0;
      final resourceType = 'IMAP:$mailboxPath';
      final checkpoint = await _loadImapCheckpoint(account.id, resourceType);

      if (checkpoint == null || checkpoint['uidValidity'] != uidValidity) {
        // First run or UID validity changed — full sync.
        if (checkpoint != null) {
          // UID validity changed: remove stale local emails for this mailbox.
          await (_db.delete(_db.emails)
                ..where((t) =>
                    t.accountId.equals(account.id) &
                    t.mailboxPath.equals(mailboxPath)))
              .go();
        }
        await _fetchAndUpsertImap(
            client, account, mailboxPath, imap.MessageSequence.fromAll());
        final maxUid = await _maxLocalUid(account.id, mailboxPath);
        await _saveImapCheckpoint(
            account.id, resourceType, uidValidity, maxUid);
      } else {
        // Incremental sync.
        final lastUid = checkpoint['lastUid'] as int;
        final newUids =
            (await client.uidSearchMessages(searchCriteria: 'UID ${lastUid + 1}:*'))
                    .matchingSequence
                    ?.toList() ??
                [];
        if (newUids.isNotEmpty) {
          await _fetchAndUpsertImap(client, account, mailboxPath,
              imap.MessageSequence.fromIds(newUids, isUid: true));
        }
        // Detect remote deletions.
        final serverUids =
            (await client.uidSearchMessages(searchCriteria: 'ALL'))
                    .matchingSequence
                    ?.toList() ??
                [];
        await _reconcileDeletedImap(account.id, mailboxPath, serverUids);
        final maxUid =
            serverUids.isEmpty ? lastUid : serverUids.reduce(math.max);
        await _saveImapCheckpoint(
            account.id, resourceType, uidValidity, maxUid);
      }
    } finally {
      await client.logout();
    }
  }

  Future<void> _fetchAndUpsertImap(
    imap.ImapClient client,
    account_model.Account account,
    String mailboxPath,
    imap.MessageSequence sequence,
  ) async {
    final fetch = await client.fetchMessages(
        sequence, '(UID FLAGS ENVELOPE BODYSTRUCTURE)');
    for (final msg in fetch.messages) {
      final envelope = msg.envelope;
      if (envelope == null) continue;
      final uid = msg.uid;
      if (uid == null) continue;
      final emailId = '${account.id}:$uid';
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
            ),
          );
    }
  }

  Future<int> _maxLocalUid(String accountId, String mailboxPath) async {
    final rows = await (_db.select(_db.emails)
          ..where((t) =>
              t.accountId.equals(accountId) &
              t.mailboxPath.equals(mailboxPath)))
        .get();
    if (rows.isEmpty) return 0;
    return rows.map((r) => r.uid).reduce(math.max);
  }

  Future<Map<String, dynamic>?> _loadImapCheckpoint(
      String accountId, String resourceType) async {
    final raw = await _loadSyncState(accountId, resourceType);
    if (raw == null) return null;
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<void> _saveImapCheckpoint(String accountId, String resourceType,
      int uidValidity, int lastUid) async {
    await _saveSyncState(accountId, resourceType,
        jsonEncode({'uidValidity': uidValidity, 'lastUid': lastUid}));
  }

  Future<void> _reconcileDeletedImap(
      String accountId, String mailboxPath, List<int> serverUids) async {
    final serverUidSet = serverUids.toSet();
    final localRows = await (_db.select(_db.emails)
          ..where((t) =>
              t.accountId.equals(accountId) &
              t.mailboxPath.equals(mailboxPath)))
        .get();
    for (final row in localRows) {
      if (!serverUidSet.contains(row.uid)) {
        await (_db.delete(_db.emails)..where((t) => t.id.equals(row.id))).go();
      }
    }
  }

  // ── JMAP email sync ────────────────────────────────────────────────────────

  static const _emailProperties = [
    'id', 'mailboxIds', 'subject', 'sentAt', 'receivedAt',
    'from', 'to', 'cc', 'keywords', 'hasAttachment', 'preview',
  ];

  Future<void> _syncEmailsJmap(
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
      await _jmapFullEmailSync(account.id, jmap, mailboxJmapId);
    } else {
      await _jmapIncrementalEmailSync(account.id, jmap, storedState);
    }
  }

  Future<void> _jmapFullEmailSync(
      String accountId, JmapClient jmap, String mailboxJmapId) async {
    // Query IDs in this mailbox, newest first, up to 500.
    final responses = await jmap.call([
      [
        'Email/query',
        {
          'accountId': jmap.accountId,
          'filter': {'inMailbox': mailboxJmapId},
          'sort': [{'property': 'receivedAt', 'isAscending': false}],
          'limit': 500,
        },
        '0',
      ],
      [
        'Email/get',
        {
          'accountId': jmap.accountId,
          '#ids': {'resultOf': '0', 'name': 'Email/query', 'path': '/ids'},
          'properties': _emailProperties,
        },
        '1',
      ],
    ]);

    final getResult = _responseArgs(responses, 1, 'Email/get');
    final emails = getResult['list'] as List<dynamic>;
    final newState = getResult['state'] as String;

    await _upsertJmapEmails(accountId, emails);
    await _saveSyncState(accountId, 'Email', newState);
  }

  Future<void> _jmapIncrementalEmailSync(
      String accountId, JmapClient jmap, String sinceState) async {
    final responses = await jmap.call([
      [
        'Email/changes',
        {'accountId': jmap.accountId, 'sinceState': sinceState},
        '0',
      ]
    ]);

    final changes = _responseArgs(responses, 0, 'Email/changes');
    final newState = changes['newState'] as String;
    final created = List<String>.from(changes['created'] as List? ?? []);
    final updated = List<String>.from(changes['updated'] as List? ?? []);
    final destroyed = List<String>.from(changes['destroyed'] as List? ?? []);

    final toFetch = [...created, ...updated];
    if (toFetch.isNotEmpty) {
      final getResponses = await jmap.call([
        [
          'Email/get',
          {
            'accountId': jmap.accountId,
            'ids': toFetch,
            'properties': _emailProperties,
          },
          '1',
        ]
      ]);
      final getResult = _responseArgs(getResponses, 0, 'Email/get');
      await _upsertJmapEmails(accountId, getResult['list'] as List<dynamic>);
    }

    for (final jmapId in destroyed) {
      await (_db.delete(_db.emails)
            ..where((t) => t.id.equals('$accountId:$jmapId')))
          .go();
    }

    await _saveSyncState(accountId, 'Email', newState);
  }

  Future<void> _upsertJmapEmails(
      String accountId, List<dynamic> emails) async {
    for (final e in emails) {
      final m = e as Map<String, dynamic>;
      final jmapId = m['id'] as String;
      final dbId = '$accountId:$jmapId';

      // Use first mailbox ID as the primary mailboxPath.
      final mailboxIds = m['mailboxIds'] as Map<String, dynamic>?;
      final mailboxPath = mailboxIds?.keys.firstOrNull ?? '';

      final keywords = m['keywords'] as Map<String, dynamic>? ?? {};
      final from = _encodeJmapAddresses(m['from']);
      final to = _encodeJmapAddresses(m['to']);
      final cc = _encodeJmapAddresses(m['cc']);
      final sentAt = _parseDate(m['sentAt'] as String?);
      final receivedAt = _parseDate(m['receivedAt'] as String?) ?? DateTime.now();

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
            ),
          );
    }
  }

  // ── sync_state helpers ────────────────────────────────────────────────────

  Future<String?> _loadSyncState(String accountId, String resourceType) async {
    final row = await (_db.select(_db.syncStates)
          ..where((t) =>
              t.accountId.equals(accountId) &
              t.resourceType.equals(resourceType)))
        .getSingleOrNull();
    return row?.state;
  }

  Future<void> _saveSyncState(
      String accountId, String resourceType, String state) async {
    await _db.into(_db.syncStates).insertOnConflictUpdate(
          SyncStatesCompanion.insert(
            accountId: accountId,
            resourceType: resourceType,
            state: state,
            syncedAt: DateTime.now(),
          ),
        );
  }

  // ── JMAP helpers ─────────────────────────────────────────────────────────

  Map<String, dynamic> _responseArgs(
      List<dynamic> responses, int index, String expectedMethod) {
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
    return jsonEncode(list
        .map((a) => {
              'name': (a as Map<String, dynamic>)['name'],
              'email': a['email'],
            })
        .toList());
  }

  DateTime? _parseDate(String? iso) =>
      iso == null ? null : DateTime.tryParse(iso);

  // ── Mutations ──────────────────────────────────────────────────────────────

  @override
  Future<void> setFlag(
    String emailId, {
    bool? seen,
    bool? flagged,
  }) async {
    final row = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(emailId)))
        .getSingle();
    final account = (await _accounts.getAccount(row.accountId))!;

    if (account.type == account_model.AccountType.jmap) {
      if (seen != null) {
        await _enqueueChange(account.id, emailId, 'flag_seen',
            jsonEncode({'seen': seen}));
      }
      if (flagged != null) {
        await _enqueueChange(account.id, emailId, 'flag_flagged',
            jsonEncode({'flagged': flagged}));
      }
      // Optimistic local update.
      await (_db.update(_db.emails)..where((t) => t.id.equals(emailId))).write(
        EmailsCompanion(
          isSeen: seen != null ? Value(seen) : const Value.absent(),
          isFlagged: flagged != null ? Value(flagged) : const Value.absent(),
        ),
      );
      return;
    }

    if (seen != null) {
      await _enqueueChange(account.id, emailId, 'flag_seen',
          jsonEncode({'uid': row.uid, 'mailboxPath': row.mailboxPath, 'seen': seen}));
    }
    if (flagged != null) {
      await _enqueueChange(account.id, emailId, 'flag_flagged',
          jsonEncode({'uid': row.uid, 'mailboxPath': row.mailboxPath, 'flagged': flagged}));
    }
    await (_db.update(_db.emails)..where((t) => t.id.equals(emailId))).write(
      EmailsCompanion(
        isSeen: seen != null ? Value(seen) : const Value.absent(),
        isFlagged: flagged != null ? Value(flagged) : const Value.absent(),
      ),
    );
  }

  @override
  Future<void> moveEmail(String emailId, String destMailboxPath) async {
    final row = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(emailId)))
        .getSingle();
    final account = (await _accounts.getAccount(row.accountId))!;

    if (account.type == account_model.AccountType.jmap) {
      await _enqueueChange(account.id, emailId, 'move',
          jsonEncode({'dest': destMailboxPath}));
      // Optimistic: remove from current view; next sync will reconcile.
      await (_db.delete(_db.emails)..where((t) => t.id.equals(emailId))).go();
      return;
    }

    await _enqueueChange(account.id, emailId, 'move',
        jsonEncode({'uid': row.uid, 'mailboxPath': row.mailboxPath, 'dest': destMailboxPath}));
    await (_db.delete(_db.emails)..where((t) => t.id.equals(emailId))).go();
  }

  @override
  Future<void> deleteEmail(String emailId) async {
    final row = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(emailId)))
        .getSingle();
    final account = (await _accounts.getAccount(row.accountId))!;

    if (account.type == account_model.AccountType.jmap) {
      await _enqueueChange(
          account.id, emailId, 'delete', jsonEncode(<String, dynamic>{}));
      await (_db.delete(_db.emails)..where((t) => t.id.equals(emailId))).go();
      return;
    }

    await _enqueueChange(account.id, emailId, 'delete',
        jsonEncode({'uid': row.uid, 'mailboxPath': row.mailboxPath}));
    await (_db.delete(_db.emails)..where((t) => t.id.equals(emailId))).go();
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
  }

  /// Drains pending changes for [accountId] via the appropriate protocol.
  /// Called at the start of each sync cycle.
  @override
  Future<void> flushPendingChanges(
      String accountId, String password) async {
    final rows = await (_db.select(_db.pendingChanges)
          ..where((t) => t.accountId.equals(accountId))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();
    if (rows.isEmpty) return;

    final account = (await _accounts.getAccount(accountId))!;
    switch (account.type) {
      case account_model.AccountType.imap:
        await _flushPendingChangesImap(account, password, rows);
      case account_model.AccountType.jmap:
        await _flushPendingChangesJmap(account, password, rows);
    }
  }

  Future<void> _flushPendingChangesJmap(account_model.Account account,
      String password, List<PendingChangeRow> rows) async {
    final jmapUrl = account.jmapUrl;
    if (jmapUrl == null || jmapUrl.isEmpty) return;

    final jmap = await JmapClient.connect(
      httpClient: _httpClient,
      jmapUrl: Uri.parse(jmapUrl),
      username: _effectiveUsername(account),
      password: password,
    );

    for (final row in rows) {
      try {
        await _applyPendingChangeJmap(jmap, row);
        await (_db.delete(_db.pendingChanges)
              ..where((t) => t.id.equals(row.id)))
            .go();
      } catch (e) {
        await (_db.update(_db.pendingChanges)
              ..where((t) => t.id.equals(row.id)))
            .write(PendingChangesCompanion(
          attempts: Value(row.attempts + 1),
          lastError: Value(e.toString()),
        ));
      }
    }
  }

  Future<void> _flushPendingChangesImap(account_model.Account account,
      String password, List<PendingChangeRow> rows) async {
    imap.ImapClient? client;
    try {
      client =
          await _imapConnect(account, _effectiveUsername(account), password);
    } catch (e) {
      for (final row in rows) {
        await (_db.update(_db.pendingChanges)
              ..where((t) => t.id.equals(row.id)))
            .write(PendingChangesCompanion(
          attempts: Value(row.attempts + 1),
          lastError: Value(e.toString()),
        ));
      }
      return;
    }
    try {
      for (final row in rows) {
        try {
          await _applyPendingChangeImap(client, row);
          await (_db.delete(_db.pendingChanges)
                ..where((t) => t.id.equals(row.id)))
              .go();
        } catch (e) {
          await (_db.update(_db.pendingChanges)
                ..where((t) => t.id.equals(row.id)))
              .write(PendingChangesCompanion(
            attempts: Value(row.attempts + 1),
            lastError: Value(e.toString()),
          ));
        }
      }
    } finally {
      await client.logout();
    }
  }

  Future<void> _applyPendingChangeImap(
      imap.ImapClient client, PendingChangeRow row) async {
    final payload = jsonDecode(row.payload) as Map<String, dynamic>;
    final uid = payload['uid'] as int;
    final mailboxPath = payload['mailboxPath'] as String;
    final seq = imap.MessageSequence.fromId(uid, isUid: true);
    await client.selectMailboxByPath(mailboxPath);

    switch (row.changeType) {
      case 'flag_seen':
        final seen = payload['seen'] as bool;
        seen
            ? await client.uidMarkSeen(seq)
            : await client.uidMarkUnseen(seq);
      case 'flag_flagged':
        final flagged = payload['flagged'] as bool;
        flagged
            ? await client.uidMarkFlagged(seq)
            : await client.uidMarkUnflagged(seq);
      case 'move':
        await client.uidMove(seq,
            targetMailboxPath: payload['dest'] as String);
      case 'delete':
        await client.uidMarkDeleted(seq);
        await client.uidExpunge(seq);
    }
  }

  Future<void> _applyPendingChangeJmap(
      JmapClient jmap, PendingChangeRow row) async {
    final payload = jsonDecode(row.payload) as Map<String, dynamic>;
    // Extract the JMAP email ID from the DB id (format: "accountId:jmapId").
    final jmapEmailId = row.resourceId.contains(':')
        ? row.resourceId.substring(row.resourceId.indexOf(':') + 1)
        : row.resourceId;

    switch (row.changeType) {
      case 'flag_seen':
        final seen = payload['seen'] as bool;
        await jmap.call([
          [
            'Email/set',
            {
              'accountId': jmap.accountId,
              'update': {
                jmapEmailId: {
                  'keywords/\$seen': seen,
                },
              },
            },
            '0',
          ]
        ]);

      case 'flag_flagged':
        final flagged = payload['flagged'] as bool;
        await jmap.call([
          [
            'Email/set',
            {
              'accountId': jmap.accountId,
              'update': {
                jmapEmailId: {
                  'keywords/\$flagged': flagged,
                },
              },
            },
            '0',
          ]
        ]);

      case 'move':
        final destMailboxId = payload['dest'] as String;
        await jmap.call([
          [
            'Email/set',
            {
              'accountId': jmap.accountId,
              'update': {
                jmapEmailId: {
                  'mailboxIds/$destMailboxId': true,
                  'mailboxIds/${row.resourceId}': null,
                },
              },
            },
            '0',
          ]
        ]);

      case 'delete':
        await jmap.call([
          [
            'Email/set',
            {
              'accountId': jmap.accountId,
              'destroy': [jmapEmailId],
            },
            '0',
          ]
        ]);
    }
  }

  @override
  Future<void> sendEmail(String accountId, model.EmailDraft draft) async {
    final account = (await _accounts.getAccount(accountId))!;
    final password = await _accounts.getPassword(accountId);
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
    final smtpClient = await _smtpConnect(account, _effectiveUsername(account), password);
    try {
      await smtpClient.sendMessage(mimeMessage);
    } finally {
      await smtpClient.quit();
    }
    // Save a copy to the Sent folder via IMAP APPEND.
    // Create the folder first — many servers don't pre-create it.
    final imapClient = await _imapConnect(account, _effectiveUsername(account), password);
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

    final emailRow = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(emailId)))
        .getSingle();
    final account = (await _accounts.getAccount(emailRow.accountId))!;
    final password = await _accounts.getPassword(account.id);
    final client = await _imapConnect(account, _effectiveUsername(account), password);
    try {
      await client.selectMailboxByPath(emailRow.mailboxPath);
      final fetch = await client.uidFetchMessage(
        emailRow.uid,
        'BODY[${attachment.fetchPartId}]',
      );
      final msg = fetch.messages.first;
      final part = msg.getPart(attachment.fetchPartId);
      final bytes = part?.decodeContentBinary();
      if (bytes == null) {
        throw StateError(
          'Failed to decode attachment ${attachment.filename}.',
        );
      }
      await file.writeAsBytes(bytes);
      return file.path;
    } finally {
      await client.logout();
    }
  }

  @override
  Future<List<model.Email>> searchEmails(
    String accountId,
    String mailboxPath,
    String query,
  ) async {
    final account = (await _accounts.getAccount(accountId))!;
    final password = await _accounts.getPassword(accountId);
    final client = await _imapConnect(account, _effectiveUsername(account), password);
    try {
      await client.selectMailboxByPath(mailboxPath);
      final escaped = query.replaceAll('"', '\\"');
      final result = await client.uidSearchMessages(
        searchCriteria: 'OR SUBJECT "$escaped" TEXT "$escaped"',
      );
      final uids = result.matchingSequence?.toList() ?? [];
      if (uids.isEmpty) return [];

      final fetch = await client.fetchMessages(
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
          .map(
            (a) => model.EmailAddress(
              name: a.personalName,
              email: a.email,
            ),
          )
          .toList();

  // ── Helpers ────────────────────────────────────────────────────────────────

  String _encodeAddresses(List<imap.MailAddress>? addresses) => jsonEncode(
        (addresses ?? const [])
            .map((a) => {'name': a.personalName, 'email': a.email})
            .toList(),
      );

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
    );
  }

  model.EmailBody _bodyRowToModel(EmailBody row) => model.EmailBody(
        emailId: row.emailId,
        textBody: row.textBody,
        htmlBody: row.htmlBody,
        attachments: _parseAttachments(row.attachmentsJson),
      );

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
}
