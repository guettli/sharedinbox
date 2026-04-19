import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';

import 'account_repository_impl_test.dart' show MapSecureStorage;
import 'db_test_helper.dart';
import 'fake_imap.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

const _account = Account(
  id: 'acc-1',
  displayName: 'Alice',
  email: 'alice@example.com',
  imapHost: 'imap.example.com',
  smtpHost: 'smtp.example.com',
);

const _jmapAccount = Account(
  id: 'jmap-1',
  displayName: 'Alice',
  email: 'alice@example.com',
  type: AccountType.jmap,
  jmapUrl: 'https://jmap.example.com/.well-known/jmap',
);

http.Client _mockJmapEmails({required List<Map<String, dynamic>> apiResponses}) {
  var callIndex = 0;
  return MockClient((req) async {
    if (req.url.path.contains('well-known')) {
      return http.Response(
        jsonEncode({
          'apiUrl': 'https://jmap.example.com/api/',
          'accounts': {'acct1': {'name': 'alice@example.com', 'isPersonal': true}},
          'primaryAccounts': {
            'urn:ietf:params:jmap:core': 'acct1',
            'urn:ietf:params:jmap:mail': 'acct1',
          },
          'capabilities': {},
          'username': 'alice@example.com',
          'state': 'sess1',
        }),
        200,
      );
    }
    final resp = apiResponses[callIndex % apiResponses.length];
    callIndex++;
    return http.Response(jsonEncode(resp), 200);
  });
}

Map<String, dynamic> _emailGetResponse(
    {required String state, required List<Map<String, dynamic>> list}) =>
    {
      'sessionState': 'sess1',
      'methodResponses': [
        ['Email/query', {'accountId': 'acct1', 'ids': list.map((e) => e['id']).toList()}, '0'],
        ['Email/get', {'accountId': 'acct1', 'state': state, 'list': list}, '1'],
      ],
    };

Map<String, dynamic> _emailChangesResponse({
  required String oldState,
  required String newState,
  List<String> created = const [],
  List<String> updated = const [],
  List<String> destroyed = const [],
}) =>
    {
      'sessionState': 'sess1',
      'methodResponses': [
        [
          'Email/changes',
          {
            'accountId': 'acct1',
            'oldState': oldState,
            'newState': newState,
            'hasMoreChanges': false,
            'created': created,
            'updated': updated,
            'destroyed': destroyed,
          },
          '0',
        ],
      ],
    };

Map<String, dynamic> _emailGetOnly(
    {required String state, required List<Map<String, dynamic>> list}) =>
    {
      'sessionState': 'sess1',
      'methodResponses': [
        ['Email/get', {'accountId': 'acct1', 'state': state, 'list': list}, '1'],
      ],
    };

Map<String, dynamic> _jmapEmail({
  required String id,
  required String mailboxId,
  String subject = 'Hello',
  bool seen = false,
}) =>
    {
      'id': id,
      'mailboxIds': {mailboxId: true},
      'subject': subject,
      'sentAt': '2024-01-01T10:00:00Z',
      'receivedAt': '2024-01-01T10:00:01Z',
      'from': [{'name': 'Sender', 'email': 'sender@example.com'}],
      'to': [{'name': 'Alice', 'email': 'alice@example.com'}],
      'cc': [],
      'keywords': seen ? {r'$seen': true} : <String, dynamic>{},
      'hasAttachment': false,
      'preview': 'Hello world',
    };

Future<imap.ImapClient> _noImapConnect(Account a, String u, String p) =>
    Future.error(UnsupportedError('IMAP unavailable in unit tests'));

Future<imap.SmtpClient> _noSmtpConnect(Account a, String u, String p) =>
    Future.error(UnsupportedError('SMTP unavailable in unit tests'));

({
  AppDatabase db,
  AccountRepositoryImpl accounts,
  EmailRepositoryImpl emails,
}) _makeRepos({http.Client? httpClient}) {
  final db = openTestDatabase();
  final storage = MapSecureStorage();
  final accounts = AccountRepositoryImpl(db, storage);
  final emails = EmailRepositoryImpl(
    db,
    accounts,
    imapConnect: _noImapConnect,
    smtpConnect: _noSmtpConnect,
    httpClient: httpClient,
  );
  return (db: db, accounts: accounts, emails: emails);
}

