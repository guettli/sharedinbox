import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
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
import 'fake_imap.dart' show FakeImapClient, SnoozeSpyImapClient;
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

http.Client _mockJmapEmails({
  required List<Map<String, dynamic>> apiResponses,
}) {
  var callIndex = 0;
  return MockClient((req) async {
    if (req.url.path.contains('well-known')) {
      return http.Response(
        jsonEncode({
          'apiUrl': 'https://jmap.example.com/api/',
          'accounts': {
            'acct1': {'name': 'alice@example.com', 'isPersonal': true},
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
          '0',
        ],
        [
          'Email/get',
          {'accountId': 'acct1', 'state': state, 'list': list},
          '1',
        ],
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

Map<String, dynamic> _emailGetOnly({
  required String state,
  required List<Map<String, dynamic>> list,
}) =>
    {
      'sessionState': 'sess1',
      'methodResponses': [
        [
          'Email/get',
          {'accountId': 'acct1', 'state': state, 'list': list},
          '1',
        ],
      ],
    };

Map<String, dynamic> _jmapEmail({
  required String id,
  required String mailboxId,
  String subject = 'Hello',
  bool seen = false,
  String? threadId,
}) =>
    {
      'id': id,
      'mailboxIds': {mailboxId: true},
      'subject': subject,
      'sentAt': '2024-01-01T10:00:00Z',
      'receivedAt': '2024-01-01T10:00:01Z',
      'from': [
        {'name': 'Sender', 'email': 'sender@example.com'},
      ],
      'to': [
        {'name': 'Alice', 'email': 'alice@example.com'},
      ],
      'cc': [],
      'keywords': seen ? {r'$seen': true} : <String, dynamic>{},
      'hasAttachment': false,
      'preview': 'Hello world',
      'threadId': threadId,
    };

Future<imap.ImapClient> _noImapConnect(Account a, String u, String p) =>
    Future.error(UnsupportedError('IMAP unavailable in unit tests'));

Future<imap.SmtpClient> _noSmtpConnect(Account a, String u, String p) =>
    Future.error(UnsupportedError('SMTP unavailable in unit tests'));

({AppDatabase db, AccountRepositoryImpl accounts, EmailRepositoryImpl emails})
    _makeRepos({
  http.Client? httpClient,
  Future<imap.ImapClient> Function(Account, String, String)? imapConnect,
  Future<imap.SmtpClient> Function(Account, String, String)? smtpConnect,
}) {
  final db = openTestDatabase();
  final storage = MapSecureStorage();
  final accounts = AccountRepositoryImpl(db, storage);
  final emails = EmailRepositoryImpl(
    db,
    accounts,
    imapConnect: imapConnect ?? _noImapConnect,
    smtpConnect: smtpConnect ?? _noSmtpConnect,
    httpClient: httpClient,
  );
  return (db: db, accounts: accounts, emails: emails);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUpAll(configureSqliteForTests);

  group('EmailRepositoryImpl', () {
    test('observeEmails emits empty list when no emails', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      final emails = await r.emails.observeEmails('acc-1', 'INBOX').first;
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

    test('same UID in different mailboxes yields independent emails', () async {
      // Regression test for the UID collision bug: IMAP UIDs are mailbox-scoped,
      // so UID 50 in INBOX and UID 50 in Archive must get distinct local IDs.
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');

      // New ID format: accountId:mailboxPath:uid
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:INBOX:50',
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              uid: 50,
              receivedAt: DateTime(2024),
            ),
          );
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:Archive:50',
              accountId: 'acc-1',
              mailboxPath: 'Archive',
              uid: 50,
              receivedAt: DateTime(2024, 1, 2),
            ),
          );

      final inboxEmail = await r.emails.getEmail('acc-1:INBOX:50');
      expect(inboxEmail, isNotNull);
      expect(inboxEmail!.mailboxPath, 'INBOX');

      final archiveEmail = await r.emails.getEmail('acc-1:Archive:50');
      expect(archiveEmail, isNotNull);
      expect(archiveEmail!.mailboxPath, 'Archive');

      final inboxEmails = await r.emails.observeEmails('acc-1', 'INBOX').first;
      expect(inboxEmails, hasLength(1));
      expect(inboxEmails.first.id, 'acc-1:INBOX:50');

      final archiveEmails =
          await r.emails.observeEmails('acc-1', 'Archive').first;
      expect(archiveEmails, hasLength(1));
      expect(archiveEmails.first.id, 'acc-1:Archive:50');
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

    // ── Threading tests ──────────────────────────────────────────────────────

    test('observeThreads returns aggregated thread rows from DB', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');

      final now = DateTime.now();
      await r.db.into(r.db.threads).insert(
            ThreadsCompanion.insert(
              id: 'tid1',
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              subject: const Value('Thread 1'),
              latestDate: now,
              messageCount: const Value(2),
              hasUnread: const Value(true),
              latestEmailId: 'acc-1:2',
              emailIdsJson: const Value('["acc-1:1", "acc-1:2"]'),
            ),
          );

      final threads = await r.emails.observeThreads('acc-1', 'INBOX').first;
      expect(threads, hasLength(1));
      expect(threads.first.threadId, 'tid1');
      expect(threads.first.subject, 'Thread 1');
      expect(threads.first.messageCount, 2);
      expect(threads.first.hasUnread, isTrue);
      expect(threads.first.emailIds, ['acc-1:1', 'acc-1:2']);
    });

    test('observeEmailsInThread returns all emails for a thread', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');

      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:1',
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              uid: 1,
              threadId: const Value('tid1'),
              receivedAt: DateTime(2024),
            ),
          );
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:2',
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              uid: 2,
              threadId: const Value('tid1'),
              receivedAt: DateTime(2024, 2),
            ),
          );

      final emails =
          await r.emails.observeEmailsInThread('acc-1', 'INBOX', 'tid1').first;
      expect(emails, hasLength(2));
      expect(emails.map((e) => e.id).toSet(), {'acc-1:1', 'acc-1:2'});
    });

    // ── Search tests ─────────────────────────────────────────────────────────

    test('searchEmailsGlobal filters by query across accounts', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      await r.accounts.addAccount(
        _account.copyWith(id: 'acc-2', email: 'bob@example.com'),
        'pw',
      );

      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:1',
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              uid: 1,
              subject: const Value('Pizza night'),
              receivedAt: DateTime(2024),
            ),
          );
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-2:1',
              accountId: 'acc-2',
              mailboxPath: 'INBOX',
              uid: 1,
              subject: const Value('Burger lunch'),
              receivedAt: DateTime(2024),
            ),
          );

      // Global search
      final results1 = await r.emails.searchEmailsGlobal(null, 'pizza');
      expect(results1, hasLength(1));
      expect(results1.first.subject, 'Pizza night');

      // Account-specific search
      final results2 = await r.emails.searchEmailsGlobal('acc-2', 'burger');
      expect(results2, hasLength(1));
      expect(results2.first.subject, 'Burger lunch');

      final results3 = await r.emails.searchEmailsGlobal('acc-1', 'burger');
      expect(results3, isEmpty);
    });

    test('searchEmailsGlobal matches word prefix but not suffix', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');

      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:1',
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              uid: 1,
              subject: const Value('foobar baz'),
              receivedAt: DateTime(2024),
            ),
          );
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:2',
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              uid: 2,
              subject: const Value('blafoo baz'),
              receivedAt: DateTime(2024),
            ),
          );

      // 'foo' is a prefix of 'foobar' — should match; 'blafoo' is not a
      // prefix match so only one result expected.
      final results = await r.emails.searchEmailsGlobal(null, 'foo');
      expect(results, hasLength(1));
      expect(results.first.subject, 'foobar baz');
    });

    test('searchEmails filters by mailboxPath using local FTS5', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');

      // Insert matching email in INBOX.
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:1',
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              uid: 1,
              subject: const Value('Meeting agenda'),
              receivedAt: DateTime(2024),
            ),
          );
      // Insert matching email in a different mailbox — must not appear.
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:2',
              accountId: 'acc-1',
              mailboxPath: 'Sent',
              uid: 2,
              subject: const Value('Meeting follow-up'),
              receivedAt: DateTime(2024),
            ),
          );

      final results = await r.emails.searchEmails('acc-1', 'INBOX', 'meeting');
      expect(results, hasLength(1));
      expect(results.first.subject, 'Meeting agenda');
      expect(results.first.mailboxPath, 'INBOX');
    });

    test('searchEmailsGlobal includes emails matched by note text', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');

      // Email whose subject does NOT match — but its note does.
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:1',
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              uid: 1,
              messageId: const Value('<msg1@example.com>'),
              subject: const Value('Weekly report'),
              receivedAt: DateTime(2024),
            ),
          );
      // Add a note referencing the email's messageId.
      await r.db.into(r.db.emailNotes).insert(
            EmailNotesCompanion.insert(
              id: 'note-1',
              accountId: 'acc-1',
              messageId: '<msg1@example.com>',
              noteText: 'Urgent follow-up needed',
              serverId: '42',
              createdAt: DateTime(2024),
            ),
          );

      final results = await r.emails.searchEmailsGlobal(null, 'urgent');
      expect(results, hasLength(1));
      expect(results.first.subject, 'Weekly report');
    });

    test('searchEmails includes emails matched by note text in mailbox',
        () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');

      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:1',
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              uid: 1,
              messageId: const Value('<msg1@example.com>'),
              subject: const Value('Project update'),
              receivedAt: DateTime(2024),
            ),
          );
      // Email in a different mailbox — its note must not appear in INBOX search.
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:2',
              accountId: 'acc-1',
              mailboxPath: 'Sent',
              uid: 2,
              messageId: const Value('<msg2@example.com>'),
              subject: const Value('Other email'),
              receivedAt: DateTime(2024),
            ),
          );
      await r.db.into(r.db.emailNotes).insert(
            EmailNotesCompanion.insert(
              id: 'note-1',
              accountId: 'acc-1',
              messageId: '<msg1@example.com>',
              noteText: 'remember to call client',
              serverId: '42',
              createdAt: DateTime(2024),
            ),
          );
      await r.db.into(r.db.emailNotes).insert(
            EmailNotesCompanion.insert(
              id: 'note-2',
              accountId: 'acc-1',
              messageId: '<msg2@example.com>',
              noteText: 'remember to call client',
              serverId: '43',
              createdAt: DateTime(2024),
            ),
          );

      final results = await r.emails.searchEmails('acc-1', 'INBOX', 'client');
      expect(results, hasLength(1));
      expect(results.first.subject, 'Project update');
      expect(results.first.mailboxPath, 'INBOX');
    });

    test('searchEmailsGlobal returns results sorted by receivedAt descending',
        () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');

      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:1',
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              uid: 1,
              subject: const Value('Older report'),
              receivedAt: DateTime(2024),
            ),
          );
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:2',
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              uid: 2,
              subject: const Value('Newer report'),
              receivedAt: DateTime(2024, 6),
            ),
          );

      final results = await r.emails.searchEmailsGlobal(null, 'report');
      expect(results, hasLength(2));
      expect(results[0].subject, 'Newer report');
      expect(results[1].subject, 'Older report');
    });

    test('searchEmails returns results sorted by receivedAt descending',
        () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');

      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:1',
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              uid: 1,
              subject: const Value('Older meeting'),
              receivedAt: DateTime(2024),
            ),
          );
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:2',
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              uid: 2,
              subject: const Value('Newer meeting'),
              receivedAt: DateTime(2024, 6),
            ),
          );

      final results = await r.emails.searchEmails('acc-1', 'INBOX', 'meeting');
      expect(results, hasLength(2));
      expect(results[0].subject, 'Newer meeting');
      expect(results[1].subject, 'Older meeting');
    });

    test(
      'searchAddresses returns results sorted by most recently used',
      () async {
        final r = _makeRepos();
        await r.accounts.addAccount(_account, 'pw');

        final older = DateTime(2024);
        final newer = DateTime(2024, 6);

        // Two emails — older one has alice@, newer one has bob@.
        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: 'acc-1:old',
                accountId: 'acc-1',
                mailboxPath: 'INBOX',
                uid: 1,
                receivedAt: older,
                toAddresses: const Value(
                  '[{"name":"Alice","email":"alice@example.com"}]',
                ),
              ),
            );
        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: 'acc-1:new',
                accountId: 'acc-1',
                mailboxPath: 'Sent',
                uid: 2,
                receivedAt: newer,
                toAddresses: const Value(
                  '[{"name":"Bob","email":"bob@example.com"}]',
                ),
              ),
            );

        // Query matching both; newer (bob) should come first.
        final results = await r.emails.searchAddresses(null, 'example');
        expect(results.map((a) => a.email).toList(), [
          'bob@example.com',
          'alice@example.com',
        ]);
      },
    );

    test(
      'searchAddresses prioritises sent-folder addresses over newer received',
      () async {
        final r = _makeRepos();
        await r.accounts.addAccount(_account, 'pw');

        // Register the Sent mailbox so searchAddresses knows its role.
        await r.db.into(r.db.mailboxes).insert(
              MailboxesCompanion.insert(
                id: 'acc-1:Sent',
                accountId: 'acc-1',
                path: 'Sent',
                name: 'Sent',
                role: const Value('sent'),
              ),
            );

        // Older sent email: user deliberately wrote to info@foo.de.
        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: 'acc-1:sent-1',
                accountId: 'acc-1',
                mailboxPath: 'Sent',
                uid: 1,
                receivedAt: DateTime(2025),
                toAddresses: const Value(
                  '[{"name":"Foo","email":"info@foo.de"}]',
                ),
              ),
            );

        // Newer received email: spam arrived today from info@spam.de.
        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: 'acc-1:inbox-1',
                accountId: 'acc-1',
                mailboxPath: 'INBOX',
                uid: 2,
                receivedAt: DateTime(2026),
                fromJson: const Value(
                  '[{"name":"Spam","email":"info@spam.de"}]',
                ),
              ),
            );

        // Even though spam is newer, the sent-folder address should win.
        final results = await r.emails.searchAddresses(null, 'info');
        expect(results.map((a) => a.email).toList(), [
          'info@foo.de',
          'info@spam.de',
        ]);
      },
    );

    // ── IMAP method tests ────────────────────────────────────────────────────

    test(
      'setFlag seen=true enqueues flag_seen change and updates local DB',
      () async {
        final r = _makeRepos();
        await r.accounts.addAccount(_account, 'pw');
        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: 'acc-1:5',
                accountId: 'acc-1',
                mailboxPath: 'INBOX',
                uid: 5,
                receivedAt: DateTime(2024),
              ),
            );

        await r.emails.setFlag('acc-1:5', seen: true);

        final changes = await r.db.select(r.db.pendingChanges).get();
        expect(changes, hasLength(1));
        expect(changes.first.changeType, 'flag_seen');
        expect(changes.first.payload, contains('"seen":true'));
        final email = await r.emails.getEmail('acc-1:5');
        expect(email!.isSeen, isTrue);
      },
    );

    test(
      'setFlag seen=false enqueues flag_seen change with seen=false',
      () async {
        final r = _makeRepos();
        await r.accounts.addAccount(_account, 'pw');
        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: 'acc-1:5',
                accountId: 'acc-1',
                mailboxPath: 'INBOX',
                uid: 5,
                receivedAt: DateTime(2024),
                isSeen: const Value(true),
              ),
            );

        await r.emails.setFlag('acc-1:5', seen: false);

        final changes = await r.db.select(r.db.pendingChanges).get();
        expect(changes.first.changeType, 'flag_seen');
        expect(changes.first.payload, contains('"seen":false'));
        final email = await r.emails.getEmail('acc-1:5');
        expect(email!.isSeen, isFalse);
      },
    );

    test('setFlag flagged=true enqueues flag_flagged change', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:5',
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              uid: 5,
              receivedAt: DateTime(2024),
            ),
          );

      await r.emails.setFlag('acc-1:5', flagged: true);

      final changes = await r.db.select(r.db.pendingChanges).get();
      expect(changes.first.changeType, 'flag_flagged');
      final email = await r.emails.getEmail('acc-1:5');
      expect(email!.isFlagged, isTrue);
    });

    test(
      'setFlag flagged=false enqueues flag_flagged change with flagged=false',
      () async {
        final r = _makeRepos();
        await r.accounts.addAccount(_account, 'pw');
        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: 'acc-1:5',
                accountId: 'acc-1',
                mailboxPath: 'INBOX',
                uid: 5,
                receivedAt: DateTime(2024),
                isFlagged: const Value(true),
              ),
            );

        await r.emails.setFlag('acc-1:5', flagged: false);

        final changes = await r.db.select(r.db.pendingChanges).get();
        expect(changes.first.changeType, 'flag_flagged');
        expect(changes.first.payload, contains('"flagged":false'));
      },
    );

    test(
      'moveEmail enqueues move change and updates local mailboxPath (optimistic)',
      () async {
        final r = _makeRepos();
        await r.accounts.addAccount(_account, 'pw');
        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: 'acc-1:5',
                accountId: 'acc-1',
                mailboxPath: 'INBOX',
                uid: 5,
                receivedAt: DateTime(2024),
              ),
            );

        await r.emails.moveEmail('acc-1:5', 'Archive');

        final changes = await r.db.select(r.db.pendingChanges).get();
        expect(changes.first.changeType, 'move');
        expect(changes.first.payload, contains('Archive'));

        final email = await r.emails.getEmail('acc-1:5');
        expect(email, isNotNull);
        expect(email!.mailboxPath, 'Archive');
      },
    );

    test(
      'deleteEmail enqueues delete change and removes email from local DB',
      () async {
        final r = _makeRepos();
        await r.accounts.addAccount(_account, 'pw');
        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: 'acc-1:5',
                accountId: 'acc-1',
                mailboxPath: 'INBOX',
                uid: 5,
                receivedAt: DateTime(2024),
              ),
            );

        await r.emails.deleteEmail('acc-1:5');

        final changes = await r.db.select(r.db.pendingChanges).get();
        expect(changes.first.changeType, 'delete');
        expect(await r.emails.getEmail('acc-1:5'), isNull);
      },
    );
  });

  group('IMAP flushPendingChanges', () {
    test('records attempt and error when IMAP throws', () async {
      final r = _makeRepos();
      // _makeRepos uses _noImapConnect which throws UnsupportedError
      await r.accounts.addAccount(_account, 'pw');
      await r.db.into(r.db.pendingChanges).insert(
            PendingChangesCompanion.insert(
              accountId: 'acc-1',
              resourceType: 'Email',
              resourceId: 'acc-1:5',
              changeType: 'flag_seen',
              payload: '{"uid":5,"mailboxPath":"INBOX","seen":true}',
              createdAt: DateTime.now(),
            ),
          );
      await r.emails.flushPendingChanges('acc-1', 'pw');
      final changes = await r.db.select(r.db.pendingChanges).get();
      expect(changes, hasLength(1));
      expect(changes.first.attempts, 1);
      expect(changes.first.lastError, isNotNull);
    });

    test('evicts IMAP change after max attempts (5)', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      // Pre-seed a flag_seen at attempts=4
      await r.db.into(r.db.pendingChanges).insert(
            PendingChangesCompanion.insert(
              accountId: _account.id,
              resourceType: 'Email',
              resourceId: '${_account.id}:1',
              changeType: 'flag_seen',
              payload: '{"uid":1,"mailboxPath":"INBOX","seen":true}',
              createdAt: DateTime.now(),
              attempts: const Value(4),
            ),
          );

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

    test(
      'snooze flush selects src mailbox and moves email to Snoozed',
      () async {
        final spy = SnoozeSpyImapClient();
        final r = _makeRepos(imapConnect: (_, __, ___) async => spy);
        await r.accounts.addAccount(_account, 'pw');
        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: 'acc-1:5',
                accountId: 'acc-1',
                mailboxPath: 'Snoozed',
                uid: 5,
                receivedAt: DateTime(2024),
              ),
            );
        await r.db.into(r.db.pendingChanges).insert(
              PendingChangesCompanion.insert(
                accountId: 'acc-1',
                resourceType: 'Email',
                resourceId: 'acc-1:5',
                changeType: 'snooze',
                payload: jsonEncode({
                  'uid': 5,
                  'src': 'INBOX',
                  'dest': 'Snoozed',
                  'until': '2026-05-10T15:00:00.000',
                }),
                createdAt: DateTime.now(),
              ),
            );

        await r.emails.flushPendingChanges('acc-1', 'pw');

        // Change successfully applied — removed from queue.
        expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);
        // Source mailbox extracted from 'src', not 'mailboxPath'.
        expect(spy.selectedMailbox, 'INBOX');
        expect(spy.createdMailbox, 'Snoozed');
        expect(spy.movedToMailbox, 'Snoozed');
      },
    );
  });

  group('Snooze', () {
    test('snoozeEmail enqueues snooze change and updates local DB', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:5',
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              uid: 5,
              receivedAt: DateTime(2024),
            ),
          );

      final until = DateTime(2026, 5, 10, 15);
      await r.emails.snoozeEmail('acc-1:5', until);

      final email = await r.emails.getEmail('acc-1:5');
      expect(email!.snoozedUntil, until);
      expect(email.mailboxPath, 'Snoozed');
      expect(email.snoozedFromMailboxPath, 'INBOX');

      final changes = await r.db.select(r.db.pendingChanges).get();
      expect(changes, hasLength(1));
      expect(changes.first.changeType, 'snooze');
      expect(changes.first.payload, contains('2026-05-10T15:00:00.000'));
    });

    test('wakeUpEmails enqueues unsnooze for expired emails', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      // Seed Inbox mailbox
      await r.db.into(r.db.mailboxes).insert(
            MailboxesCompanion.insert(
              id: 'acc-1:INBOX',
              accountId: 'acc-1',
              path: 'INBOX',
              name: 'Inbox',
              role: const Value('inbox'),
            ),
          );

      final past = DateTime.now().subtract(const Duration(hours: 1));
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:5',
              accountId: 'acc-1',
              mailboxPath: 'Snoozed',
              uid: 5,
              receivedAt: DateTime(2024),
              snoozedUntil: Value(past),
              snoozedFromMailboxPath: const Value('INBOX'),
            ),
          );

      final count = await r.emails.wakeUpEmails('acc-1');
      expect(count, 1);

      final email = await r.emails.getEmail('acc-1:5');
      expect(email!.snoozedUntil, isNull);
      expect(email.mailboxPath, 'INBOX');

      final changes = await r.db.select(r.db.pendingChanges).get();
      expect(changes, hasLength(1));
      expect(changes.first.changeType, 'unsnooze');
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
                  'acct1': {'name': 'alice@example.com', 'isPersonal': true},
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
                          {'partId': '1', 'type': 'text/plain'},
                        ],
                        'htmlBody': [
                          {'partId': '2', 'type': 'text/html'},
                        ],
                        'bodyValues': {
                          '1': {'value': text, 'isTruncated': false},
                          '2': {'value': html, 'isTruncated': false},
                        },
                        'attachments': [],
                      },
                    ],
                  },
                  '0',
                ],
              ],
            }),
            200,
          );
        });

    test('fetches body via JMAP Email/get and caches it', () async {
      final r = _makeRepos(httpClient: mockBodyClient());
      await r.accounts.addAccount(_jmapAccount, 'pw');
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'jmap-1:e1',
              accountId: 'jmap-1',
              mailboxPath: 'mbx1',
              uid: 0,
              receivedAt: DateTime(2024),
            ),
          );

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
                  'acct1': {'name': 'alice@example.com', 'isPersonal': true},
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
                      },
                    ],
                  },
                  '0',
                ],
              ],
            }),
            200,
          );
        }),
      );
      await r.accounts.addAccount(_jmapAccount, 'pw');
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'jmap-1:e1',
              accountId: 'jmap-1',
              mailboxPath: 'mbx1',
              uid: 0,
              receivedAt: DateTime(2024),
            ),
          );

      final body = await r.emails.getEmailBody('jmap-1:e1');
      expect(body.textBody, isNull);
      expect(body.htmlBody, isNull);
    });

    test('populates mimeTree from JMAP bodyStructure', () async {
      final r = _makeRepos(
        httpClient: MockClient((req) async {
          if (req.url.path.contains('well-known')) {
            return http.Response(
              jsonEncode({
                'apiUrl': 'https://jmap.example.com/api/',
                'accounts': {
                  'acct1': {'name': 'alice@example.com', 'isPersonal': true},
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
                          {'partId': '1', 'type': 'text/plain'},
                        ],
                        'htmlBody': [],
                        'bodyValues': {
                          '1': {'value': 'Hello', 'isTruncated': false},
                        },
                        'attachments': [],
                        'bodyStructure': {
                          'type': 'multipart/mixed',
                          'subParts': [
                            {'type': 'text/plain', 'size': 5},
                            {
                              'type': 'application/pdf',
                              'name': 'doc.pdf',
                              'size': 2048,
                            },
                          ],
                        },
                      },
                    ],
                  },
                  '0',
                ],
              ],
            }),
            200,
          );
        }),
      );
      await r.accounts.addAccount(_jmapAccount, 'pw');
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'jmap-1:e1',
              accountId: 'jmap-1',
              mailboxPath: 'mbx1',
              uid: 0,
              receivedAt: DateTime(2024),
            ),
          );

      final body = await r.emails.getEmailBody('jmap-1:e1');

      expect(body.mimeTree, isNotNull);
      expect(body.mimeTree!.contentType, 'multipart/mixed');
      expect(body.mimeTree!.children, hasLength(2));
      expect(body.mimeTree!.children[0].contentType, 'text/plain');
      expect(body.mimeTree!.children[1].contentType, 'application/pdf');
      expect(body.mimeTree!.children[1].filename, 'doc.pdf');
      expect(body.mimeTree!.children[1].size, 2048);

      // mimeTree must survive the cache round-trip.
      final cached = await r.emails.getEmailBody('jmap-1:e1');
      expect(cached.mimeTree, isNotNull);
      expect(cached.mimeTree!.contentType, 'multipart/mixed');
      expect(cached.mimeTree!.children, hasLength(2));
    });

    test('mimeTree is null when bodyStructure is absent', () async {
      final r = _makeRepos(httpClient: mockBodyClient());
      await r.accounts.addAccount(_jmapAccount, 'pw');
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'jmap-1:e1',
              accountId: 'jmap-1',
              mailboxPath: 'mbx1',
              uid: 0,
              receivedAt: DateTime(2024),
            ),
          );

      // mockBodyClient returns no bodyStructure field.
      final body = await r.emails.getEmailBody('jmap-1:e1');
      expect(body.mimeTree, isNull);
    });
  });

  group('JMAP syncEmails', () {
    test('full sync upserts emails and persists state', () async {
      final r = _makeRepos(
        httpClient: _mockJmapEmails(
          apiResponses: [
            _emailGetResponse(
              state: 'est1',
              list: [
                _jmapEmail(id: 'e1', mailboxId: 'mbx1', subject: 'First'),
                _jmapEmail(
                  id: 'e2',
                  mailboxId: 'mbx1',
                  subject: 'Second',
                  seen: true,
                ),
              ],
            ),
          ],
        ),
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
        httpClient: _mockJmapEmails(
          apiResponses: [
            // Call 1: Email/changes
            _emailChangesResponse(
              oldState: 'est1',
              newState: 'est2',
              created: ['e3'],
              updated: ['e1'],
              destroyed: ['e2'],
            ),
            // Call 2: Email/get for created + updated
            _emailGetOnly(
              state: 'est2',
              list: [
                _jmapEmail(
                  id: 'e1',
                  mailboxId: 'mbx1',
                  subject: 'First updated',
                ),
                _jmapEmail(id: 'e3', mailboxId: 'mbx1', subject: 'Third'),
              ],
            ),
          ],
        ),
      );
      await r.accounts.addAccount(_jmapAccount, 'pw');

      // Pre-populate
      await r.db.into(r.db.emails).insertOnConflictUpdate(
            EmailsCompanion.insert(
              id: 'jmap-1:e1',
              accountId: 'jmap-1',
              mailboxPath: 'mbx1',
              uid: 0,
              subject: const Value('First'),
              receivedAt: DateTime(2024),
            ),
          );
      await r.db.into(r.db.emails).insertOnConflictUpdate(
            EmailsCompanion.insert(
              id: 'jmap-1:e2',
              accountId: 'jmap-1',
              mailboxPath: 'mbx1',
              uid: 0,
              subject: const Value('Second'),
              receivedAt: DateTime(2024),
            ),
          );
      await r.db.into(r.db.syncStates).insertOnConflictUpdate(
            SyncStatesCompanion.insert(
              accountId: 'jmap-1',
              resourceType: 'Email',
              state: 'est1',
              syncedAt: DateTime.now(),
            ),
          );

      await r.emails.syncEmails('jmap-1', 'mbx1');

      final emails = await r.emails.observeEmails('jmap-1', 'mbx1').first;
      expect(emails.map((e) => e.subject).toSet(), {'First updated', 'Third'});

      final states = await r.db.select(r.db.syncStates).get();
      expect(states.first.state, 'est2');
    });

    test('incremental sync with no changes updates state only', () async {
      final r = _makeRepos(
        httpClient: _mockJmapEmails(
          apiResponses: [
            _emailChangesResponse(oldState: 'est1', newState: 'est1'),
          ],
        ),
      );
      await r.accounts.addAccount(_jmapAccount, 'pw');
      await r.db.into(r.db.syncStates).insertOnConflictUpdate(
            SyncStatesCompanion.insert(
              accountId: 'jmap-1',
              resourceType: 'Email',
              state: 'est1',
              syncedAt: DateTime.now(),
            ),
          );

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
        httpClient: _mockJmapEmails(
          apiResponses: [
            _emailGetResponse(state: 'est1', list: page1, total: 4),
            _emailGetResponse(state: 'est1', list: page2, total: 4),
          ],
        ),
      );
      await r.accounts.addAccount(_jmapAccount, 'pw');
      await r.emails.syncEmails('jmap-1', 'mbx1');

      final emails = await r.emails.observeEmails('jmap-1', 'mbx1').first;
      expect(emails, hasLength(4));
      expect(emails.map((e) => e.subject).toSet(), {
        'Page1-A',
        'Page1-B',
        'Page2-A',
        'Page2-B',
      });

      final states = await r.db.select(r.db.syncStates).get();
      expect(states.first.state, 'est1');
    });
  });

  group('JMAP setFlag / moveEmail / deleteEmail enqueue pending_changes', () {
    Future<void> seedJmapEmail(
      AppDatabase db,
      AccountRepositoryImpl accounts,
    ) async {
      await accounts.addAccount(_jmapAccount, 'pw');
      await db.into(db.emails).insert(
            EmailsCompanion.insert(
              id: 'jmap-1:e1',
              accountId: 'jmap-1',
              mailboxPath: 'mbx1',
              uid: 0,
              receivedAt: DateTime(2024),
            ),
          );
    }

    test(
      'setFlag seen enqueues flag_seen change and updates local DB',
      () async {
        final r = _makeRepos();
        await seedJmapEmail(r.db, r.accounts);

        await r.emails.setFlag('jmap-1:e1', seen: true);

        final changes = await r.db.select(r.db.pendingChanges).get();
        expect(changes, hasLength(1));
        expect(changes.first.changeType, 'flag_seen');
        expect(changes.first.payload, contains('true'));

        final email = await r.emails.getEmail('jmap-1:e1');
        expect(email?.isSeen, isTrue);
      },
    );

    test('setFlag flagged enqueues flag_flagged change', () async {
      final r = _makeRepos();
      await seedJmapEmail(r.db, r.accounts);

      await r.emails.setFlag('jmap-1:e1', flagged: true);

      final changes = await r.db.select(r.db.pendingChanges).get();
      expect(changes.first.changeType, 'flag_flagged');
    });

    test(
      'moveEmail enqueues move change and updates local mailbox path',
      () async {
        final r = _makeRepos();
        await seedJmapEmail(r.db, r.accounts);

        await r.emails.moveEmail('jmap-1:e1', 'mbx2');

        final changes = await r.db.select(r.db.pendingChanges).get();
        expect(changes.first.changeType, 'move');
        expect(changes.first.payload, contains('mbx2'));

        final email = await r.emails.getEmail('jmap-1:e1');
        expect(email, isNotNull);
        expect(email?.mailboxPath, 'mbx2');
      },
    );

    test(
      'deleteEmail enqueues delete change and removes email from local DB',
      () async {
        final r = _makeRepos();
        await seedJmapEmail(r.db, r.accounts);

        await r.emails.deleteEmail('jmap-1:e1');

        final changes = await r.db.select(r.db.pendingChanges).get();
        expect(changes.first.changeType, 'delete');
        expect(await r.emails.getEmail('jmap-1:e1'), isNull);
      },
    );
  });

  group('JMAP flushPendingChanges', () {
    http.Client mockFlush(int apiStatus) {
      return MockClient((req) async {
        if (req.url.path.contains('well-known')) {
          return http.Response(
            jsonEncode({
              'apiUrl': 'https://jmap.example.com/api/',
              'accounts': {
                'acct1': {'name': 'alice@example.com', 'isPersonal': true},
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
            'sessionState': 's1',
            'methodResponses': [
              [
                'Email/set',
                {'accountId': 'acct1', 'updated': {}, 'destroyed': []},
                '0',
              ],
            ],
          }),
          apiStatus,
        );
      });
    }

    Future<void> seedChange(
      AppDatabase db,
      AccountRepositoryImpl accounts, {
      String changeType = 'flag_seen',
      String payload = '{"seen":true}',
    }) async {
      await accounts.addAccount(_jmapAccount, 'pw');
      await db.into(db.pendingChanges).insert(
            PendingChangesCompanion.insert(
              accountId: 'jmap-1',
              resourceType: 'Email',
              resourceId: 'jmap-1:e1',
              changeType: changeType,
              payload: payload,
              createdAt: DateTime.now(),
            ),
          );
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
      await seedChange(
        r.db,
        r.accounts,
        changeType: 'flag_flagged',
        payload: '{"flagged":true}',
      );

      await r.emails.flushPendingChanges('jmap-1', 'pw');

      expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);
    });

    test('sends move and removes change on success', () async {
      final r = _makeRepos(httpClient: mockFlush(200));
      await seedChange(
        r.db,
        r.accounts,
        changeType: 'move',
        payload: '{"src":"mbx1","dest":"mbx2"}',
      );

      await r.emails.flushPendingChanges('jmap-1', 'pw');

      expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);
    });

    test('sends delete and removes change on success', () async {
      final r = _makeRepos(httpClient: mockFlush(200));
      await seedChange(r.db, r.accounts, changeType: 'delete', payload: '{}');

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
          jsonEncode({
            'sessionState': 's1',
            'methodResponses': [
              [
                'Email/set',
                {'accountId': 'acct1', 'newState': 'est2', 'updated': {}},
                '0',
              ],
            ],
          }),
          200,
        );
      });

      final r = _makeRepos(httpClient: client);
      await r.accounts.addAccount(_jmapAccount, 'pw');
      await r.db.into(r.db.syncStates).insertOnConflictUpdate(
            SyncStatesCompanion.insert(
              accountId: 'jmap-1',
              resourceType: 'Email',
              state: 'est1',
              syncedAt: DateTime.now(),
            ),
          );
      await r.db.into(r.db.pendingChanges).insert(
            PendingChangesCompanion.insert(
              accountId: 'jmap-1',
              resourceType: 'Email',
              resourceId: 'jmap-1:e1',
              changeType: 'flag_seen',
              payload: '{"seen":true}',
              createdAt: DateTime.now(),
            ),
          );

      await r.emails.flushPendingChanges('jmap-1', 'pw');

      final firstCall =
          (capturedBody['methodCalls'] as List<dynamic>).first as List<dynamic>;
      final args = firstCall[1] as Map<String, dynamic>;
      expect(args['ifInState'], 'est1');

      // newState returned by server should update our checkpoint
      final states = await r.db.select(r.db.syncStates).get();
      expect(states.first.state, 'est2');
    });

    test(
      'stateMismatch clears sync state and marks change as failed',
      () async {
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
            jsonEncode({
              'sessionState': 's1',
              'methodResponses': [
                [
                  'Email/set',
                  {'accountId': 'acct1', 'type': 'stateMismatch'},
                  '0',
                ],
              ],
            }),
            200,
          );
        });

        final r = _makeRepos(httpClient: client);
        await r.accounts.addAccount(_jmapAccount, 'pw');
        await r.db.into(r.db.syncStates).insertOnConflictUpdate(
              SyncStatesCompanion.insert(
                accountId: 'jmap-1',
                resourceType: 'Email',
                state: 'est1',
                syncedAt: DateTime.now(),
              ),
            );
        await r.db.into(r.db.pendingChanges).insert(
              PendingChangesCompanion.insert(
                accountId: 'jmap-1',
                resourceType: 'Email',
                resourceId: 'jmap-1:e1',
                changeType: 'flag_seen',
                payload: '{"seen":true}',
                createdAt: DateTime.now(),
              ),
            );

        await r.emails.flushPendingChanges('jmap-1', 'pw');

        // Sync state should be cleared so next cycle does a full re-sync
        expect(await r.db.select(r.db.syncStates).get(), isEmpty);

        // Change should still be present but with attempt count bumped
        final changes = await r.db.select(r.db.pendingChanges).get();
        expect(changes.first.attempts, 1);
      },
    );

    test(
      'discards change immediately on notUpdated (permanent error)',
      () async {
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
            jsonEncode({
              'sessionState': 's1',
              'methodResponses': [
                [
                  'Email/set',
                  {
                    'accountId': 'acct1',
                    'notUpdated': {
                      'e1': {'type': 'notFound'},
                    },
                  },
                  '0',
                ],
              ],
            }),
            200,
          );
        });

        final r = _makeRepos(httpClient: client);
        await r.accounts.addAccount(_jmapAccount, 'pw');
        await r.db.into(r.db.pendingChanges).insert(
              PendingChangesCompanion.insert(
                accountId: 'jmap-1',
                resourceType: 'Email',
                resourceId: 'jmap-1:e1',
                changeType: 'flag_seen',
                payload: '{"seen":true}',
                createdAt: DateTime.now(),
              ),
            );

        await r.emails.flushPendingChanges('jmap-1', 'pw');

        // Permanent error — change is immediately evicted
        expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);
      },
    );

    test('evicts change after max attempts (5)', () async {
      final r = _makeRepos(httpClient: mockFlush(500));
      await r.accounts.addAccount(_jmapAccount, 'pw');
      // Seed a change already at attempts=4 (one below the eviction threshold)
      await r.db.into(r.db.pendingChanges).insert(
            PendingChangesCompanion.insert(
              accountId: 'jmap-1',
              resourceType: 'Email',
              resourceId: 'jmap-1:e1',
              changeType: 'flag_seen',
              payload: '{"seen":true}',
              createdAt: DateTime.now(),
              attempts: const Value(4),
            ),
          );

      await r.emails.flushPendingChanges('jmap-1', 'pw');

      // 4+1 = 5 = _maxChangeAttempts → evicted
      expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);
    });

    test(
      'snooze creates Snoozed folder via Mailbox/set when dest is Snoozed',
      () async {
        final List<Map<String, dynamic>> capturedBodies = [];
        final client = MockClient((req) async {
          if (req.url.path.contains('well-known')) {
            return http.Response(
              jsonEncode({
                'apiUrl': 'https://jmap.example.com/api/',
                'accounts': {
                  'acct1': {'name': 'alice@example.com', 'isPersonal': true},
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
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          capturedBodies.add(body);
          final calls = body['methodCalls'] as List;
          final methodName = (calls.first as List)[0] as String;
          if (methodName == 'Mailbox/set') {
            return http.Response(
              jsonEncode({
                'sessionState': 's1',
                'methodResponses': [
                  [
                    'Mailbox/set',
                    {
                      'accountId': 'acct1',
                      'created': {
                        'new-snoozed': {'id': 'mbx-snoozed'},
                      },
                    },
                    '0',
                  ],
                ],
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'sessionState': 's1',
              'methodResponses': [
                [
                  'Email/set',
                  {'accountId': 'acct1', 'updated': {}},
                  '0',
                ],
              ],
            }),
            200,
          );
        });

        final r = _makeRepos(httpClient: client);
        await seedChange(
          r.db,
          r.accounts,
          changeType: 'snooze',
          payload: jsonEncode({
            'uid': 0,
            'src': 'mbx-inbox',
            'dest': 'Snoozed',
            'until': '2026-05-10T15:00:00.000',
          }),
        );

        await r.emails.flushPendingChanges('jmap-1', 'pw');

        // Change successfully applied — removed from queue.
        expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);

        // First API call should be Mailbox/set to create the Snoozed folder.
        expect(capturedBodies, hasLength(2));
        final firstCall =
            ((capturedBodies.first['methodCalls'] as List).first as List)[0];
        expect(firstCall, 'Mailbox/set');

        // Second call should be Email/set using the newly created mailbox ID.
        final secondCallArgs = ((capturedBodies[1]['methodCalls'] as List).first
            as List)[1] as Map<String, dynamic>;
        final update = (secondCallArgs['update'] as Map<String, dynamic>)['e1']
            as Map<String, dynamic>;
        expect(update['mailboxIds/mbx-snoozed'], true);
      },
    );

    test(
      'snooze uses existing mailbox ID when dest is already a JMAP ID',
      () async {
        final r = _makeRepos(httpClient: mockFlush(200));
        await seedChange(
          r.db,
          r.accounts,
          changeType: 'snooze',
          payload: jsonEncode({
            'uid': 0,
            'src': 'mbx-inbox',
            'dest': 'mbx-snoozed',
            'until': '2026-05-10T15:00:00.000',
          }),
        );

        await r.emails.flushPendingChanges('jmap-1', 'pw');

        // Change applied without needing Mailbox/set (dest was already a valid ID).
        expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);
      },
    );
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
          'textBody': [
            if (textContent != null) {'partId': 'text1', 'type': 'text/plain'},
          ],
          'htmlBody': [
            if (htmlContent != null) {'partId': 'html1', 'type': 'text/html'},
          ],
          'bodyValues': {
            if (textContent != null)
              'text1': {
                'value': textContent,
                'isEncodingProblem': false,
                'isTruncated': false,
              },
            if (htmlContent != null)
              'html1': {
                'value': htmlContent,
                'isEncodingProblem': false,
                'isTruncated': false,
              },
          },
          'attachments': [],
        };

    test('full sync caches bodies when bodyValues are present', () async {
      final r = _makeRepos(
        httpClient: _mockJmapEmails(
          apiResponses: [
            _emailGetResponse(
              state: 'est1',
              list: [
                jmapEmailWithBody(
                  id: 'e1',
                  mailboxId: 'mbx1',
                  textContent: 'Hello text',
                  htmlContent: '<p>Hello</p>',
                ),
              ],
            ),
          ],
        ),
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
        httpClient: _mockJmapEmails(
          apiResponses: [
            _emailGetResponse(
              state: 'est1',
              list: [_jmapEmail(id: 'e1', mailboxId: 'mbx1')],
            ),
          ],
        ),
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
        // First API call is Identity/get; respond with a single identity.
        if (req.body.contains('Identity/get')) {
          return http.Response(
            jsonEncode({
              'sessionState': 's1',
              'methodResponses': [
                [
                  'Identity/get',
                  {
                    'accountId': 'acct1',
                    'state': 'id1',
                    'list': [
                      {'id': 'identity1', 'email': 'alice@example.com'},
                    ],
                  },
                  'i',
                ],
              ],
            }),
            apiStatus,
          );
        }
        if (req.body.contains('Email/set')) {
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
                        'created': {
                          'em1': {'id': 'newEmailId1'},
                        },
                      },
                  '0',
                ],
              ],
            }),
            apiStatus,
          );
        }
        return http.Response(
          jsonEncode({
            'sessionState': 's1',
            'methodResponses': [
              [
                'EmailSubmission/set',
                submissionResult ??
                    {
                      'accountId': 'acct1',
                      'created': {
                        'sub1': {'id': 'subId1'},
                      },
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
            'notCreated': {
              'em1': {'type': 'invalidProperties'},
            },
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
            'notCreated': {
              'sub1': {'type': 'invalidRecipients'},
            },
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
        if (req.body.contains('Email/set')) {
          capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
        }
        // First API call is Identity/get; respond with a single identity.
        if (req.body.contains('Identity/get')) {
          return http.Response(
            jsonEncode({
              'sessionState': 's1',
              'methodResponses': [
                [
                  'Identity/get',
                  {
                    'accountId': 'acct1',
                    'state': 'id1',
                    'list': [
                      {'id': 'identity1', 'email': 'alice@example.com'},
                    ],
                  },
                  'i',
                ],
              ],
            }),
            200,
          );
        }
        if (req.body.contains('Email/set')) {
          return http.Response(
            jsonEncode({
              'sessionState': 's1',
              'methodResponses': [
                [
                  'Email/set',
                  {
                    'accountId': 'acct1',
                    'newState': 'est2',
                    'created': {
                      'em1': {'id': 'newId'},
                    },
                  },
                  '0',
                ],
              ],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'sessionState': 's1',
            'methodResponses': [
              [
                'EmailSubmission/set',
                {
                  'accountId': 'acct1',
                  'created': {
                    'sub1': {'id': 'subId'},
                  },
                },
                '1',
              ],
            ],
          }),
          200,
        );
      });

      final r = _makeRepos(httpClient: client);
      await r.accounts.addAccount(_jmapAccount, 'pw');
      // Seed a Sent mailbox with role='sent'
      await r.db.into(r.db.mailboxes).insert(
            MailboxesCompanion.insert(
              id: 'jmap-1:sentMbx',
              accountId: 'jmap-1',
              path: 'sentMbxJmapId',
              name: 'Sent',
              role: const Value('sent'),
            ),
          );

      await r.emails.sendEmail('jmap-1', draft);

      final calls = capturedBody['methodCalls'] as List<dynamic>;
      final emailSetArgs =
          (calls.first as List<dynamic>)[1] as Map<String, dynamic>;
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
      final sub = r.emails.watchJmapPush('jmap-1', 'pw').listen(emitted.add);

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
      final sub = r.emails.watchJmapPush('jmap-1', 'pw').listen(emitted.add);

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

  // ── Blob expiry (TTL) tests ───────────────────────────────────────────────────

  group('blob expiry', () {
    test('returns cached body when cachedAt is recent', () async {
      // Uses _makeRepos (IMAP throws if called) — passing without error proves
      // no IMAP connection was made.
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
      await r.db.into(r.db.emailBodies).insertOnConflictUpdate(
            EmailBodiesCompanion.insert(
              emailId: 'acc-1:1',
              textBody: const Value('cached text'),
              cachedAt: Value(DateTime.now()),
            ),
          );

      final body = await r.emails.getEmailBody('acc-1:1');

      expect(body.textBody, 'cached text');
    });
  });

  // ── Failed mutations tests ────────────────────────────────────────────────────

  group('failed mutations', () {
    test('observeFailedMutations emits only rows with lastError set', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      await r.db.into(r.db.pendingChanges).insert(
            PendingChangesCompanion.insert(
              accountId: 'acc-1',
              resourceType: 'email',
              resourceId: 'acc-1:10',
              changeType: 'flag_seen',
              payload: '{"seen":true}',
              createdAt: DateTime.now(),
              lastError: const Value('network error'),
            ),
          );
      await r.db.into(r.db.pendingChanges).insert(
            PendingChangesCompanion.insert(
              accountId: 'acc-1',
              resourceType: 'email',
              resourceId: 'acc-1:11',
              changeType: 'move',
              payload: '{"dest":"Archive"}',
              createdAt: DateTime.now(),
              // lastError not set → pending, not failed
            ),
          );

      final mutations = await r.emails.observeFailedMutations('acc-1').first;

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

  group('concurrent moves', () {
    test(
      'two simultaneous moves enqueue two changes and leave email in last destination',
      () async {
        final r = _makeRepos();
        await r.accounts.addAccount(_account, 'pw');
        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: 'acc-1:5',
                accountId: 'acc-1',
                mailboxPath: 'INBOX',
                uid: 5,
                receivedAt: DateTime(2024),
              ),
            );

        // Fire both moves without awaiting to exercise concurrent enqueue logic.
        final f1 = r.emails.moveEmail('acc-1:5', 'Archive');
        final f2 = r.emails.moveEmail('acc-1:5', 'Trash');
        await Future.wait([f1, f2]);

        final changes = await r.db.select(r.db.pendingChanges).get();
        expect(changes, hasLength(2));
        expect(changes.map((c) => c.changeType), everyElement('move'));

        final destinations =
            changes.map((c) => (jsonDecode(c.payload) as Map)['dest']).toSet();
        expect(destinations, containsAll(['Archive', 'Trash']));

        final email = await r.emails.getEmail('acc-1:5');
        expect(
          email!.mailboxPath,
          anyOf('Archive', 'Trash'),
          reason:
              'email must be optimistically moved to one of the two destinations',
        );
      },
    );
  });

  group('IMAP SMTP auth failure', () {
    test('sendEmail propagates SMTP authentication error', () async {
      final r = _makeRepos(
        smtpConnect: (Account _, String __, String ___) => Future.error(
          Exception('535 5.7.8 Authentication credentials invalid'),
        ),
      );
      await r.accounts.addAccount(_account, 'pw');

      const draft = EmailDraft(
        from: EmailAddress(name: 'Alice', email: 'alice@example.com'),
        to: [EmailAddress(name: 'Bob', email: 'bob@example.com')],
        cc: [],
        subject: 'Test',
        body: 'Body',
      );

      await expectLater(
        r.emails.sendEmail('acc-1', draft),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('535'),
          ),
        ),
      );
    });
  });

  group('IMAP UID validity change', () {
    test('full re-sync wipes stale emails when uidValidity changes', () async {
      final r = _makeRepos(
        imapConnect: (Account _, String __, String ___) async =>
            _FakeImapClientUidValidity(456),
      );
      await r.accounts.addAccount(_account, 'pw');

      // Pre-seed two emails from the old server epoch (uidValidity=123).
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:1',
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              uid: 1,
              receivedAt: DateTime(2024),
            ),
          );
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:2',
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              uid: 2,
              receivedAt: DateTime(2024),
            ),
          );

      // Seed an IMAP checkpoint with the old uidValidity so the code detects
      // a mismatch and triggers a full re-sync.
      await r.db.into(r.db.syncStates).insertOnConflictUpdate(
            SyncStatesCompanion.insert(
              accountId: 'acc-1',
              resourceType: 'IMAP:INBOX',
              state: '{"uidValidity":123,"lastUid":2,"highestModSeq":null}',
              syncedAt: DateTime(2024),
            ),
          );

      await r.emails.syncEmails('acc-1', 'INBOX');

      // Old emails must be wiped; the fake server returns zero messages.
      final remaining = await r.db.select(r.db.emails).get();
      expect(remaining, isEmpty);

      // Checkpoint must be updated to the new uidValidity.
      final stateRow = await (r.db.select(r.db.syncStates)
            ..where(
              (t) =>
                  t.accountId.equals('acc-1') &
                  t.resourceType.equals('IMAP:INBOX'),
            ))
          .getSingleOrNull();
      expect(stateRow, isNotNull);
      final state = jsonDecode(stateRow!.state) as Map<String, dynamic>;
      expect(state['uidValidity'], 456);
    });
  });
}

// ── Additional fake IMAP client for UID-validity tests ───────────────────────

class _FakeImapClientUidValidity extends FakeImapClient {
  _FakeImapClientUidValidity(this._uidValidity);
  final int _uidValidity;

  @override
  Future<imap.Mailbox> selectMailboxByPath(
    String path, {
    bool enableCondStore = false,
    imap.QResyncParameters? qresync,
  }) async =>
      imap.Mailbox(
        encodedName: path,
        encodedPath: path,
        flags: [],
        pathSeparator: '/',
        uidValidity: _uidValidity,
      );

  @override
  Future<imap.SearchImapResult> uidSearchMessages({
    String searchCriteria = 'ALL',
    List<imap.ReturnOption>? returnOptions,
    Duration? responseTimeout,
  }) async =>
      imap.SearchImapResult();
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
      return http.StreamedResponse(Stream.value(utf8.encode(session)), 200);
    }
    if (request.headers['Accept'] == 'text/event-stream') {
      return http.StreamedResponse(sseStream, 200);
    }
    return http.StreamedResponse(Stream.value(utf8.encode('{}')), 200);
  }
}
