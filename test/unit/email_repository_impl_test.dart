import 'dart:async';
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
import 'package:sharedinbox/data/jmap/jmap_client.dart';
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

Map<String, dynamic> _emailGetResponse({
  required String state,
  required List<Map<String, dynamic>> list,
  int? total,
}) =>
    {
      'sessionState': 'sess1',
      'methodResponses': [
        [
          'Email/query',
          {
            'accountId': 'acct1',
            'ids': list.map((e) => e['id']).toList(),
            'total': total ?? list.length,
          },
          '0'
        ],
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
              cachedAt: Value(DateTime.now()),
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

    test('syncEmails saves IMAP checkpoint after full sync', () async {
      final r = _makeReposWithFakes();
      await r.accounts.addAccount(_account, 'pw');
      r.fakeImap.uidValidityResult = 1000;
      r.fakeImap.fetchResults = [
        buildEnvelopeMessage(uid: 10, subject: 'First'),
        buildEnvelopeMessage(uid: 20, subject: 'Second'),
      ];

      await r.emails.syncEmails('acc-1', 'INBOX');

      final states = await r.db.select(r.db.syncStates).get();
      expect(states, hasLength(1));
      final checkpoint =
          jsonDecode(states.first.state) as Map<String, dynamic>;
      expect(checkpoint['uidValidity'], 1000);
      expect(checkpoint['lastUid'], 20);
    });

    test('syncEmails incremental sync fetches only messages newer than checkpoint',
        () async {
      final r = _makeReposWithFakes();
      await r.accounts.addAccount(_account, 'pw');
      r.fakeImap.uidValidityResult = 1000;
      await r.db.into(r.db.syncStates).insertOnConflictUpdate(
            SyncStatesCompanion.insert(
              accountId: 'acc-1',
              resourceType: 'IMAP:INBOX',
              state: jsonEncode({'uidValidity': 1000, 'lastUid': 10}),
              syncedAt: DateTime.now(),
            ),
          );
      await r.db.into(r.db.emails).insert(EmailsCompanion.insert(
            id: 'acc-1:10',
            accountId: 'acc-1',
            mailboxPath: 'INBOX',
            uid: 10,
            receivedAt: DateTime(2024),
          ));
      // Call 1 (UID 11:*): returns uid 20; call 2 (ALL): returns [10, 20]
      r.fakeImap.searchCallQueue = [
        [20],
        [10, 20]
      ];
      r.fakeImap.fetchResults = [buildEnvelopeMessage(uid: 20, subject: 'New')];

      await r.emails.syncEmails('acc-1', 'INBOX');

      final emails =
          await r.emails.observeEmails('acc-1', 'INBOX').first;
      expect(emails.map((e) => e.uid).toSet(), {10, 20});
      final state = jsonDecode(
              (await r.db.select(r.db.syncStates).get()).first.state)
          as Map<String, dynamic>;
      expect(state['lastUid'], 20);
    });

    test('syncEmails reconciliation removes emails deleted on server', () async {
      final r = _makeReposWithFakes();
      await r.accounts.addAccount(_account, 'pw');
      r.fakeImap.uidValidityResult = 1000;
      await r.db.into(r.db.syncStates).insertOnConflictUpdate(
            SyncStatesCompanion.insert(
              accountId: 'acc-1',
              resourceType: 'IMAP:INBOX',
              state: jsonEncode({'uidValidity': 1000, 'lastUid': 20}),
              syncedAt: DateTime.now(),
            ),
          );
      for (final uid in [10, 20]) {
        await r.db.into(r.db.emails).insert(EmailsCompanion.insert(
              id: 'acc-1:$uid',
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              uid: uid,
              receivedAt: DateTime(2024),
            ));
      }
      // No new UIDs; server only has uid=10 (uid=20 was deleted)
      r.fakeImap.searchCallQueue = [[], [10]];

      await r.emails.syncEmails('acc-1', 'INBOX');

      final emails =
          await r.emails.observeEmails('acc-1', 'INBOX').first;
      expect(emails, hasLength(1));
      expect(emails.first.uid, 10);
    });

    test('syncEmails full re-sync when UID validity changes', () async {
      final r = _makeReposWithFakes();
      await r.accounts.addAccount(_account, 'pw');
      r.fakeImap.uidValidityResult = 9999;
      await r.db.into(r.db.syncStates).insertOnConflictUpdate(
            SyncStatesCompanion.insert(
              accountId: 'acc-1',
              resourceType: 'IMAP:INBOX',
              state: jsonEncode({'uidValidity': 1000, 'lastUid': 50}),
              syncedAt: DateTime.now(),
            ),
          );
      await r.db.into(r.db.emails).insert(EmailsCompanion.insert(
            id: 'acc-1:50',
            accountId: 'acc-1',
            mailboxPath: 'INBOX',
            uid: 50,
            receivedAt: DateTime(2024),
          ));
      r.fakeImap.fetchResults = [
        buildEnvelopeMessage(uid: 1, subject: 'Fresh start'),
      ];

      await r.emails.syncEmails('acc-1', 'INBOX');

      final emails =
          await r.emails.observeEmails('acc-1', 'INBOX').first;
      expect(emails, hasLength(1));
      expect(emails.first.uid, 1);
      final state = jsonDecode(
              (await r.db.select(r.db.syncStates).get()).first.state)
          as Map<String, dynamic>;
      expect(state['uidValidity'], 9999);
      expect(state['lastUid'], 1);
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

    test('evicts IMAP change after max attempts (5)', () async {
      final r = _makeReposWithFakes();
      await r.accounts.addAccount(_account, 'pw');
      // Pre-seed a flag_seen at attempts=4
      await r.db.into(r.db.pendingChanges).insert(PendingChangesCompanion.insert(
        accountId: _account.id,
        resourceType: 'Email',
        resourceId: '${_account.id}:1',
        changeType: 'flag_seen',
        payload: '{"uid":1,"mailboxPath":"INBOX","seen":true}',
        createdAt: DateTime.now(),
        attempts: const Value(4),
      ));

      // Force connection failure so the attempt counter increments
      final failingEmails = EmailRepositoryImpl(
        r.db,
        r.accounts,
        imapConnect: (_, __, ___) => Future.error(Exception('forced failure')),
        smtpConnect: _noSmtpConnect,
      );

      await failingEmails.flushPendingChanges(_account.id, 'pw');

      // 4+1 = 5 = _maxChangeAttempts → evicted
      expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);
    });
  });

  group('JMAP getEmailBody', () {
    http.Client mockBodyClient({
      String text = 'Hello from JMAP',
      String html = '<p>Hello from JMAP</p>',
    }) =>
        MockClient((req) async {
          if (req.url.path.contains('well-known')) {
            return http.Response(
              jsonEncode({
                'apiUrl': 'https://jmap.example.com/api/',
                'accounts': {
                  'acct1': {'name': 'alice@example.com', 'isPersonal': true}
                },
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
            jsonEncode({
              'sessionState': 'sess1',
              'methodResponses': [
                [
                  'Email/get',
                  {
                    'accountId': 'acct1',
                    'state': 'es1',
                    'list': [
                      {
                        'id': 'e1',
                        'textBody': [
                          {'partId': '1', 'type': 'text/plain'}
                        ],
                        'htmlBody': [
                          {'partId': '2', 'type': 'text/html'}
                        ],
                        'bodyValues': {
                          '1': {'value': text, 'isTruncated': false},
                          '2': {'value': html, 'isTruncated': false},
                        },
                        'attachments': [],
                      }
                    ],
                  },
                  '0',
                ]
              ],
            }),
            200,
          );
        });

    test('fetches body via JMAP Email/get and caches it', () async {
      final r = _makeRepos(httpClient: mockBodyClient());
      await r.accounts.addAccount(_jmapAccount, 'pw');
      await r.db.into(r.db.emails).insert(EmailsCompanion.insert(
            id: 'jmap-1:e1',
            accountId: 'jmap-1',
            mailboxPath: 'mbx1',
            uid: 0,
            receivedAt: DateTime(2024),
          ));

      final body = await r.emails.getEmailBody('jmap-1:e1');

      expect(body.textBody, 'Hello from JMAP');
      expect(body.htmlBody, '<p>Hello from JMAP</p>');

      // Second call should return cached body without HTTP call.
      final cached = await r.emails.getEmailBody('jmap-1:e1');
      expect(cached.textBody, body.textBody);
    });

    test('returns empty body when bodyValues is absent', () async {
      final r = _makeRepos(
        httpClient: MockClient((req) async {
          if (req.url.path.contains('well-known')) {
            return http.Response(
              jsonEncode({
                'apiUrl': 'https://jmap.example.com/api/',
                'accounts': {
                  'acct1': {'name': 'alice@example.com', 'isPersonal': true}
                },
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
            jsonEncode({
              'sessionState': 'sess1',
              'methodResponses': [
                [
                  'Email/get',
                  {
                    'accountId': 'acct1',
                    'state': 'es1',
                    'list': [
                      {
                        'id': 'e1',
                        'textBody': [],
                        'htmlBody': [],
                        'bodyValues': <String, dynamic>{},
                        'attachments': [],
                      }
                    ],
                  },
                  '0',
                ]
              ],
            }),
            200,
          );
        }),
      );
      await r.accounts.addAccount(_jmapAccount, 'pw');
      await r.db.into(r.db.emails).insert(EmailsCompanion.insert(
            id: 'jmap-1:e1',
            accountId: 'jmap-1',
            mailboxPath: 'mbx1',
            uid: 0,
            receivedAt: DateTime(2024),
          ));

      final body = await r.emails.getEmailBody('jmap-1:e1');
      expect(body.textBody, isNull);
      expect(body.htmlBody, isNull);
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

    test('full sync paginates when total exceeds page size', () async {
      final page1 = [
        _jmapEmail(id: 'e1', mailboxId: 'mbx1', subject: 'Page1-A'),
        _jmapEmail(id: 'e2', mailboxId: 'mbx1', subject: 'Page1-B'),
      ];
      final page2 = [
        _jmapEmail(id: 'e3', mailboxId: 'mbx1', subject: 'Page2-A'),
        _jmapEmail(id: 'e4', mailboxId: 'mbx1', subject: 'Page2-B'),
      ];
      final r = _makeRepos(
        httpClient: _mockJmapEmails(apiResponses: [
          _emailGetResponse(state: 'est1', list: page1, total: 4),
          _emailGetResponse(state: 'est1', list: page2, total: 4),
        ]),
      );
      await r.accounts.addAccount(_jmapAccount, 'pw');
      await r.emails.syncEmails('jmap-1', 'mbx1');

      final emails = await r.emails.observeEmails('jmap-1', 'mbx1').first;
      expect(emails, hasLength(4));
      expect(emails.map((e) => e.subject).toSet(),
          {'Page1-A', 'Page1-B', 'Page2-A', 'Page2-B'});

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

    test('passes ifInState when sync_state exists', () async {
      late Map<String, dynamic> capturedBody;
      final client = MockClient((req) async {
        if (req.url.path.contains('well-known')) {
          return http.Response(
            jsonEncode({
              'apiUrl': 'https://jmap.example.com/api/',
              'accounts': {'acct1': {}},
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
        capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({'sessionState': 's1', 'methodResponses': [
            ['Email/set', {'accountId': 'acct1', 'newState': 'est2', 'updated': {}}, '0'],
          ]}),
          200,
        );
      });

      final r = _makeRepos(httpClient: client);
      await r.accounts.addAccount(_jmapAccount, 'pw');
      await r.db.into(r.db.syncStates).insertOnConflictUpdate(SyncStatesCompanion.insert(
        accountId: 'jmap-1', resourceType: 'Email',
        state: 'est1', syncedAt: DateTime.now(),
      ));
      await r.db.into(r.db.pendingChanges).insert(PendingChangesCompanion.insert(
        accountId: 'jmap-1', resourceType: 'Email', resourceId: 'jmap-1:e1',
        changeType: 'flag_seen', payload: '{"seen":true}', createdAt: DateTime.now(),
      ));

      await r.emails.flushPendingChanges('jmap-1', 'pw');

      final firstCall = (capturedBody['methodCalls'] as List<dynamic>).first as List<dynamic>;
      final args = firstCall[1] as Map<String, dynamic>;
      expect(args['ifInState'], 'est1');

      // newState returned by server should update our checkpoint
      final states = await r.db.select(r.db.syncStates).get();
      expect(states.first.state, 'est2');
    });

    test('stateMismatch clears sync state and marks change as failed', () async {
      final client = MockClient((req) async {
        if (req.url.path.contains('well-known')) {
          return http.Response(
            jsonEncode({
              'apiUrl': 'https://jmap.example.com/api/',
              'accounts': {'acct1': {}},
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
        // Server responds with stateMismatch error inside Email/set
        return http.Response(
          jsonEncode({'sessionState': 's1', 'methodResponses': [
            ['Email/set', {'accountId': 'acct1', 'type': 'stateMismatch'}, '0'],
          ]}),
          200,
        );
      });

      final r = _makeRepos(httpClient: client);
      await r.accounts.addAccount(_jmapAccount, 'pw');
      await r.db.into(r.db.syncStates).insertOnConflictUpdate(SyncStatesCompanion.insert(
        accountId: 'jmap-1', resourceType: 'Email',
        state: 'est1', syncedAt: DateTime.now(),
      ));
      await r.db.into(r.db.pendingChanges).insert(PendingChangesCompanion.insert(
        accountId: 'jmap-1', resourceType: 'Email', resourceId: 'jmap-1:e1',
        changeType: 'flag_seen', payload: '{"seen":true}', createdAt: DateTime.now(),
      ));

      await r.emails.flushPendingChanges('jmap-1', 'pw');

      // Sync state should be cleared so next cycle does a full re-sync
      expect(await r.db.select(r.db.syncStates).get(), isEmpty);

      // Change should still be present but with attempt count bumped
      final changes = await r.db.select(r.db.pendingChanges).get();
      expect(changes.first.attempts, 1);
    });

    test('discards change immediately on notUpdated (permanent error)', () async {
      final client = MockClient((req) async {
        if (req.url.path.contains('well-known')) {
          return http.Response(
            jsonEncode({
              'apiUrl': 'https://jmap.example.com/api/',
              'accounts': {'acct1': {}},
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
        // Server responds with notUpdated — permanent per-item error
        return http.Response(
          jsonEncode({'sessionState': 's1', 'methodResponses': [
            ['Email/set', {
              'accountId': 'acct1',
              'notUpdated': {'e1': {'type': 'notFound'}},
            }, '0'],
          ]}),
          200,
        );
      });

      final r = _makeRepos(httpClient: client);
      await r.accounts.addAccount(_jmapAccount, 'pw');
      await r.db.into(r.db.pendingChanges).insert(PendingChangesCompanion.insert(
        accountId: 'jmap-1', resourceType: 'Email', resourceId: 'jmap-1:e1',
        changeType: 'flag_seen', payload: '{"seen":true}', createdAt: DateTime.now(),
      ));

      await r.emails.flushPendingChanges('jmap-1', 'pw');

      // Permanent error — change is immediately evicted
      expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);
    });

    test('evicts change after max attempts (5)', () async {
      final r = _makeRepos(httpClient: mockFlush(500));
      await r.accounts.addAccount(_jmapAccount, 'pw');
      // Seed a change already at attempts=4 (one below the eviction threshold)
      await r.db.into(r.db.pendingChanges).insert(PendingChangesCompanion.insert(
        accountId: 'jmap-1', resourceType: 'Email', resourceId: 'jmap-1:e1',
        changeType: 'flag_seen', payload: '{"seen":true}', createdAt: DateTime.now(),
        attempts: const Value(4),
      ));

      await r.emails.flushPendingChanges('jmap-1', 'pw');

      // 4+1 = 5 = _maxChangeAttempts → evicted
      expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);
    });
  });

  group('JMAP syncEmails body caching', () {
    Map<String, dynamic> jmapEmailWithBody({
      required String id,
      required String mailboxId,
      String? textContent,
      String? htmlContent,
    }) =>
        {
          ..._jmapEmail(id: id, mailboxId: mailboxId),
          'textBody': [if (textContent != null) {'partId': 'text1', 'type': 'text/plain'}],
          'htmlBody': [if (htmlContent != null) {'partId': 'html1', 'type': 'text/html'}],
          'bodyValues': {
            if (textContent != null) 'text1': {'value': textContent, 'isEncodingProblem': false, 'isTruncated': false},
            if (htmlContent != null) 'html1': {'value': htmlContent, 'isEncodingProblem': false, 'isTruncated': false},
          },
          'attachments': [],
        };

    test('full sync caches bodies when bodyValues are present', () async {
      final r = _makeRepos(
        httpClient: _mockJmapEmails(apiResponses: [
          _emailGetResponse(state: 'est1', list: [
            jmapEmailWithBody(id: 'e1', mailboxId: 'mbx1',
                textContent: 'Hello text', htmlContent: '<p>Hello</p>'),
          ]),
        ]),
      );
      await r.accounts.addAccount(_jmapAccount, 'pw');
      await r.emails.syncEmails('jmap-1', 'mbx1');

      final bodies = await r.db.select(r.db.emailBodies).get();
      expect(bodies, hasLength(1));
      expect(bodies.first.textBody, 'Hello text');
      expect(bodies.first.htmlBody, '<p>Hello</p>');
    });

    test('full sync does not write body row when bodyValues absent', () async {
      final r = _makeRepos(
        httpClient: _mockJmapEmails(apiResponses: [
          _emailGetResponse(state: 'est1', list: [
            _jmapEmail(id: 'e1', mailboxId: 'mbx1'),
          ]),
        ]),
      );
      await r.accounts.addAccount(_jmapAccount, 'pw');
      await r.emails.syncEmails('jmap-1', 'mbx1');

      final bodies = await r.db.select(r.db.emailBodies).get();
      expect(bodies, isEmpty);
    });
  });

  group('JMAP sendEmail', () {
    http.Client mockSend({
      int sessionStatus = 200,
      int apiStatus = 200,
      Map<String, dynamic>? emailSetResult,
      Map<String, dynamic>? submissionResult,
    }) {
      return MockClient((req) async {
        if (req.url.path.contains('well-known')) {
          return http.Response(
            jsonEncode({
              'apiUrl': 'https://jmap.example.com/api/',
              'accounts': {'acct1': {}},
              'primaryAccounts': {
                'urn:ietf:params:jmap:core': 'acct1',
                'urn:ietf:params:jmap:mail': 'acct1',
              },
              'capabilities': {
                'urn:ietf:params:jmap:core': {},
                'urn:ietf:params:jmap:mail': {},
                'urn:ietf:params:jmap:submission': {},
              },
              'username': 'alice@example.com',
              'state': 'sess1',
            }),
            sessionStatus,
          );
        }
        return http.Response(
          jsonEncode({
            'sessionState': 's1',
            'methodResponses': [
              [
                'Email/set',
                emailSetResult ??
                    {
                      'accountId': 'acct1',
                      'newState': 'est2',
                      'created': {'em1': {'id': 'newEmailId1'}},
                    },
                '0',
              ],
              [
                'EmailSubmission/set',
                submissionResult ??
                    {
                      'accountId': 'acct1',
                      'created': {'sub1': {'id': 'subId1'}},
                    },
                '1',
              ],
            ],
          }),
          apiStatus,
        );
      });
    }

    const draft = EmailDraft(
      from: EmailAddress(name: 'Alice', email: 'alice@example.com'),
      to: [EmailAddress(name: 'Bob', email: 'bob@example.com')],
      cc: [],
      subject: 'Hello',
      body: 'World',
    );

    test('sends email via EmailSubmission/set for JMAP accounts', () async {
      final r = _makeRepos(httpClient: mockSend());
      await r.accounts.addAccount(_jmapAccount, 'pw');

      await r.emails.sendEmail('jmap-1', draft);
      // No exception = success; IMAP connections are not opened
    });

    test('throws when Email/set reports notCreated', () async {
      final r = _makeRepos(
        httpClient: mockSend(
          emailSetResult: {
            'accountId': 'acct1',
            'notCreated': {'em1': {'type': 'invalidProperties'}},
          },
        ),
      );
      await r.accounts.addAccount(_jmapAccount, 'pw');

      await expectLater(
        r.emails.sendEmail('jmap-1', draft),
        throwsA(isA<JmapException>()),
      );
    });

    test('throws when EmailSubmission/set reports notCreated', () async {
      final r = _makeRepos(
        httpClient: mockSend(
          submissionResult: {
            'accountId': 'acct1',
            'notCreated': {'sub1': {'type': 'invalidRecipients'}},
          },
        ),
      );
      await r.accounts.addAccount(_jmapAccount, 'pw');

      await expectLater(
        r.emails.sendEmail('jmap-1', draft),
        throwsA(isA<JmapException>()),
      );
    });

    test('uses Sent mailbox ID when role=sent mailbox exists in DB', () async {
      late Map<String, dynamic> capturedBody;
      final client = MockClient((req) async {
        if (req.url.path.contains('well-known')) {
          return http.Response(
            jsonEncode({
              'apiUrl': 'https://jmap.example.com/api/',
              'accounts': {'acct1': {}},
              'primaryAccounts': {
                'urn:ietf:params:jmap:core': 'acct1',
                'urn:ietf:params:jmap:mail': 'acct1',
              },
              'capabilities': {
                'urn:ietf:params:jmap:core': {},
                'urn:ietf:params:jmap:mail': {},
                'urn:ietf:params:jmap:submission': {},
              },
              'username': 'alice@example.com',
              'state': 'sess1',
            }),
            200,
          );
        }
        capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'sessionState': 's1',
            'methodResponses': [
              ['Email/set', {'accountId': 'acct1', 'newState': 'est2',
                'created': {'em1': {'id': 'newId'}}}, '0'],
              ['EmailSubmission/set', {'accountId': 'acct1',
                'created': {'sub1': {'id': 'subId'}}}, '1'],
            ],
          }),
          200,
        );
      });

      final r = _makeRepos(httpClient: client);
      await r.accounts.addAccount(_jmapAccount, 'pw');
      // Seed a Sent mailbox with role='sent'
      await r.db.into(r.db.mailboxes).insert(MailboxesCompanion.insert(
        id: 'jmap-1:sentMbx', accountId: 'jmap-1',
        path: 'sentMbxJmapId', name: 'Sent',
        role: const Value('sent'),
      ));

      await r.emails.sendEmail('jmap-1', draft);

      final calls = capturedBody['methodCalls'] as List<dynamic>;
      final emailSetArgs = (calls.first as List<dynamic>)[1] as Map<String, dynamic>;
      final createMap = emailSetArgs['create'] as Map<String, dynamic>;
      final em1Create = createMap['em1'] as Map<String, dynamic>;
      expect(em1Create['mailboxIds'], {'sentMbxJmapId': true});
    });
  });

  group('JMAP watchJmapPush', () {
    // A custom BaseClient that serves session JSON for well-known requests
    // and an SSE stream for all other GET requests.
    http.Client makeSseClient({
      String? eventSourceUrl,
      Stream<List<int>>? sseStream,
    }) {
      return _SseTestClient(
        eventSourceUrl: eventSourceUrl,
        sseStream: sseStream ?? const Stream.empty(),
      );
    }

    test('returns empty stream when server has no eventSourceUrl', () async {
      final r = _makeRepos(httpClient: makeSseClient());
      await r.accounts.addAccount(_jmapAccount, 'pw');

      final events = await r.emails.watchJmapPush('jmap-1', 'pw').toList();
      expect(events, isEmpty);
    });

    test('yields on StateChange event', () async {
      final sseController = StreamController<List<int>>();
      final r = _makeRepos(
        httpClient: makeSseClient(
          eventSourceUrl: 'https://jmap.example.com/events/',
          sseStream: sseController.stream,
        ),
      );
      await r.accounts.addAccount(_jmapAccount, 'pw');

      final emitted = <void>[];
      final sub = r.emails
          .watchJmapPush('jmap-1', 'pw')
          .listen(emitted.add);

      // Push a StateChange event
      const event = 'data: {"@type":"StateChange","changed":{}}\n\n';
      sseController.add(utf8.encode(event));

      await Future.delayed(const Duration(milliseconds: 50));
      expect(emitted, hasLength(1));

      await sub.cancel();
      await sseController.close();
    });

    test('ignores non-StateChange SSE data lines', () async {
      final sseController = StreamController<List<int>>();
      final r = _makeRepos(
        httpClient: makeSseClient(
          eventSourceUrl: 'https://jmap.example.com/events/',
          sseStream: sseController.stream,
        ),
      );
      await r.accounts.addAccount(_jmapAccount, 'pw');

      final emitted = <void>[];
      final sub = r.emails
          .watchJmapPush('jmap-1', 'pw')
          .listen(emitted.add);

      const keepalive = ': keepalive\n\n';
      const other = 'data: {"@type":"Something"}\n\n';
      sseController.add(utf8.encode(keepalive + other));

      await Future.delayed(const Duration(milliseconds: 50));
      expect(emitted, isEmpty);

      await sub.cancel();
      await sseController.close();
    });
  });

  // ── CONDSTORE tests ──────────────────────────────────────────────────────────

  group('CONDSTORE', () {
    test('fast-path: skips search/fetch when modseq is unchanged', () async {
      final r = _makeReposWithFakes();
      await r.accounts.addAccount(_account, 'pw');
      r.fakeImap.uidValidityResult = 1000;
      r.fakeImap.highestModSequenceResult = 42;
      await r.db.into(r.db.syncStates).insertOnConflictUpdate(
            SyncStatesCompanion.insert(
              accountId: 'acc-1',
              resourceType: 'IMAP:INBOX',
              state: jsonEncode(
                  {'uidValidity': 1000, 'lastUid': 5, 'highestModSeq': 42}),
              syncedAt: DateTime.now(),
            ),
          );

      await r.emails.syncEmails('acc-1', 'INBOX');

      // No search or fetch calls because modseq is unchanged.
      expect(r.fakeImap.uidFetchMessagesCalls, 0);
      expect(r.fakeImap.logoutCalled, isTrue);
    });

    test('flag refresh: calls uidFetchMessages with changedSince when modseq changes',
        () async {
      final r = _makeReposWithFakes();
      await r.accounts.addAccount(_account, 'pw');
      r.fakeImap.uidValidityResult = 1000;
      r.fakeImap.highestModSequenceResult = 55; // server advanced from 42 → 55
      await r.db.into(r.db.syncStates).insertOnConflictUpdate(
            SyncStatesCompanion.insert(
              accountId: 'acc-1',
              resourceType: 'IMAP:INBOX',
              state: jsonEncode(
                  {'uidValidity': 1000, 'lastUid': 5, 'highestModSeq': 42}),
              syncedAt: DateTime.now(),
            ),
          );
      // No new UIDs; server returns [5] for both UID search calls.
      r.fakeImap.searchCallQueue = [[], [5]];

      await r.emails.syncEmails('acc-1', 'INBOX');

      expect(r.fakeImap.uidFetchMessagesCalls, 1);
      expect(r.fakeImap.lastChangedSinceModSequence, 42);

      // Checkpoint updated with new modseq.
      final state = jsonDecode(
              (await r.db.select(r.db.syncStates).get()).first.state)
          as Map<String, dynamic>;
      expect(state['highestModSeq'], 55);
    });

    test('flag refresh: updates flags in local DB', () async {
      final r = _makeReposWithFakes();
      await r.accounts.addAccount(_account, 'pw');
      await r.db.into(r.db.emails).insert(EmailsCompanion.insert(
            id: 'acc-1:5',
            accountId: 'acc-1',
            mailboxPath: 'INBOX',
            uid: 5,
            receivedAt: DateTime(2024),
          ));
      r.fakeImap.uidValidityResult = 1000;
      r.fakeImap.highestModSequenceResult = 55;
      await r.db.into(r.db.syncStates).insertOnConflictUpdate(
            SyncStatesCompanion.insert(
              accountId: 'acc-1',
              resourceType: 'IMAP:INBOX',
              state: jsonEncode(
                  {'uidValidity': 1000, 'lastUid': 5, 'highestModSeq': 42}),
              syncedAt: DateTime.now(),
            ),
          );
      r.fakeImap.searchCallQueue = [[], [5]];
      // Server says uid=5 is now \Seen.
      r.fakeImap.uidFetchResults = [
        buildEnvelopeMessage(uid: 5, flags: [r'\Seen']),
      ];

      await r.emails.syncEmails('acc-1', 'INBOX');

      final email = await r.emails.getEmail('acc-1:5');
      expect(email!.isSeen, isTrue);
    });
  });

  // ── Blob expiry (TTL) tests ───────────────────────────────────────────────────

  group('blob expiry', () {
    test('returns cached body when cachedAt is recent', () async {
      final r = _makeReposWithFakes();
      await r.accounts.addAccount(_account, 'pw');
      await r.db.into(r.db.emails).insert(EmailsCompanion.insert(
            id: 'acc-1:1',
            accountId: 'acc-1',
            mailboxPath: 'INBOX',
            uid: 1,
            receivedAt: DateTime(2024),
          ));
      await r.db.into(r.db.emailBodies).insertOnConflictUpdate(
            EmailBodiesCompanion.insert(
              emailId: 'acc-1:1',
              textBody: const Value('cached text'),
              cachedAt: Value(DateTime.now()),
            ),
          );

      final body = await r.emails.getEmailBody('acc-1:1');

      expect(body.textBody, 'cached text');
      expect(r.fakeImap.logoutCalled, isFalse);
    });

    test('re-fetches body when cachedAt is null (legacy row)', () async {
      final r = _makeReposWithFakes();
      await r.accounts.addAccount(_account, 'pw');
      await r.db.into(r.db.emails).insert(EmailsCompanion.insert(
            id: 'acc-1:1',
            accountId: 'acc-1',
            mailboxPath: 'INBOX',
            uid: 1,
            receivedAt: DateTime(2024),
          ));
      await r.db.into(r.db.emailBodies).insertOnConflictUpdate(
            EmailBodiesCompanion.insert(
              emailId: 'acc-1:1',
              textBody: const Value('stale text'),
              // cachedAt omitted → null
            ),
          );

      final msg = imap.MimeMessage.parseFromText(
        'Subject: Hi\r\nContent-Type: text/plain\r\n\r\nfresh from IMAP',
      );
      msg.uid = 1;
      r.fakeImap.fetchResults = [msg];

      final body = await r.emails.getEmailBody('acc-1:1');

      expect(body.textBody, contains('fresh from IMAP'));
      expect(r.fakeImap.logoutCalled, isTrue);
    });

    test('re-fetches body when cachedAt is older than 7 days', () async {
      final r = _makeReposWithFakes();
      await r.accounts.addAccount(_account, 'pw');
      await r.db.into(r.db.emails).insert(EmailsCompanion.insert(
            id: 'acc-1:1',
            accountId: 'acc-1',
            mailboxPath: 'INBOX',
            uid: 1,
            receivedAt: DateTime(2024),
          ));
      await r.db.into(r.db.emailBodies).insertOnConflictUpdate(
            EmailBodiesCompanion.insert(
              emailId: 'acc-1:1',
              textBody: const Value('old text'),
              cachedAt: Value(DateTime.now().subtract(const Duration(days: 8))),
            ),
          );

      final msg = imap.MimeMessage.parseFromText(
        'Subject: Hi\r\nContent-Type: text/plain\r\n\r\nnew body',
      );
      msg.uid = 1;
      r.fakeImap.fetchResults = [msg];

      final body = await r.emails.getEmailBody('acc-1:1');

      expect(body.textBody, contains('new body'));
      expect(r.fakeImap.logoutCalled, isTrue);
    });
  });

  // ── Failed mutations tests ────────────────────────────────────────────────────

  group('failed mutations', () {
    test('observeFailedMutations emits only rows with lastError set', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      await r.db.into(r.db.pendingChanges).insert(PendingChangesCompanion.insert(
            accountId: 'acc-1',
            resourceType: 'email',
            resourceId: 'acc-1:10',
            changeType: 'flag_seen',
            payload: '{"seen":true}',
            createdAt: DateTime.now(),
            attempts: const Value(1),
            lastError: const Value('network error'),
          ));
      await r.db.into(r.db.pendingChanges).insert(PendingChangesCompanion.insert(
            accountId: 'acc-1',
            resourceType: 'email',
            resourceId: 'acc-1:11',
            changeType: 'move',
            payload: '{"dest":"Archive"}',
            createdAt: DateTime.now(),
            // lastError not set → pending, not failed
          ));

      final mutations =
          await r.emails.observeFailedMutations('acc-1').first;

      expect(mutations, hasLength(1));
      expect(mutations.first.resourceId, 'acc-1:10');
      expect(mutations.first.changeType, 'flag_seen');
      expect(mutations.first.lastError, 'network error');
    });

    test('discardMutation removes the row', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      final rowId = await r.db.into(r.db.pendingChanges).insert(
            PendingChangesCompanion.insert(
              accountId: 'acc-1',
              resourceType: 'email',
              resourceId: 'acc-1:10',
              changeType: 'delete',
              payload: '{}',
              createdAt: DateTime.now(),
              attempts: const Value(3),
              lastError: const Value('timeout'),
            ),
          );

      await r.emails.discardMutation(rowId);

      final rows = await r.db.select(r.db.pendingChanges).get();
      expect(rows, isEmpty);
    });

    test('retryMutation resets attempts and clears lastError', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      final rowId = await r.db.into(r.db.pendingChanges).insert(
            PendingChangesCompanion.insert(
              accountId: 'acc-1',
              resourceType: 'email',
              resourceId: 'acc-1:10',
              changeType: 'move',
              payload: '{"dest":"Trash"}',
              createdAt: DateTime.now(),
              attempts: const Value(5),
              lastError: const Value('connection refused'),
            ),
          );

      await r.emails.retryMutation(rowId);

      final row = (await r.db.select(r.db.pendingChanges).get()).first;
      expect(row.attempts, 0);
      expect(row.lastError, isNull);
    });
  });
}

// ── SSE test helper ──────────────────────────────────────────────────────────

class _SseTestClient extends http.BaseClient {
  _SseTestClient({required this.eventSourceUrl, required this.sseStream});

  final String? eventSourceUrl;
  final Stream<List<int>> sseStream;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path.contains('well-known')) {
      final session = jsonEncode({
        'apiUrl': 'https://jmap.example.com/api/',
        'accounts': {'acct1': {}},
        'primaryAccounts': {
          'urn:ietf:params:jmap:core': 'acct1',
          'urn:ietf:params:jmap:mail': 'acct1',
        },
        'capabilities': {
          'urn:ietf:params:jmap:core': {},
          'urn:ietf:params:jmap:mail': {},
        },
        'username': 'alice@example.com',
        'state': 'sess1',
        if (eventSourceUrl != null) 'eventSourceUrl': eventSourceUrl,
      });
      return http.StreamedResponse(
          Stream.value(utf8.encode(session)), 200);
    }
    if (request.headers['Accept'] == 'text/event-stream') {
      return http.StreamedResponse(sseStream, 200);
    }
    return http.StreamedResponse(Stream.value(utf8.encode('{}') ), 200);
  }
}