({
  AppDatabase db,
  AccountRepositoryImpl accounts,
  EmailRepositoryImpl emails,
  FakeImapClient fakeImap,
  FakeSmtpClient fakeSmtp,
  Directory cacheDir,
}) _makeReposWithFakes() {
  final db = openTestDatabase();
  final accounts = AccountRepositoryImpl(db, MapSecureStorage());
  final fakeImap = FakeImapClient();
  final fakeSmtp = FakeSmtpClient();
  final cacheDir = Directory.systemTemp.createTempSync('test_attach_');
  final emails = EmailRepositoryImpl(
    db,
    accounts,
    imapConnect: (_, __, ___) async => fakeImap,
    smtpConnect: (_, __, ___) async => fakeSmtp,
    getCacheDir: () async => cacheDir,
  );
  return (
    db: db,
    accounts: accounts,
    emails: emails,
    fakeImap: fakeImap,
    fakeSmtp: fakeSmtp,
    cacheDir: cacheDir,
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUpAll(configureSqliteForTests);

  group('EmailRepositoryImpl', () {
    test('observeEmails emits empty list when no emails', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      final emails =
          await r.emails.observeEmails('acc-1', 'INBOX').first;
      expect(emails, isEmpty);
    });

    test('getEmail returns null for unknown id', () async {
      final r = _makeRepos();
      expect(await r.emails.getEmail('no-such-id'), isNull);
    });

    test('observeEmails reflects inserted row', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');

      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:42',
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              uid: 42,
              receivedAt: DateTime(2024),
            ),
          );

      final emails = await r.emails.observeEmails('acc-1', 'INBOX').first;
      expect(emails, hasLength(1));
      expect(emails.first.id, 'acc-1:42');
      expect(emails.first.uid, 42);
    });

    test('getEmail returns inserted row', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');

      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:7',
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              uid: 7,
              receivedAt: DateTime(2024, 6, 15),
            ),
          );

      final email = await r.emails.getEmail('acc-1:7');
      expect(email, isNotNull);
      expect(email!.mailboxPath, 'INBOX');
    });

    test('observeEmails orders by receivedAt descending', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');

      for (final (uid, date) in [
        (1, DateTime(2024)),
        (3, DateTime(2024, 3)),
        (2, DateTime(2024, 2)),
      ]) {
        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: 'acc-1:$uid',
                accountId: 'acc-1',
                mailboxPath: 'INBOX',
                uid: uid,
                receivedAt: date,
              ),
            );
      }

      final emails = await r.emails.observeEmails('acc-1', 'INBOX').first;
      expect(emails.map((e) => e.uid).toList(), [3, 2, 1]);
    });

    test('syncEmails propagates IMAP error', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      expect(
        () => r.emails.syncEmails('acc-1', 'INBOX'),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('getEmailBody propagates IMAP error when not cached', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:1',
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              uid: 1,
              receivedAt: DateTime(2024),
            ),
          );
      expect(
        () => r.emails.getEmailBody('acc-1:1'),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('getEmailBody returns cached body without IMAP call', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:1',
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              uid: 1,
              receivedAt: DateTime(2024),
            ),
          );
      await r.db.into(r.db.emailBodies).insert(
            EmailBodiesCompanion.insert(
              emailId: 'acc-1:1',
              textBody: const Value('Hello'),
              htmlBody: const Value('<p>Hello</p>'),
            ),
          );

      final body = await r.emails.getEmailBody('acc-1:1');
      expect(body.textBody, 'Hello');
      expect(body.htmlBody, '<p>Hello</p>');
    });

    test('getEmailBody fetches from IMAP and caches when not stored', () async {
      final r = _makeReposWithFakes();
      await r.accounts.addAccount(_account, 'pw');
      await r.db.into(r.db.emails).insert(EmailsCompanion.insert(
            id: 'acc-1:1',
            accountId: 'acc-1',
            mailboxPath: 'INBOX',
            uid: 1,
            receivedAt: DateTime(2024),
          ));

      // Build a simple text/plain MimeMessage the IMAP fake will return.
      final msg = imap.MimeMessage.parseFromText(
        'Subject: Hi\r\n'
        'Content-Type: text/plain\r\n'
        '\r\n'
        'Hello from IMAP',
      );
      msg.uid = 1;
      r.fakeImap.fetchResults = [msg];

      final body = await r.emails.getEmailBody('acc-1:1');

      expect(body.textBody, contains('Hello from IMAP'));
      expect(r.fakeImap.logoutCalled, isTrue);

      // Second call should return cached without IMAP.
      r.fakeImap.logoutCalled = false;
      final cached = await r.emails.getEmailBody('acc-1:1');
      expect(cached.textBody, body.textBody);
      expect(r.fakeImap.logoutCalled, isFalse);
    });

    // ── IMAP method tests ────────────────────────────────────────────────────

    test('syncEmails stores fetched messages in DB', () async {
      final r = _makeReposWithFakes();
      await r.accounts.addAccount(_account, 'pw');
      r.fakeImap.fetchResults = [
        buildEnvelopeMessage(uid: 10, subject: 'Hello'),
        buildEnvelopeMessage(uid: 11, subject: 'World', flags: [r'\Seen']),
      ];

      await r.emails.syncEmails('acc-1', 'INBOX');

      final emails =
          await r.emails.observeEmails('acc-1', 'INBOX').first;
      expect(emails, hasLength(2));
      expect(emails.map((e) => e.uid).toSet(), {10, 11});
      expect(emails.firstWhere((e) => e.uid == 11).isSeen, isTrue);
      expect(r.fakeImap.logoutCalled, isTrue);
    });

    test('setFlag seen=true enqueues flag_seen change and updates local DB', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      await r.db.into(r.db.emails).insert(EmailsCompanion.insert(
            id: 'acc-1:5',
            accountId: 'acc-1',
            mailboxPath: 'INBOX',
            uid: 5,
            receivedAt: DateTime(2024),
          ));

      await r.emails.setFlag('acc-1:5', seen: true);

      final changes = await r.db.select(r.db.pendingChanges).get();
      expect(changes, hasLength(1));
      expect(changes.first.changeType, 'flag_seen');
      expect(changes.first.payload, contains('"seen":true'));
      final email = await r.emails.getEmail('acc-1:5');
      expect(email!.isSeen, isTrue);
    });

    test('setFlag seen=false enqueues flag_seen change with seen=false', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      await r.db.into(r.db.emails).insert(EmailsCompanion.insert(
            id: 'acc-1:5',
            accountId: 'acc-1',
            mailboxPath: 'INBOX',
            uid: 5,
            receivedAt: DateTime(2024),
            isSeen: const Value(true),
          ));

      await r.emails.setFlag('acc-1:5', seen: false);

      final changes = await r.db.select(r.db.pendingChanges).get();
      expect(changes.first.changeType, 'flag_seen');
      expect(changes.first.payload, contains('"seen":false'));
      final email = await r.emails.getEmail('acc-1:5');
      expect(email!.isSeen, isFalse);
    });

    test('setFlag flagged=true enqueues flag_flagged change', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      await r.db.into(r.db.emails).insert(EmailsCompanion.insert(
            id: 'acc-1:5',
            accountId: 'acc-1',
            mailboxPath: 'INBOX',
            uid: 5,
            receivedAt: DateTime(2024),
          ));

      await r.emails.setFlag('acc-1:5', flagged: true);

      final changes = await r.db.select(r.db.pendingChanges).get();
      expect(changes.first.changeType, 'flag_flagged');
      final email = await r.emails.getEmail('acc-1:5');
      expect(email!.isFlagged, isTrue);
    });

    test('setFlag flagged=false enqueues flag_flagged change with flagged=false', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      await r.db.into(r.db.emails).insert(EmailsCompanion.insert(
            id: 'acc-1:5',
            accountId: 'acc-1',
            mailboxPath: 'INBOX',
            uid: 5,
            receivedAt: DateTime(2024),
            isFlagged: const Value(true),
          ));

      await r.emails.setFlag('acc-1:5', flagged: false);

      final changes = await r.db.select(r.db.pendingChanges).get();
      expect(changes.first.changeType, 'flag_flagged');
      expect(changes.first.payload, contains('"flagged":false'));
    });

    test('moveEmail enqueues move change and removes email from local DB', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      await r.db.into(r.db.emails).insert(EmailsCompanion.insert(
            id: 'acc-1:5',
            accountId: 'acc-1',
            mailboxPath: 'INBOX',
            uid: 5,
            receivedAt: DateTime(2024),
          ));

      await r.emails.moveEmail('acc-1:5', 'Archive');

      final changes = await r.db.select(r.db.pendingChanges).get();
      expect(changes.first.changeType, 'move');
      expect(changes.first.payload, contains('Archive'));
      expect(await r.emails.getEmail('acc-1:5'), isNull);
    });

    test('deleteEmail enqueues delete change and removes email from local DB', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      await r.db.into(r.db.emails).insert(EmailsCompanion.insert(
            id: 'acc-1:5',
            accountId: 'acc-1',
            mailboxPath: 'INBOX',
            uid: 5,
            receivedAt: DateTime(2024),
          ));

      await r.emails.deleteEmail('acc-1:5');

      final changes = await r.db.select(r.db.pendingChanges).get();
      expect(changes.first.changeType, 'delete');
      expect(await r.emails.getEmail('acc-1:5'), isNull);
    });

    test('sendEmail sends via SMTP and appends copy to Sent folder', () async {
      final r = _makeReposWithFakes();
      await r.accounts.addAccount(_account, 'pw');

      await r.emails.sendEmail(
        'acc-1',
        const EmailDraft(
          from: EmailAddress(name: 'Alice', email: 'alice@example.com'),
          to: [EmailAddress(name: 'Bob', email: 'bob@example.com')],
          cc: [],
          subject: 'Hello',
          body: 'Hi Bob',
        ),
      );

      expect(r.fakeSmtp.messageSent, isTrue);
      expect(r.fakeSmtp.quitCalled, isTrue);
      expect(r.fakeImap.appendCalls, 1);
      expect(r.fakeImap.lastAppendMailboxPath, 'Sent');
      expect(r.fakeImap.logoutCalled, isTrue);
    });

    test('searchEmails returns emails matching IMAP search', () async {
      final r = _makeReposWithFakes();
      await r.accounts.addAccount(_account, 'pw');
      r.fakeImap.searchUids = [7, 8];
      r.fakeImap.fetchResults = [
        buildEnvelopeMessage(uid: 7, subject: 'Result A'),
        buildEnvelopeMessage(uid: 8, subject: 'Result B'),
      ];

      final results =
          await r.emails.searchEmails('acc-1', 'INBOX', 'result');

      expect(results, hasLength(2));
      expect(results.map((e) => e.subject).toSet(), {'Result A', 'Result B'});
      expect(r.fakeImap.logoutCalled, isTrue);
    });

    test('searchEmails returns empty list when no UIDs match', () async {
      final r = _makeReposWithFakes();
      await r.accounts.addAccount(_account, 'pw');
      r.fakeImap.searchUids = [];

      final results =
          await r.emails.searchEmails('acc-1', 'INBOX', 'nothing');

      expect(results, isEmpty);
    });

    test('syncEmails skips messages with no envelope or no uid', () async {
      final r = _makeReposWithFakes();
      await r.accounts.addAccount(_account, 'pw');
      r.fakeImap.fetchResults = [
        buildMessageWithoutEnvelope(), // no envelope → skip
        buildEnvelopeMessage(uid: 42, subject: 'Valid'),
      ];

      await r.emails.syncEmails('acc-1', 'INBOX');

      final emails =
          await r.emails.observeEmails('acc-1', 'INBOX').first;
      expect(emails, hasLength(1));
      expect(emails.first.uid, 42);
    });

    // ── Attachment tests ─────────────────────────────────────────────────────

    test('sendEmail with attachment includes it in the SMTP message', () async {
      final r = _makeReposWithFakes();
      await r.accounts.addAccount(_account, 'pw');

      // Create a temp file to attach.
      final tmpFile = File('${r.cacheDir.path}/attach.txt');
      await tmpFile.writeAsBytes(utf8.encode('hello attachment'));

      await r.emails.sendEmail(
        'acc-1',
        EmailDraft(
          from: const EmailAddress(name: 'Alice', email: 'alice@example.com'),
          to: const [EmailAddress(name: 'Bob', email: 'bob@example.com')],
          cc: const [],
          subject: 'With attachment',
          body: 'See attached',
          attachmentFilePaths: [tmpFile.path],
        ),
      );

      expect(r.fakeSmtp.messageSent, isTrue);
      expect(r.fakeSmtp.lastSentMessage?.hasAttachments(), isTrue);
      expect(r.fakeImap.appendCalls, 1);
    });

    test('downloadAttachment fetches part, writes file, returns path', () async {
      final r = _makeReposWithFakes();
      await r.accounts.addAccount(_account, 'pw');
      await r.db.into(r.db.emails).insert(EmailsCompanion.insert(
            id: 'acc-1:1',
            accountId: 'acc-1',
            mailboxPath: 'INBOX',
            uid: 1,
            receivedAt: DateTime(2024),
          ));

      // Multipart message with a text/plain body and one attachment.
      // base64("Hello World") = SGVsbG8gV29ybGQ=
      const rawMsg = 'MIME-Version: 1.0\r\n'
          'From: test@example.com\r\n'
          'To: to@example.com\r\n'
          'Subject: Test\r\n'
          'Content-Type: multipart/mixed; boundary="xyz"\r\n'
          '\r\n'
          '--xyz\r\n'
          'Content-Type: text/plain\r\n'
          '\r\n'
          'Hello\r\n'
          '--xyz\r\n'
          'Content-Type: application/octet-stream\r\n'
          'Content-Disposition: attachment; filename="data.bin"\r\n'
          'Content-Transfer-Encoding: base64\r\n'
          '\r\n'
          'SGVsbG8gV29ybGQ=\r\n'
          '--xyz--\r\n';

      final msg = imap.MimeMessage.parseFromText(rawMsg);
      msg.uid = 1;
      r.fakeImap.fetchResults = [msg];

      // getEmailBody populates attachment metadata (including fetchPartId).
      final body = await r.emails.getEmailBody('acc-1:1');
      expect(body.attachments, hasLength(1));
      expect(body.attachments.first.filename, 'data.bin');
      expect(body.attachments.first.fetchPartId, isNotEmpty);

      // downloadAttachment fetches the part and writes to cache.
      final path =
          await r.emails.downloadAttachment('acc-1:1', body.attachments.first);

      expect(File(path).existsSync(), isTrue);
      expect(File(path).readAsBytesSync(),
          equals(utf8.encode('Hello World')));
      expect(r.fakeImap.logoutCalled, isTrue);
    });

    test('downloadAttachment returns cached file on second call', () async {
      final r = _makeReposWithFakes();
      await r.accounts.addAccount(_account, 'pw');
      await r.db.into(r.db.emails).insert(EmailsCompanion.insert(
            id: 'acc-1:1',
            accountId: 'acc-1',
            mailboxPath: 'INBOX',
            uid: 1,
            receivedAt: DateTime(2024),
          ));

      const rawMsg = 'MIME-Version: 1.0\r\n'
          'From: test@example.com\r\n'
          'To: to@example.com\r\n'
          'Subject: Test\r\n'
          'Content-Type: multipart/mixed; boundary="xyz"\r\n'
          '\r\n'
          '--xyz\r\n'
          'Content-Type: text/plain\r\n'
          '\r\n'
          'Body\r\n'
          '--xyz\r\n'
          'Content-Type: application/octet-stream\r\n'
          'Content-Disposition: attachment; filename="file.bin"\r\n'
          'Content-Transfer-Encoding: base64\r\n'
          '\r\n'
          'dGVzdA==\r\n'
          '--xyz--\r\n';

      final msg = imap.MimeMessage.parseFromText(rawMsg);
      msg.uid = 1;
      r.fakeImap.fetchResults = [msg];

      final body = await r.emails.getEmailBody('acc-1:1');
      final att = body.attachments.first;

      // First download.
      final path1 = await r.emails.downloadAttachment('acc-1:1', att);
      r.fakeImap.logoutCalled = false;

      // Second download — must return same path without IMAP call.
      final path2 = await r.emails.downloadAttachment('acc-1:1', att);
      expect(path2, equals(path1));
      expect(r.fakeImap.logoutCalled, isFalse);
    });
  });

  group('IMAP flushPendingChanges', () {
    Future<void> seedImapChange(
      AppDatabase db,
      AccountRepositoryImpl accounts, {
      String changeType = 'flag_seen',
      String payload = '{"uid":5,"mailboxPath":"INBOX","seen":true}',
    }) async {
      await accounts.addAccount(_account, 'pw');
      await db.into(db.pendingChanges).insert(PendingChangesCompanion.insert(
        accountId: 'acc-1',
        resourceType: 'Email',
        resourceId: 'acc-1:5',
        changeType: changeType,
        payload: payload,
        createdAt: DateTime.now(),
      ));
    }

    test('flag_seen sends uidMarkSeen and removes change', () async {
      final r = _makeReposWithFakes();
      await seedImapChange(r.db, r.accounts);
      await r.emails.flushPendingChanges('acc-1', 'pw');
      expect(r.fakeImap.markSeenCalls, 1);
      expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);
      expect(r.fakeImap.logoutCalled, isTrue);
    });

    test('flag_seen false sends uidMarkUnseen and removes change', () async {
      final r = _makeReposWithFakes();
      await seedImapChange(r.db, r.accounts,
          payload: '{"uid":5,"mailboxPath":"INBOX","seen":false}');
      await r.emails.flushPendingChanges('acc-1', 'pw');
      expect(r.fakeImap.markUnseenCalls, 1);
      expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);
    });

    test('flag_flagged sends uidMarkFlagged and removes change', () async {
      final r = _makeReposWithFakes();
      await seedImapChange(r.db, r.accounts,
          changeType: 'flag_flagged',
          payload: '{"uid":5,"mailboxPath":"INBOX","flagged":true}');
      await r.emails.flushPendingChanges('acc-1', 'pw');
      expect(r.fakeImap.markFlaggedCalls, 1);
      expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);
    });

    test('flag_flagged false sends uidMarkUnflagged', () async {
      final r = _makeReposWithFakes();
      await seedImapChange(r.db, r.accounts,
          changeType: 'flag_flagged',
          payload: '{"uid":5,"mailboxPath":"INBOX","flagged":false}');
      await r.emails.flushPendingChanges('acc-1', 'pw');
      expect(r.fakeImap.markUnflaggedCalls, 1);
    });

    test('move sends uidMove and removes change', () async {
      final r = _makeReposWithFakes();
      await seedImapChange(r.db, r.accounts,
          changeType: 'move',
          payload: '{"uid":5,"mailboxPath":"INBOX","dest":"Archive"}');
      await r.emails.flushPendingChanges('acc-1', 'pw');
      expect(r.fakeImap.moveEmailCalls, 1);
      expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);
    });

    test('delete sends uidMarkDeleted + uidExpunge and removes change', () async {
      final r = _makeReposWithFakes();
      await seedImapChange(r.db, r.accounts,
          changeType: 'delete',
          payload: '{"uid":5,"mailboxPath":"INBOX"}');
      await r.emails.flushPendingChanges('acc-1', 'pw');
      expect(r.fakeImap.markDeletedCalls, 1);
      expect(r.fakeImap.expungeCalls, 1);
      expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);
    });

    test('records attempt and error when IMAP throws', () async {
      final r = _makeRepos();
      // _makeRepos uses _noImapConnect which throws UnsupportedError
      await r.accounts.addAccount(_account, 'pw');
      await r.db.into(r.db.pendingChanges).insert(PendingChangesCompanion.insert(
        accountId: 'acc-1',
        resourceType: 'Email',
        resourceId: 'acc-1:5',
        changeType: 'flag_seen',
        payload: '{"uid":5,"mailboxPath":"INBOX","seen":true}',
        createdAt: DateTime.now(),
      ));
      await r.emails.flushPendingChanges('acc-1', 'pw');
      final changes = await r.db.select(r.db.pendingChanges).get();
      expect(changes, hasLength(1));
      expect(changes.first.attempts, 1);
      expect(changes.first.lastError, isNotNull);
    });
  });

  group('JMAP syncEmails', () {
    test('full sync upserts emails and persists state', () async {
      final r = _makeRepos(
        httpClient: _mockJmapEmails(apiResponses: [
          _emailGetResponse(state: 'est1', list: [
            _jmapEmail(id: 'e1', mailboxId: 'mbx1', subject: 'First'),
            _jmapEmail(id: 'e2', mailboxId: 'mbx1', subject: 'Second', seen: true),
          ]),
        ]),
      );
      await r.accounts.addAccount(_jmapAccount, 'pw');
      await r.emails.syncEmails('jmap-1', 'mbx1');

      final emails = await r.emails.observeEmails('jmap-1', 'mbx1').first;
      expect(emails, hasLength(2));
      expect(emails.map((e) => e.subject).toSet(), {'First', 'Second'});
      expect(emails.firstWhere((e) => e.subject == 'Second').isSeen, isTrue);

      final states = await r.db.select(r.db.syncStates).get();
      expect(states, hasLength(1));
      expect(states.first.state, 'est1');
    });

    test('incremental sync applies created, updated, destroyed', () async {
      final r = _makeRepos(
        httpClient: _mockJmapEmails(apiResponses: [
          // Call 1: Email/changes
          _emailChangesResponse(
            oldState: 'est1', newState: 'est2',
            created: ['e3'], updated: ['e1'], destroyed: ['e2'],
          ),
          // Call 2: Email/get for created + updated
          _emailGetOnly(state: 'est2', list: [
            _jmapEmail(id: 'e1', mailboxId: 'mbx1', subject: 'First updated'),
            _jmapEmail(id: 'e3', mailboxId: 'mbx1', subject: 'Third'),
          ]),
        ]),
      );
      await r.accounts.addAccount(_jmapAccount, 'pw');

      // Pre-populate
      await r.db.into(r.db.emails).insertOnConflictUpdate(EmailsCompanion.insert(
        id: 'jmap-1:e1', accountId: 'jmap-1', mailboxPath: 'mbx1', uid: 0,
        subject: const Value('First'), receivedAt: DateTime(2024),
      ));
      await r.db.into(r.db.emails).insertOnConflictUpdate(EmailsCompanion.insert(
        id: 'jmap-1:e2', accountId: 'jmap-1', mailboxPath: 'mbx1', uid: 0,
        subject: const Value('Second'), receivedAt: DateTime(2024),
      ));
      await r.db.into(r.db.syncStates).insertOnConflictUpdate(SyncStatesCompanion.insert(
        accountId: 'jmap-1', resourceType: 'Email',
        state: 'est1', syncedAt: DateTime.now(),
      ));

      await r.emails.syncEmails('jmap-1', 'mbx1');

      final emails = await r.emails.observeEmails('jmap-1', 'mbx1').first;
      expect(emails.map((e) => e.subject).toSet(), {'First updated', 'Third'});

      final states = await r.db.select(r.db.syncStates).get();
      expect(states.first.state, 'est2');
    });

    test('incremental sync with no changes updates state only', () async {
      final r = _makeRepos(
        httpClient: _mockJmapEmails(apiResponses: [
          _emailChangesResponse(oldState: 'est1', newState: 'est1'),
        ]),
      );
      await r.accounts.addAccount(_jmapAccount, 'pw');
      await r.db.into(r.db.syncStates).insertOnConflictUpdate(SyncStatesCompanion.insert(
        accountId: 'jmap-1', resourceType: 'Email',
        state: 'est1', syncedAt: DateTime.now(),
      ));

      await r.emails.syncEmails('jmap-1', 'mbx1');

      final states = await r.db.select(r.db.syncStates).get();
      expect(states.first.state, 'est1');
    });
  });

  group('JMAP setFlag / moveEmail / deleteEmail enqueue pending_changes', () {
    Future<void> seedJmapEmail(
        AppDatabase db, AccountRepositoryImpl accounts) async {
      await accounts.addAccount(_jmapAccount, 'pw');
      await db.into(db.emails).insert(EmailsCompanion.insert(
        id: 'jmap-1:e1',
        accountId: 'jmap-1',
        mailboxPath: 'mbx1',
        uid: 0,
        receivedAt: DateTime(2024),
      ));
    }

    test('setFlag seen enqueues flag_seen change and updates local DB', () async {
      final r = _makeRepos();
      await seedJmapEmail(r.db, r.accounts);

      await r.emails.setFlag('jmap-1:e1', seen: true);

      final changes = await r.db.select(r.db.pendingChanges).get();
      expect(changes, hasLength(1));
      expect(changes.first.changeType, 'flag_seen');
      expect(changes.first.payload, contains('true'));

      final email = await r.emails.getEmail('jmap-1:e1');
      expect(email?.isSeen, isTrue);
    });

    test('setFlag flagged enqueues flag_flagged change', () async {
      final r = _makeRepos();
      await seedJmapEmail(r.db, r.accounts);

      await r.emails.setFlag('jmap-1:e1', flagged: true);

      final changes = await r.db.select(r.db.pendingChanges).get();
      expect(changes.first.changeType, 'flag_flagged');
    });

    test('moveEmail enqueues move change and removes email from local DB', () async {
      final r = _makeRepos();
      await seedJmapEmail(r.db, r.accounts);

      await r.emails.moveEmail('jmap-1:e1', 'mbx2');

      final changes = await r.db.select(r.db.pendingChanges).get();
      expect(changes.first.changeType, 'move');
      expect(changes.first.payload, contains('mbx2'));

      expect(await r.emails.getEmail('jmap-1:e1'), isNull);
    });

    test('deleteEmail enqueues delete change and removes email from local DB', () async {
      final r = _makeRepos();
      await seedJmapEmail(r.db, r.accounts);

      await r.emails.deleteEmail('jmap-1:e1');

      final changes = await r.db.select(r.db.pendingChanges).get();
      expect(changes.first.changeType, 'delete');
      expect(await r.emails.getEmail('jmap-1:e1'), isNull);
    });
  });

  group('JMAP flushPendingChanges', () {
    http.Client mockFlush(int apiStatus) {
      return MockClient((req) async {
        if (req.url.path.contains('well-known')) {
          return http.Response(
            jsonEncode({
              'apiUrl': 'https://jmap.example.com/api/',
              'accounts': {'acct1': {'name': 'alice@example.com', 'isPersonal': true}},
              'primaryAccounts': {
                'urn:ietf:params:jmap:core': 'acct1',
                'urn:ietf:params:jmap:mail': 'acct1',
              },
              'capabilities': {},
              'username': 'alice@example.com',
              'state': 'sess1',
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({'sessionState': 's1', 'methodResponses': [
            ['Email/set', {'accountId': 'acct1', 'updated': {}, 'destroyed': []}, '0'],
          ]}),
          apiStatus,
        );
      });
    }

    Future<void> seedChange(AppDatabase db, AccountRepositoryImpl accounts,
        {String changeType = 'flag_seen', String payload = '{"seen":true}'}) async {
      await accounts.addAccount(_jmapAccount, 'pw');
      await db.into(db.pendingChanges).insert(PendingChangesCompanion.insert(
        accountId: 'jmap-1',
        resourceType: 'Email',
        resourceId: 'jmap-1:e1',
        changeType: changeType,
        payload: payload,
        createdAt: DateTime.now(),
      ));
    }

    test('no-op when no pending changes', () async {
      final r = _makeRepos(httpClient: mockFlush(200));
      await r.accounts.addAccount(_jmapAccount, 'pw');
      await r.emails.flushPendingChanges('jmap-1', 'pw');
      expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);
    });

    test('sends flag_seen and removes change on success', () async {
      final r = _makeRepos(httpClient: mockFlush(200));
      await seedChange(r.db, r.accounts);

      await r.emails.flushPendingChanges('jmap-1', 'pw');

      expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);
    });

    test('sends flag_flagged and removes change on success', () async {
      final r = _makeRepos(httpClient: mockFlush(200));
      await seedChange(r.db, r.accounts,
          changeType: 'flag_flagged', payload: '{"flagged":true}');

      await r.emails.flushPendingChanges('jmap-1', 'pw');

      expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);
    });

    test('sends move and removes change on success', () async {
      final r = _makeRepos(httpClient: mockFlush(200));
      await seedChange(r.db, r.accounts,
          changeType: 'move', payload: '{"dest":"mbx2"}');

      await r.emails.flushPendingChanges('jmap-1', 'pw');

      expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);
    });

    test('sends delete and removes change on success', () async {
      final r = _makeRepos(httpClient: mockFlush(200));
      await seedChange(r.db, r.accounts,
          changeType: 'delete', payload: '{}');

      await r.emails.flushPendingChanges('jmap-1', 'pw');

      expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);
    });

    test('records attempt count and error on API failure', () async {
      final r = _makeRepos(httpClient: mockFlush(500));
      await seedChange(r.db, r.accounts);

      await r.emails.flushPendingChanges('jmap-1', 'pw');

      final changes = await r.db.select(r.db.pendingChanges).get();
      expect(changes, hasLength(1));
      expect(changes.first.attempts, 1);
      expect(changes.first.lastError, isNotNull);
    });
  });
}
