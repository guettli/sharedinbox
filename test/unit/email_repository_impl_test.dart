import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/filter/similar_filter.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account, Email;
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

// A matching IMAP/JMAP pair pointing at the *same* server (same host + user),
// used to exercise cross-protocol snooze mirroring (see [AccountComparison]).
const _imapPair = Account(
  id: 'imap-p',
  displayName: 'Alice',
  email: 'alice@example.com',
  imapHost: 'mail.example.com',
  smtpHost: 'smtp.example.com',
);

const _jmapPair = Account(
  id: 'jmap-p',
  displayName: 'Alice',
  email: 'alice@example.com',
  type: AccountType.jmap,
  jmapUrl: 'https://mail.example.com/.well-known/jmap',
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
  Duration? sendOperationTimeout,
  AppLogger? appLogger,
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
    sendOperationTimeout: sendOperationTimeout ?? const Duration(seconds: 50),
    appLogger: appLogger,
  );
  return (db: db, accounts: accounts, emails: emails);
}

/// Minimal in-memory [AppLogRepository] used by the JMAP push tests to
/// observe the `push_status` sequence written by `watchJmapPush`. Only the
/// insert path is exercised — everything else is inherited as a no-op from
/// [NoOpAppLogRepository].
class _PushStatusRecorder extends NoOpAppLogRepository {
  final List<AppLogEntry> entries = [];
  int _nextId = 1;

  @override
  Future<int?> insert({
    required AppLogLevel level,
    required String event,
    required String message,
    String? dataJson,
    String? screen,
    String? accountId,
    String? mailboxPath,
    String? emailId,
    int? syncLogId,
    DateTime? createdAt,
  }) async {
    final id = _nextId++;
    entries.add(
      AppLogEntry(
        id: id,
        createdAt: createdAt ?? DateTime.now(),
        level: level,
        event: event,
        message: message,
        dataJson: dataJson,
        screen: screen,
        accountId: accountId,
        mailboxPath: mailboxPath,
        emailId: emailId,
        syncLogId: syncLogId,
      ),
    );
    return id;
  }
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
              // Populate the metadata fields so the cache hit logic
              // doesn't treat the row as a legacy entry and refetch.
              headersJson: const Value('[]'),
              mimeTreeJson: const Value('{"type":"text/plain"}'),
              cachedAt: Value(DateTime.now()),
            ),
          );

      final body = await r.emails.getEmailBody('acc-1:1');
      expect(body.textBody, 'Hello');
      expect(body.htmlBody, '<p>Hello</p>');
    });

    // ── JMAP body parsing ────────────────────────────────────────────────────

    group('parseJmapBody type guarding', () {
      // JMAP's textBody/htmlBody fall back to the other representation for
      // single-part mail (RFC 8621 §4.1.4). The parser must key on the part's
      // MIME `type` so the cached columns match the IMAP path, which uses the
      // type-specific decodeTextPlainPart()/decodeTextHtmlPart() (#514).

      test('HTML-only mail leaves textBody null, keeps htmlBody', () {
        final r = _makeRepos();
        final (textBody, htmlBody, _) = r.emails.parseJmapBodyForTest({
          'textBody': [
            {'partId': '1', 'type': 'text/html'},
          ],
          'htmlBody': [
            {'partId': '1', 'type': 'text/html'},
          ],
          'bodyValues': {
            '1': {'value': '<html><body>Hi</body></html>'},
          },
        });
        expect(textBody, isNull);
        expect(htmlBody, '<html><body>Hi</body></html>');
      });

      test('plain-only mail leaves htmlBody null, keeps textBody', () {
        final r = _makeRepos();
        final (textBody, htmlBody, _) = r.emails.parseJmapBodyForTest({
          'textBody': [
            {'partId': '1', 'type': 'text/plain'},
          ],
          'htmlBody': [
            {'partId': '1', 'type': 'text/plain'},
          ],
          'bodyValues': {
            '1': {'value': 'Plain hello'},
          },
        });
        expect(textBody, 'Plain hello');
        expect(htmlBody, isNull);
      });

      test('multipart/alternative fills both from their matching parts', () {
        final r = _makeRepos();
        final (textBody, htmlBody, _) = r.emails.parseJmapBodyForTest({
          'textBody': [
            {'partId': '1', 'type': 'text/plain'},
          ],
          'htmlBody': [
            {'partId': '2', 'type': 'text/html'},
          ],
          'bodyValues': {
            '1': {'value': 'Plain hello'},
            '2': {'value': '<p>Hello</p>'},
          },
        });
        expect(textBody, 'Plain hello');
        expect(htmlBody, '<p>Hello</p>');
      });
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

    test('observeThreads returns starred threads before unstarred', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');

      // Insert four threads: two starred (one old, one very old) and two
      // unstarred (one newest, one middle). Starred must come first even
      // though an unstarred thread has the newest date.
      Future<void> insertThread(
        String id,
        DateTime date, {
        required bool flagged,
      }) {
        return r.db.into(r.db.threads).insert(
              ThreadsCompanion.insert(
                id: id,
                accountId: 'acc-1',
                mailboxPath: 'INBOX',
                latestDate: date,
                isFlagged: Value(flagged),
                latestEmailId: '$id-latest',
              ),
            );
      }

      await insertThread('unstarred-new', DateTime(2024, 6), flagged: false);
      await insertThread('starred-old', DateTime(2024, 2), flagged: true);
      await insertThread('unstarred-mid', DateTime(2024, 4), flagged: false);
      await insertThread('starred-mid', DateTime(2024, 3), flagged: true);

      final threads = await r.emails.observeThreads('acc-1', 'INBOX').first;
      expect(
        threads.map((t) => t.threadId).toList(),
        ['starred-mid', 'starred-old', 'unstarred-new', 'unstarred-mid'],
      );
    });

    test(
      'observeAllInboxThreads returns starred threads before unstarred',
      () async {
        final r = _makeRepos();
        await r.accounts.addAccount(_account, 'pw');
        const account2 = Account(
          id: 'acc-2',
          displayName: 'Bob',
          email: 'bob@example.com',
          imapHost: 'imap.example.com',
          smtpHost: 'smtp.example.com',
        );
        await r.accounts.addAccount(account2, 'pw');

        for (final (accountId, path) in [
          ('acc-1', 'INBOX'),
          ('acc-2', 'INBOX'),
        ]) {
          await r.db.into(r.db.mailboxes).insert(
                MailboxesCompanion.insert(
                  id: '$accountId:$path',
                  accountId: accountId,
                  path: path,
                  name: path,
                  role: const Value('inbox'),
                ),
              );
        }

        Future<void> insertThread(
          String accountId,
          String id,
          DateTime date, {
          required bool flagged,
        }) {
          return r.db.into(r.db.threads).insert(
                ThreadsCompanion.insert(
                  id: id,
                  accountId: accountId,
                  mailboxPath: 'INBOX',
                  latestDate: date,
                  isFlagged: Value(flagged),
                  latestEmailId: '$id-latest',
                ),
              );
        }

        await insertThread('acc-1', 't-a', DateTime(2024, 6), flagged: false);
        await insertThread('acc-2', 't-b', DateTime(2024, 2), flagged: true);
        await insertThread('acc-1', 't-c', DateTime(2024, 5), flagged: true);
        await insertThread('acc-2', 't-d', DateTime(2024, 4), flagged: false);

        final threads = await r.emails.observeAllInboxThreads().first;
        expect(
          threads.map((t) => t.threadId).toList(),
          ['t-c', 't-b', 't-a', 't-d'],
        );
      },
    );

    group('sweepOrphanThreads (#523)', () {
      // Seeds one real email in `Done` plus [orphanCount] thread rows whose ids
      // are not backed by that email — the "18 threads, 1 email" shape from
      // #523. Follows the `seedInboxThread(r, ...)` pattern used below.
      Future<void> seedOrphans(
        ({
          AppDatabase db,
          AccountRepositoryImpl accounts,
          EmailRepositoryImpl emails
        }) r, {
        int orphanCount = 17,
      }) async {
        await r.accounts.addAccount(_account, 'pw');

        // One real email whose thread row is legitimately backed.
        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: 'acc-1:1',
                accountId: 'acc-1',
                mailboxPath: 'Done',
                uid: 1,
                receivedAt: DateTime(2024),
                threadId: const Value('tid-live'),
              ),
            );
        await r.db.into(r.db.threads).insert(
              ThreadsCompanion.insert(
                id: 'tid-live',
                accountId: 'acc-1',
                mailboxPath: 'Done',
                latestDate: DateTime(2024),
                latestEmailId: 'acc-1:1',
              ),
            );
        // Orphan thread rows backed by no email in the folder.
        for (var i = 0; i < orphanCount; i++) {
          await r.db.into(r.db.threads).insert(
                ThreadsCompanion.insert(
                  id: 'orphan-$i',
                  accountId: 'acc-1',
                  mailboxPath: 'Done',
                  latestDate: DateTime(2024),
                  latestEmailId: 'orphan-$i-latest',
                ),
              );
        }
      }

      test('removes orphan rows and keeps the backed thread', () async {
        final r = _makeRepos();
        await seedOrphans(r, orphanCount: 17);

        // Before: the folder view shows all 18 phantom+real rows.
        expect(
          await r.emails.observeThreads('acc-1', 'Done').first,
          hasLength(18),
        );

        final removed = await r.emails.sweepOrphanThreads('acc-1', 'Done');
        expect(removed, 17);

        final remaining = await r.emails.observeThreads('acc-1', 'Done').first;
        expect(remaining, hasLength(1));
        expect(remaining.single.threadId, 'tid-live');
      });

      test('is a no-op on a healthy folder', () async {
        final r = _makeRepos();
        await seedOrphans(r, orphanCount: 0);
        expect(await r.emails.sweepOrphanThreads('acc-1', 'Done'), 0);
        expect(
          await r.emails.observeThreads('acc-1', 'Done').first,
          hasLength(1),
        );
      });

      test('removes every thread when the folder has no emails', () async {
        final r = _makeRepos();
        await r.accounts.addAccount(_account, 'pw');
        for (var i = 0; i < 3; i++) {
          await r.db.into(r.db.threads).insert(
                ThreadsCompanion.insert(
                  id: 'ghost-$i',
                  accountId: 'acc-1',
                  mailboxPath: 'Done',
                  latestDate: DateTime(2024),
                  latestEmailId: 'ghost-$i-latest',
                ),
              );
        }
        expect(await r.emails.sweepOrphanThreads('acc-1', 'Done'), 3);
        expect(await r.emails.observeThreads('acc-1', 'Done').first, isEmpty);
      });

      test('does not touch another folder', () async {
        final r = _makeRepos();
        await seedOrphans(r, orphanCount: 2);
        await r.db.into(r.db.threads).insert(
              ThreadsCompanion.insert(
                id: 'orphan-0',
                accountId: 'acc-1',
                mailboxPath: 'INBOX',
                latestDate: DateTime(2024),
                latestEmailId: 'inbox-latest',
              ),
            );
        await r.emails.sweepOrphanThreads('acc-1', 'Done');
        // The identically-named row in INBOX is untouched (per-folder scope).
        expect(
          await r.emails.observeThreads('acc-1', 'INBOX').first,
          hasLength(1),
        );
      });
    });

    group('observeAllInboxThreads counterpart de-duplication', () {
      // Inserts an inbox mailbox, a message and its inbox thread for [account].
      // The thread's latest message carries [messageId] so counterpart copies
      // of the same server message can be collapsed.
      Future<void> seedInboxThread(
        ({
          AppDatabase db,
          AccountRepositoryImpl accounts,
          EmailRepositoryImpl emails
        }) r, {
        required String accountId,
        required String threadId,
        required String emailId,
        required String? messageId,
        DateTime? date,
      }) async {
        date ??= DateTime(2024, 6);
        final existingInbox = await (r.db.select(r.db.mailboxes)
              ..where(
                (t) => t.accountId.equals(accountId) & t.role.equals('inbox'),
              ))
            .getSingleOrNull();
        if (existingInbox == null) {
          await r.db.into(r.db.mailboxes).insert(
                MailboxesCompanion.insert(
                  id: '$accountId:INBOX',
                  accountId: accountId,
                  path: 'INBOX',
                  name: 'INBOX',
                  role: const Value('inbox'),
                ),
              );
        }
        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: emailId,
                accountId: accountId,
                mailboxPath: 'INBOX',
                uid: 0,
                receivedAt: date,
                messageId: Value(messageId),
              ),
            );
        await r.db.into(r.db.threads).insert(
              ThreadsCompanion.insert(
                id: threadId,
                accountId: accountId,
                mailboxPath: 'INBOX',
                latestDate: date,
                latestEmailId: emailId,
              ),
            );
      }

      test('collapses counterpart copies to the IMAP row', () async {
        final r = _makeRepos();
        await r.accounts.addAccount(_imapPair, 'pw');
        await r.accounts.addAccount(_jmapPair, 'pw');

        // Same message, different Message-ID flavours (IMAP keeps the angle
        // brackets, JMAP drops them) — must still be recognised as one mail.
        await seedInboxThread(
          r,
          accountId: 'imap-p',
          threadId: 'imap-t',
          emailId: 'imap-p:5',
          messageId: '<abc@example.com>',
        );
        await seedInboxThread(
          r,
          accountId: 'jmap-p',
          threadId: 'jmap-t',
          emailId: 'jmap-p:e1',
          messageId: 'abc@example.com',
        );

        final threads = await r.emails.observeAllInboxThreads().first;
        expect(threads, hasLength(1));
        expect(threads.first.accountId, 'imap-p');
        expect(threads.first.threadId, 'imap-t');
      });

      test('keeps both copies for non-counterpart accounts', () async {
        final r = _makeRepos();
        // Same host but both IMAP → not a comparable pair; and a genuinely
        // different account. Either way, the shared Message-ID must not merge.
        await r.accounts.addAccount(_account, 'pw');
        const account2 = Account(
          id: 'acc-2',
          displayName: 'Bob',
          email: 'bob@example.com',
          imapHost: 'imap.example.com',
          smtpHost: 'smtp.example.com',
        );
        await r.accounts.addAccount(account2, 'pw');

        await seedInboxThread(
          r,
          accountId: 'acc-1',
          threadId: 'a-t',
          emailId: 'acc-1:1',
          messageId: 'shared@example.com',
        );
        await seedInboxThread(
          r,
          accountId: 'acc-2',
          threadId: 'b-t',
          emailId: 'acc-2:1',
          messageId: 'shared@example.com',
        );

        final threads = await r.emails.observeAllInboxThreads().first;
        expect(
          threads.map((t) => t.threadId).toSet(),
          {'a-t', 'b-t'},
        );
      });

      test('never merges counterpart threads without a Message-ID', () async {
        final r = _makeRepos();
        await r.accounts.addAccount(_imapPair, 'pw');
        await r.accounts.addAccount(_jmapPair, 'pw');

        await seedInboxThread(
          r,
          accountId: 'imap-p',
          threadId: 'imap-t',
          emailId: 'imap-p:5',
          messageId: null,
        );
        await seedInboxThread(
          r,
          accountId: 'jmap-p',
          threadId: 'jmap-t',
          emailId: 'jmap-p:e1',
          messageId: null,
        );

        final threads = await r.emails.observeAllInboxThreads().first;
        expect(
          threads.map((t) => t.threadId).toSet(),
          {'imap-t', 'jmap-t'},
        );
      });
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

    group('computeThreadIdForTest (IMAP reference-chain walking)', () {
      test('root-only: no References/In-Reply-To → own Message-ID', () {
        expect(
          EmailRepositoryImpl.computeThreadIdForTest(
            messageId: 'root@example.com',
            inReplyTo: null,
            references: null,
            subject: 'Original',
            date: DateTime.utc(2024, 3),
          ),
          'root@example.com',
        );
      });

      test('deep chain: References first entry (= oldest ancestor) wins', () {
        // JWZ: every reply carries the whole chain in References, oldest first.
        expect(
          EmailRepositoryImpl.computeThreadIdForTest(
            messageId: 'reply3@example.com',
            inReplyTo: 'reply2@example.com',
            references: 'root@example.com reply1@example.com '
                'reply2@example.com',
            subject: 'Re: Original',
            date: DateTime.utc(2024, 3, 3),
          ),
          'root@example.com',
        );
      });

      test('broken chain: no References → falls back to In-Reply-To', () {
        // Some clients drop References but keep In-Reply-To. The reply must
        // still land in the same thread as its immediate parent.
        expect(
          EmailRepositoryImpl.computeThreadIdForTest(
            messageId: 'reply@example.com',
            inReplyTo: 'root@example.com',
            references: null,
            subject: 'Re: Original',
            date: DateTime.utc(2024, 3, 2),
          ),
          'root@example.com',
        );
      });

      test('subject fallback: no headers → subj:yyyy-mm:<normalised subject>',
          () {
        expect(
          EmailRepositoryImpl.computeThreadIdForTest(
            messageId: null,
            inReplyTo: null,
            references: null,
            subject: 'Re: Fwd: Project Alpha',
            date: DateTime.utc(2024, 5, 15),
          ),
          'subj:2024-05:project alpha',
        );
      });

      test('subject fallback groups matching subjects within same month', () {
        final key1 = EmailRepositoryImpl.computeThreadIdForTest(
          messageId: null,
          inReplyTo: null,
          references: null,
          subject: 'Project Alpha',
          date: DateTime.utc(2024, 5, 2, 8),
        );
        final key2 = EmailRepositoryImpl.computeThreadIdForTest(
          messageId: null,
          inReplyTo: null,
          references: null,
          subject: 'Re: Project Alpha',
          date: DateTime.utc(2024, 5, 30, 23, 59),
        );
        expect(key1, isNotNull);
        expect(key1, key2);
      });

      test('subject fallback splits threads across month boundaries', () {
        final key1 = EmailRepositoryImpl.computeThreadIdForTest(
          messageId: null,
          inReplyTo: null,
          references: null,
          subject: 'Project Alpha',
          date: DateTime.utc(2024, 5, 31),
        );
        final key2 = EmailRepositoryImpl.computeThreadIdForTest(
          messageId: null,
          inReplyTo: null,
          references: null,
          subject: 'Project Alpha',
          date: DateTime.utc(2024, 6),
        );
        expect(key1, isNot(key2));
      });

      test('everything missing: returns null so caller uses emailId', () {
        // Subject omitted (defaults to null) — the true "no signal" case.
        expect(
          EmailRepositoryImpl.computeThreadIdForTest(
            messageId: null,
            inReplyTo: null,
            references: null,
            date: DateTime.utc(2024),
          ),
          isNull,
        );
        // Empty subject after normalisation also yields null.
        expect(
          EmailRepositoryImpl.computeThreadIdForTest(
            messageId: null,
            inReplyTo: null,
            references: null,
            subject: '',
            date: DateTime.utc(2024),
          ),
          isNull,
        );
      });
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

    test('searchEmailsGlobal matches a single word only in the body', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');

      // Subject/preview do NOT contain the term — only the cached body does.
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:1',
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              uid: 1,
              subject: const Value('Trip planning'),
              receivedAt: DateTime(2024),
            ),
          );
      await r.db.into(r.db.emailBodies).insert(
            EmailBodiesCompanion.insert(
              emailId: 'acc-1:1',
              textBody: const Value('Please book the flamingo sanctuary tour'),
            ),
          );

      final results = await r.emails.searchEmailsGlobal(null, 'flamingo');
      expect(results, hasLength(1));
      expect(results.first.id, 'acc-1:1');
    });

    test('searchEmailsGlobal keeps AND-across-words semantics in the body',
        () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');

      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:2',
              accountId: 'acc-1',
              mailboxPath: 'Archive',
              uid: 2,
              subject: const Value('Weekend outing'),
              receivedAt: DateTime(2023),
            ),
          );
      await r.db.into(r.db.emailBodies).insert(
            EmailBodiesCompanion.insert(
              emailId: 'acc-1:2',
              textBody: const Value('Reserve the pelican lagoon cruise'),
            ),
          );

      // Both words present in the body — implicit AND matches.
      final both = await r.emails.searchEmailsGlobal(null, 'pelican cruise');
      expect(both, hasLength(1));

      // One word missing from the body — AND semantics reject the row.
      final partial = await r.emails.searchEmailsGlobal(null, 'pelican walrus');
      expect(partial, isEmpty);
    });

    test('searchEmailsGlobal returns nothing when the body does not match',
        () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');

      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:3',
              accountId: 'acc-1',
              mailboxPath: 'Sent',
              uid: 3,
              subject: const Value('Invoice due'),
              receivedAt: DateTime(2022),
            ),
          );
      await r.db.into(r.db.emailBodies).insert(
            EmailBodiesCompanion.insert(
              emailId: 'acc-1:3',
              textBody: const Value('Payment received for order eighty'),
            ),
          );

      final results = await r.emails.searchEmailsGlobal(null, 'kangaroo');
      expect(results, isEmpty);
    });

    test('searchEmailsGlobal picks up body inserts via the FTS trigger',
        () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');

      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:4',
              accountId: 'acc-1',
              mailboxPath: 'Drafts',
              uid: 4,
              subject: const Value('Standup notes'),
              receivedAt: DateTime(2021),
            ),
          );

      // No body yet — nothing to match.
      expect(
        await r.emails.searchEmailsGlobal(null, 'dolphin'),
        isEmpty,
      );

      // Inserting the body after the email must keep the FTS index in sync
      // via the email_body_fts_ai trigger.
      await r.db.into(r.db.emailBodies).insert(
            EmailBodiesCompanion.insert(
              emailId: 'acc-1:4',
              textBody: const Value('The dolphin workshop starts at noon'),
            ),
          );

      final results = await r.emails.searchEmailsGlobal(null, 'dolphin');
      expect(results, hasLength(1));
      expect(results.first.id, 'acc-1:4');
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

    test('searchEmailsGlobal note search uses FTS prefix semantics', () async {
      // Notes search runs against the email_notes_fts virtual table and uses
      // the same _toFtsQuery prefix builder as subject search: a query of
      // 'foll' must match a note containing 'follow-up' (prefix), but a query
      // of 'low' must NOT match (FTS5 indexes whole tokens, not substrings).
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');

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
      await r.db.into(r.db.emailNotes).insert(
            EmailNotesCompanion.insert(
              id: 'note-1',
              accountId: 'acc-1',
              messageId: '<msg1@example.com>',
              noteText: 'urgent follow-up needed',
              serverId: '42',
              createdAt: DateTime(2024),
            ),
          );

      final prefix = await r.emails.searchEmailsGlobal(null, 'foll');
      expect(prefix, hasLength(1));
      expect(prefix.first.subject, 'Weekly report');

      // 'low' is not a prefix of any token in the note ('urgent',
      // 'follow', 'up', 'needed'), so FTS5 must not return a match.
      final substring = await r.emails.searchEmailsGlobal(null, 'low');
      expect(substring, isEmpty);
    });

    test('searchEmailsGlobal note search picks up note inserts via FTS trigger',
        () async {
      // Inserting a note after the email already exists must keep the FTS
      // index in sync via the email_notes_fts_ai trigger.
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

      // Sanity: before the note is inserted, the search returns nothing.
      expect(
        await r.emails.searchEmailsGlobal(null, 'unicorn'),
        isEmpty,
      );

      await r.db.into(r.db.emailNotes).insert(
            EmailNotesCompanion.insert(
              id: 'note-1',
              accountId: 'acc-1',
              messageId: '<msg1@example.com>',
              noteText: 'unicorn migration plan',
              serverId: '42',
              createdAt: DateTime(2024),
            ),
          );

      final results = await r.emails.searchEmailsGlobal(null, 'unicorn');
      expect(results, hasLength(1));
      expect(results.first.subject, 'Project update');
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

    test('searchEmailsGlobal returns starred results before unstarred',
        () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');

      // Older starred email must appear above a newer unstarred one.
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:1',
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              uid: 1,
              subject: const Value('Older starred report'),
              receivedAt: DateTime(2024),
              isFlagged: const Value(true),
            ),
          );
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:2',
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              uid: 2,
              subject: const Value('Newer plain report'),
              receivedAt: DateTime(2024, 6),
            ),
          );

      final results = await r.emails.searchEmailsGlobal(null, 'report');
      expect(results, hasLength(2));
      expect(results[0].subject, 'Older starred report');
      expect(results[1].subject, 'Newer plain report');
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
      'searchEmailsStructured returns results sorted by receivedAt descending',
      () async {
        final r = _makeRepos();
        await r.accounts.addAccount(_account, 'pw');

        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: 'acc-1:1',
                accountId: 'acc-1',
                mailboxPath: 'INBOX',
                uid: 1,
                subject: const Value('Older invoice'),
                receivedAt: DateTime(2024),
              ),
            );
        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: 'acc-1:2',
                accountId: 'acc-1',
                mailboxPath: 'INBOX',
                uid: 2,
                subject: const Value('Newer invoice'),
                receivedAt: DateTime(2024, 6),
              ),
            );

        final filter = FilterGroup(
          operator: FilterOperator.and_,
          children: [
            FilterLeaf(
              field: FilterField.subject,
              comparison: FilterComparison.contains,
              value: 'invoice',
            ),
          ],
        );
        final results = await r.emails.searchEmailsStructured(null, filter);
        expect(results, hasLength(2));
        expect(results[0].subject, 'Newer invoice');
        expect(results[1].subject, 'Older invoice');
      },
    );

    test(
      'searchEmailsStructured returns starred results before unstarred',
      () async {
        final r = _makeRepos();
        await r.accounts.addAccount(_account, 'pw');

        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: 'acc-1:1',
                accountId: 'acc-1',
                mailboxPath: 'INBOX',
                uid: 1,
                subject: const Value('Older starred invoice'),
                receivedAt: DateTime(2024),
                isFlagged: const Value(true),
              ),
            );
        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: 'acc-1:2',
                accountId: 'acc-1',
                mailboxPath: 'INBOX',
                uid: 2,
                subject: const Value('Newer plain invoice'),
                receivedAt: DateTime(2024, 6),
              ),
            );

        final filter = FilterGroup(
          operator: FilterOperator.and_,
          children: [
            FilterLeaf(
              field: FilterField.subject,
              comparison: FilterComparison.contains,
              value: 'invoice',
            ),
          ],
        );
        final results = await r.emails.searchEmailsStructured(null, filter);
        expect(results, hasLength(2));
        expect(results[0].subject, 'Older starred invoice');
        expect(results[1].subject, 'Newer plain invoice');
      },
    );

    test(
      'searchEmailsStructured with header filter matches cached headers',
      () async {
        final r = _makeRepos();
        await r.accounts.addAccount(_account, 'pw');

        // Two emails; only the first has a matching List-Id header cached in
        // email_bodies.headers_json. The third has no body row at all, so it
        // must be excluded (documented limitation).
        for (final id in ['acc-1:1', 'acc-1:2', 'acc-1:3']) {
          await r.db.into(r.db.emails).insert(
                EmailsCompanion.insert(
                  id: id,
                  accountId: 'acc-1',
                  mailboxPath: 'INBOX',
                  uid: int.parse(id.split(':').last),
                  receivedAt: DateTime(2026, 1, int.parse(id.split(':').last)),
                ),
              );
        }
        await r.db.into(r.db.emailBodies).insert(
              EmailBodiesCompanion.insert(
                emailId: 'acc-1:1',
                headersJson: const Value(
                  '[{"name":"List-Id","value":"<news.example.com>"},'
                  '{"name":"From","value":"news@example.com"}]',
                ),
              ),
            );
        await r.db.into(r.db.emailBodies).insert(
              EmailBodiesCompanion.insert(
                emailId: 'acc-1:2',
                headersJson: const Value(
                  '[{"name":"List-Id","value":"<other.example.com>"}]',
                ),
              ),
            );

        final filter = FilterGroup(
          operator: FilterOperator.and_,
          children: [
            FilterLeaf(
              field: FilterField.header,
              comparison: FilterComparison.is_,
              value: '<news.example.com>',
              headerName: 'List-Id',
            ),
          ],
        );
        final results = await r.emails.searchEmailsStructured('acc-1', filter);
        expect(results.map((e) => e.id), ['acc-1:1']);

        final containsFilter = FilterGroup(
          operator: FilterOperator.and_,
          children: [
            FilterLeaf(
              field: FilterField.header,
              comparison: FilterComparison.contains,
              value: 'example.com',
              headerName: 'List-Id',
            ),
          ],
        );
        final containsResults = await r.emails.searchEmailsStructured(
          'acc-1',
          containsFilter,
        );
        expect(
          containsResults.map((e) => e.id),
          unorderedEquals(['acc-1:1', 'acc-1:2']),
        );
      },
    );

    test(
      'searchEmailsStructured with folder filter matches by mailbox path',
      () async {
        final r = _makeRepos();
        await r.accounts.addAccount(_account, 'pw');

        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: 'acc-1:inbox',
                accountId: 'acc-1',
                mailboxPath: 'INBOX',
                uid: 1,
                subject: const Value('Hello inbox'),
                receivedAt: DateTime(2026),
              ),
            );
        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: 'acc-1:archive',
                accountId: 'acc-1',
                mailboxPath: 'Archive',
                uid: 2,
                subject: const Value('Hello archive'),
                receivedAt: DateTime(2026, 2),
              ),
            );

        final inboxFilter = FilterGroup(
          operator: FilterOperator.and_,
          children: [
            FilterLeaf(
              field: FilterField.folder,
              comparison: FilterComparison.is_,
              value: 'INBOX',
            ),
          ],
        );
        final inboxResults =
            await r.emails.searchEmailsStructured('acc-1', inboxFilter);
        expect(inboxResults.map((e) => e.id), ['acc-1:inbox']);

        final archiveFilter = FilterGroup(
          operator: FilterOperator.and_,
          children: [
            FilterLeaf(
              field: FilterField.folder,
              comparison: FilterComparison.is_,
              value: 'archive',
            ),
          ],
        );
        final archiveResults =
            await r.emails.searchEmailsStructured('acc-1', archiveFilter);
        expect(archiveResults.map((e) => e.id), ['acc-1:archive']);
      },
    );

    test(
      'searchEmailsStructured with similarFilterFor finds near-duplicate spam',
      () async {
        final r = _makeRepos();
        await r.accounts.addAccount(_account, 'pw');

        const spammerFrom = '[{"name":"Spam","email":"spam@bad.com"}]';
        const otherFrom = '[{"name":"Bob","email":"bob@example.com"}]';

        // Three messages from spam@bad.com with the same subject "core",
        // differing only by Re:/Fwd:/ticket noise, plus one decoy from Bob.
        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: 'acc-1:1',
                accountId: 'acc-1',
                mailboxPath: 'INBOX',
                uid: 1,
                subject: const Value('You won a prize!'),
                receivedAt: DateTime(2026),
                fromJson: const Value(spammerFrom),
              ),
            );
        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: 'acc-1:2',
                accountId: 'acc-1',
                mailboxPath: 'INBOX',
                uid: 2,
                subject: const Value('Re: You won a prize!'),
                receivedAt: DateTime(2026, 2),
                fromJson: const Value(spammerFrom),
              ),
            );
        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: 'acc-1:3',
                accountId: 'acc-1',
                mailboxPath: 'INBOX',
                uid: 3,
                subject: const Value('Fwd: [TKT-9] You won a prize!'),
                receivedAt: DateTime(2026, 3),
                fromJson: const Value(spammerFrom),
              ),
            );
        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: 'acc-1:4',
                accountId: 'acc-1',
                mailboxPath: 'INBOX',
                uid: 4,
                subject: const Value('You won a prize!'),
                receivedAt: DateTime(2026, 4),
                fromJson: const Value(otherFrom),
              ),
            );

        final seed = Email(
          id: 'seed',
          accountId: 'acc-1',
          mailboxPath: 'INBOX',
          uid: 99,
          subject: 'Re: You won a prize!',
          receivedAt: DateTime(2026),
          from: const [EmailAddress(email: 'spam@bad.com')],
          to: const [],
          cc: const [],
          isSeen: false,
          isFlagged: false,
          hasAttachment: false,
        );
        final filter = similarFilterFor(seed);
        final results = await r.emails.searchEmailsStructured('acc-1', filter);

        // All three spam variants match; Bob's decoy does not.
        expect(
          results.map((e) => e.id),
          unorderedEquals(['acc-1:1', 'acc-1:2', 'acc-1:3']),
        );
      },
    );

    test(
      'getEmailsByAddress returns results sorted by receivedAt descending',
      () async {
        final r = _makeRepos();
        await r.accounts.addAccount(_account, 'pw');

        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: 'acc-1:1',
                accountId: 'acc-1',
                mailboxPath: 'INBOX',
                uid: 1,
                subject: const Value('Older hello'),
                receivedAt: DateTime(2024),
                fromJson: const Value(
                  '[{"name":"Bob","email":"bob@example.com"}]',
                ),
              ),
            );
        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: 'acc-1:2',
                accountId: 'acc-1',
                mailboxPath: 'INBOX',
                uid: 2,
                subject: const Value('Newer hello'),
                receivedAt: DateTime(2024, 6),
                fromJson: const Value(
                  '[{"name":"Bob","email":"bob@example.com"}]',
                ),
              ),
            );

        final results =
            await r.emails.getEmailsByAddress(null, 'bob@example.com');
        expect(results, hasLength(2));
        expect(results[0].subject, 'Newer hello');
        expect(results[1].subject, 'Older hello');
      },
    );

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
      'moving every mail out of a folder empties it, incl. orphan thread rows',
      () async {
        final r = _makeRepos();
        await r.accounts.addAccount(_account, 'pw');

        // One email in 'foo' with an up-to-date thread row.
        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: 'acc-1:e',
                accountId: 'acc-1',
                mailboxPath: 'foo',
                uid: 1,
                receivedAt: DateTime(2024),
                threadId: const Value('t-current'),
              ),
            );
        await r.db.into(r.db.threads).insert(
              ThreadsCompanion.insert(
                id: 't-current',
                accountId: 'acc-1',
                mailboxPath: 'foo',
                latestDate: DateTime(2024),
                latestEmailId: 'acc-1:e',
                emailIdsJson: Value(jsonEncode(['acc-1:e'])),
              ),
            );
        // A stale/orphaned thread row that still lists the same email but whose
        // id no longer matches the email's current threadId. Such rows are left
        // behind when a thread-id derivation change (message-id / subject
        // normalisation, see #418, #500) re-threads a message on resync.
        await r.db.into(r.db.threads).insert(
              ThreadsCompanion.insert(
                id: 't-stale',
                accountId: 'acc-1',
                mailboxPath: 'foo',
                latestDate: DateTime(2024),
                latestEmailId: 'acc-1:e',
                emailIdsJson: Value(jsonEncode(['acc-1:e'])),
              ),
            );

        // The user selects all and moves every email the folder lists.
        final before = await r.emails.observeThreads('acc-1', 'foo').first;
        final allEmailIds = {for (final t in before) ...t.emailIds};
        for (final id in allEmailIds) {
          await r.emails.moveEmail(id, 'dest');
        }

        final after = await r.emails.observeThreads('acc-1', 'foo').first;
        expect(
          after,
          isEmpty,
          reason: 'foo should be empty after moving all of its mail',
        );
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

    test(
      'move flush remaps local id/uid from COPYUID and rewrites cached bodies',
      () async {
        final spy = SnoozeSpyImapClient(
          copyUidValidity: 1,
          copyUidSourceToTarget: const {5: 42},
        );
        final r = _makeRepos(imapConnect: (_, __, ___) async => spy);
        await r.accounts.addAccount(_account, 'pw');

        const oldId = 'acc-1:INBOX:5';
        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: oldId,
                accountId: 'acc-1',
                mailboxPath: 'Archive', // already optimistically moved
                uid: 5,
                receivedAt: DateTime(2024),
                messageId: const Value('<msg-1@example.com>'),
                threadId: const Value('thr-1'),
              ),
            );
        await r.db.into(r.db.emailBodies).insert(
              EmailBodiesCompanion.insert(
                emailId: oldId,
                textBody: const Value('cached body'),
              ),
            );
        await r.db.into(r.db.pendingChanges).insert(
              PendingChangesCompanion.insert(
                accountId: 'acc-1',
                resourceType: 'Email',
                resourceId: oldId,
                changeType: 'move',
                payload: jsonEncode({
                  'uid': 5,
                  'mailboxPath': 'INBOX',
                  'dest': 'Archive',
                }),
                createdAt: DateTime.now(),
              ),
            );

        await r.emails.flushPendingChanges('acc-1', 'pw');

        // Pending change drained.
        expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);

        // Old id is gone; new id reflects destination mailbox + new UID.
        expect(await r.emails.getEmail(oldId), isNull);
        const newId = 'acc-1:Archive:42';
        final moved = await r.emails.getEmail(newId);
        expect(moved, isNotNull);
        expect(moved!.uid, 42);
        expect(moved.mailboxPath, 'Archive');

        // Body cache follows the new id.
        final bodies = await r.db.select(r.db.emailBodies).get();
        expect(bodies, hasLength(1));
        expect(bodies.first.emailId, newId);
        expect(bodies.first.textBody, 'cached body');
      },
    );

    test(
      'move flush falls back to UID SEARCH HEADER Message-ID without UIDPLUS',
      () async {
        const messageId = '<msg-1@example.com>';
        const criteria = 'HEADER Message-ID "$messageId"';
        final spy = SnoozeSpyImapClient(
          // No copyUidValidity → no COPYUID in the MOVE response.
          searchResults: const {
            criteria: [99],
          },
        );
        final r = _makeRepos(imapConnect: (_, __, ___) async => spy);
        await r.accounts.addAccount(_account, 'pw');

        const oldId = 'acc-1:INBOX:5';
        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: oldId,
                accountId: 'acc-1',
                mailboxPath: 'Archive',
                uid: 5,
                receivedAt: DateTime(2024),
                messageId: const Value(messageId),
              ),
            );
        await r.db.into(r.db.pendingChanges).insert(
              PendingChangesCompanion.insert(
                accountId: 'acc-1',
                resourceType: 'Email',
                resourceId: oldId,
                changeType: 'move',
                payload: jsonEncode({
                  'uid': 5,
                  'mailboxPath': 'INBOX',
                  'dest': 'Archive',
                }),
                createdAt: DateTime.now(),
              ),
            );

        await r.emails.flushPendingChanges('acc-1', 'pw');

        expect(spy.lastSearchCriteria, criteria);
        const newId = 'acc-1:Archive:99';
        final moved = await r.emails.getEmail(newId);
        expect(moved, isNotNull);
        expect(moved!.uid, 99);
      },
    );

    test(
      'move flush rewrites pending undo_actions referencing the old id',
      () async {
        final spy = SnoozeSpyImapClient(
          copyUidValidity: 1,
          copyUidSourceToTarget: const {5: 42},
        );
        final r = _makeRepos(imapConnect: (_, __, ___) async => spy);
        await r.accounts.addAccount(_account, 'pw');

        const oldId = 'acc-1:INBOX:5';
        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: oldId,
                accountId: 'acc-1',
                mailboxPath: 'Archive',
                uid: 5,
                receivedAt: DateTime(2024),
              ),
            );
        await r.db.into(r.db.pendingChanges).insert(
              PendingChangesCompanion.insert(
                accountId: 'acc-1',
                resourceType: 'Email',
                resourceId: oldId,
                changeType: 'move',
                payload: jsonEncode({
                  'uid': 5,
                  'mailboxPath': 'INBOX',
                  'dest': 'Archive',
                }),
                createdAt: DateTime.now(),
              ),
            );
        // An undo entry created when the user did the move, referencing oldId
        // in both emailIds and originalEmails[].id.
        await r.db.into(r.db.undoActions).insert(
              UndoActionsCompanion.insert(
                id: 'undo-1',
                accountId: 'acc-1',
                dataJson: jsonEncode({
                  'id': 'undo-1',
                  'accountId': 'acc-1',
                  'type': 'move',
                  'emailIds': [oldId],
                  'sourceMailboxPath': 'INBOX',
                  'destinationMailboxPath': 'Archive',
                  'timestamp': DateTime(2024).toIso8601String(),
                  'originalEmails': [
                    {
                      'id': oldId,
                      'accountId': 'acc-1',
                      'mailboxPath': 'INBOX',
                      'uid': 5,
                      'receivedAt': DateTime(2024).toIso8601String(),
                      'from': [],
                      'to': [],
                      'cc': [],
                      'isSeen': false,
                      'isFlagged': false,
                      'hasAttachment': false,
                    },
                  ],
                }),
                createdAt: DateTime(2024),
              ),
            );

        await r.emails.flushPendingChanges('acc-1', 'pw');

        const newId = 'acc-1:Archive:42';
        final stored = await r.db.select(r.db.undoActions).getSingle();
        final json = jsonDecode(stored.dataJson) as Map<String, dynamic>;
        expect(json['emailIds'], [newId]);
        expect(
          (json['originalEmails'] as List).first as Map<String, dynamic>,
          containsPair('id', newId),
        );
      },
    );

    test(
      'reconciliation skips rows with a pending move so they are not wiped',
      () async {
        final r = _makeRepos();
        await r.accounts.addAccount(_account, 'pw');

        const oldId = 'acc-1:INBOX:5';
        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: oldId,
                accountId: 'acc-1',
                mailboxPath: 'Archive', // optimistically moved
                uid: 5,
                receivedAt: DateTime(2024),
              ),
            );
        await r.db.into(r.db.pendingChanges).insert(
              PendingChangesCompanion.insert(
                accountId: 'acc-1',
                resourceType: 'Email',
                resourceId: oldId,
                changeType: 'move',
                payload: jsonEncode({
                  'uid': 5,
                  'mailboxPath': 'INBOX',
                  'dest': 'Archive',
                }),
                createdAt: DateTime.now(),
              ),
            );

        // Run the deletion-reconciliation pass with a destination snapshot
        // that does NOT contain UID 5 — the row would be wiped without the
        // in-flight guard. serverMessageCount is non-zero so the empty-mailbox
        // guard doesn't short-circuit first; this genuinely exercises the
        // in-flight guard.
        await r.emails.reconcileDeletedImapForTest(
          'acc-1',
          'Archive',
          const [7],
          serverMessageCount: 1,
        );

        expect(await r.emails.getEmail(oldId), isNotNull);
      },
    );

    test(
      'reconciliation removes local rows when the server reports the mailbox '
      'is empty (EXISTS=0)',
      () async {
        final r = _makeRepos();
        await r.accounts.addAccount(_account, 'pw');

        // A cached INBOX message whose UID is no longer on the server — e.g.
        // it was deleted/moved to Trash by another account or client.
        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: 'acc-1:INBOX:5',
                accountId: 'acc-1',
                mailboxPath: 'INBOX',
                uid: 5,
                receivedAt: DateTime(2024),
              ),
            );

        // Server authoritatively reports the mailbox is empty: SEARCH ALL
        // returned no UIDs AND SELECT reported EXISTS=0.
        await r.emails.reconcileDeletedImapForTest(
          'acc-1',
          'INBOX',
          const [],
          serverMessageCount: 0,
        );

        expect(
          await r.emails.getEmail('acc-1:INBOX:5'),
          isNull,
          reason: 'a remotely-emptied folder must clear locally',
        );
      },
    );

    test(
      'reconciliation keeps local rows when search returns nothing but the '
      'server still claims messages exist (suspicious response)',
      () async {
        final r = _makeRepos();
        await r.accounts.addAccount(_account, 'pw');

        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: 'acc-1:INBOX:5',
                accountId: 'acc-1',
                mailboxPath: 'INBOX',
                uid: 5,
                receivedAt: DateTime(2024),
              ),
            );

        // SEARCH ALL came back empty, but SELECT said EXISTS=3 — an incomplete
        // or buggy response. The cache must be preserved.
        await r.emails.reconcileDeletedImapForTest(
          'acc-1',
          'INBOX',
          const [],
          serverMessageCount: 3,
        );

        expect(await r.emails.getEmail('acc-1:INBOX:5'), isNotNull);
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

    test('snoozeEmail mirrors the snooze onto the counterpart account',
        () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_imapPair, 'pw');
      await r.accounts.addAccount(_jmapPair, 'pw');

      // Same message, seen via both protocols. IMAP keeps the RFC 5322 angle
      // brackets around the Message-ID; JMAP stores it without — the mirror
      // must correlate the two regardless.
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'imap-p:5',
              accountId: 'imap-p',
              mailboxPath: 'INBOX',
              uid: 5,
              receivedAt: DateTime(2024),
              messageId: const Value('<abc@example.com>'),
            ),
          );
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'jmap-p:e1',
              accountId: 'jmap-p',
              mailboxPath: 'INBOX',
              uid: 0,
              receivedAt: DateTime(2024),
              messageId: const Value('abc@example.com'),
            ),
          );

      final until = DateTime(2026, 5, 10, 15);
      await r.emails.snoozeEmail('imap-p:5', until);

      // Source account snoozed.
      final src = await r.emails.getEmail('imap-p:5');
      expect(src!.snoozedUntil, until);

      // Counterpart account snoozed too.
      final mirror = await r.emails.getEmail('jmap-p:e1');
      expect(mirror!.snoozedUntil, until);
      expect(mirror.mailboxPath, 'Snoozed');
      expect(mirror.snoozedFromMailboxPath, 'INBOX');

      // Each account got exactly one pending change on its own queue.
      final srcChanges = await (r.db.select(r.db.pendingChanges)
            ..where((t) => t.accountId.equals('imap-p')))
          .get();
      expect(srcChanges, hasLength(1));
      expect(srcChanges.first.changeType, 'snooze');
      final mirrorChanges = await (r.db.select(r.db.pendingChanges)
            ..where((t) => t.accountId.equals('jmap-p')))
          .get();
      expect(mirrorChanges, hasLength(1));
      expect(mirrorChanges.first.changeType, 'snooze');
    });

    test('wakeUpEmails mirrors the un-snooze onto the counterpart account',
        () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_imapPair, 'pw');
      await r.accounts.addAccount(_jmapPair, 'pw');
      for (final id in const ['imap-p', 'jmap-p']) {
        await r.db.into(r.db.mailboxes).insert(
              MailboxesCompanion.insert(
                id: '$id:INBOX',
                accountId: id,
                path: 'INBOX',
                name: 'Inbox',
                role: const Value('inbox'),
              ),
            );
      }

      final past = DateTime.now().subtract(const Duration(hours: 1));
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'imap-p:5',
              accountId: 'imap-p',
              mailboxPath: 'Snoozed',
              uid: 5,
              receivedAt: DateTime(2024),
              messageId: const Value('<abc@example.com>'),
              snoozedUntil: Value(past),
              snoozedFromMailboxPath: const Value('INBOX'),
            ),
          );
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'jmap-p:e1',
              accountId: 'jmap-p',
              mailboxPath: 'Snoozed',
              uid: 0,
              receivedAt: DateTime(2024),
              messageId: const Value('abc@example.com'),
              snoozedUntil: Value(past),
              snoozedFromMailboxPath: const Value('INBOX'),
            ),
          );

      final count = await r.emails.wakeUpEmails('imap-p');
      expect(count, 1);

      final mirror = await r.emails.getEmail('jmap-p:e1');
      expect(mirror!.snoozedUntil, isNull);
      expect(mirror.mailboxPath, 'INBOX');

      final mirrorChanges = await (r.db.select(r.db.pendingChanges)
            ..where((t) => t.accountId.equals('jmap-p')))
          .get();
      expect(mirrorChanges, hasLength(1));
      expect(mirrorChanges.first.changeType, 'unsnooze');
    });

    test('snooze mirror skips a counterpart already snoozed to the same time',
        () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_imapPair, 'pw');
      await r.accounts.addAccount(_jmapPair, 'pw');

      final until = DateTime(2026, 5, 10, 15);
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'imap-p:5',
              accountId: 'imap-p',
              mailboxPath: 'INBOX',
              uid: 5,
              receivedAt: DateTime(2024),
              messageId: const Value('<abc@example.com>'),
            ),
          );
      // Counterpart is already snoozed to the same instant (e.g. picked up from
      // the shared server-side keyword on a previous sync).
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'jmap-p:e1',
              accountId: 'jmap-p',
              mailboxPath: 'Snoozed',
              uid: 0,
              receivedAt: DateTime(2024),
              messageId: const Value('abc@example.com'),
              snoozedUntil: Value(until),
              snoozedFromMailboxPath: const Value('INBOX'),
            ),
          );

      await r.emails.snoozeEmail('imap-p:5', until);

      // No redundant change enqueued on the already-snoozed counterpart.
      final mirrorChanges = await (r.db.select(r.db.pendingChanges)
            ..where((t) => t.accountId.equals('jmap-p')))
          .get();
      expect(mirrorChanges, isEmpty);
    });

    test('snoozeEmail is a no-op mirror when there is no counterpart account',
        () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_imapPair, 'pw');
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'imap-p:5',
              accountId: 'imap-p',
              mailboxPath: 'INBOX',
              uid: 5,
              receivedAt: DateTime(2024),
              messageId: const Value('<abc@example.com>'),
            ),
          );

      await r.emails.snoozeEmail('imap-p:5', DateTime(2026, 5, 10, 15));

      final changes = await r.db.select(r.db.pendingChanges).get();
      expect(changes, hasLength(1));
      expect(changes.first.accountId, 'imap-p');
    });
  });

  group('Archive/Delete/Spam mirroring', () {
    // Seeds a mailbox row. IMAP and JMAP copies of the same server mailbox live
    // under different [path]s, so the mirror must resolve the counterpart by
    // [role], never by copying the source path.
    Future<void> seedMailbox(
      AppDatabase db,
      String accountId,
      String path,
      String name, {
      String? role,
    }) =>
        db.into(db.mailboxes).insert(
              MailboxesCompanion.insert(
                id: '$accountId:$path',
                accountId: accountId,
                path: path,
                name: name,
                role: Value(role),
              ),
            );

    Future<void> seedEmail(
      AppDatabase db,
      String id,
      String accountId,
      String mailboxPath,
      String messageId,
    ) =>
        db.into(db.emails).insert(
              EmailsCompanion.insert(
                id: id,
                accountId: accountId,
                mailboxPath: mailboxPath,
                uid: 0,
                receivedAt: DateTime(2024),
                messageId: Value(messageId),
              ),
            );

    test('archive move on IMAP mirrors to the JMAP counterpart by role',
        () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_imapPair, 'pw');
      await r.accounts.addAccount(_jmapPair, 'pw');
      await seedMailbox(r.db, 'imap-p', 'INBOX', 'Inbox', role: 'inbox');
      await seedMailbox(r.db, 'imap-p', 'Archive', 'Archive', role: 'archive');
      await seedMailbox(r.db, 'jmap-p', 'INBOX', 'Inbox', role: 'inbox');
      // Deliberately a *different* path from the IMAP archive folder.
      await seedMailbox(r.db, 'jmap-p', 'mbox-9', 'Archive', role: 'archive');
      await seedEmail(r.db, 'imap-p:5', 'imap-p', 'INBOX', '<abc@example.com>');
      await seedEmail(r.db, 'jmap-p:e1', 'jmap-p', 'INBOX', 'abc@example.com');

      await r.emails.moveEmail('imap-p:5', 'Archive');

      // Source moved to its own archive path.
      final src = await r.emails.getEmail('imap-p:5');
      expect(src!.mailboxPath, 'Archive');
      // Counterpart moved to *its* archive path (resolved by role, not copied).
      final mirror = await r.emails.getEmail('jmap-p:e1');
      expect(mirror!.mailboxPath, 'mbox-9');

      for (final id in const ['imap-p', 'jmap-p']) {
        final changes = await (r.db.select(r.db.pendingChanges)
              ..where((t) => t.accountId.equals(id)))
            .get();
        expect(changes, hasLength(1), reason: id);
        expect(changes.first.changeType, 'move');
      }
    });

    test('archive move on JMAP mirrors to the IMAP counterpart by role',
        () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_imapPair, 'pw');
      await r.accounts.addAccount(_jmapPair, 'pw');
      await seedMailbox(r.db, 'imap-p', 'INBOX', 'Inbox', role: 'inbox');
      await seedMailbox(r.db, 'imap-p', 'Archive', 'Archive', role: 'archive');
      await seedMailbox(r.db, 'jmap-p', 'INBOX', 'Inbox', role: 'inbox');
      await seedMailbox(r.db, 'jmap-p', 'mbox-9', 'Archive', role: 'archive');
      await seedEmail(r.db, 'imap-p:5', 'imap-p', 'INBOX', '<abc@example.com>');
      await seedEmail(r.db, 'jmap-p:e1', 'jmap-p', 'INBOX', 'abc@example.com');

      await r.emails.moveEmail('jmap-p:e1', 'mbox-9');

      final mirror = await r.emails.getEmail('imap-p:5');
      expect(mirror!.mailboxPath, 'Archive');
    });

    test('spam move mirrors to the counterpart junk mailbox', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_imapPair, 'pw');
      await r.accounts.addAccount(_jmapPair, 'pw');
      await seedMailbox(r.db, 'imap-p', 'INBOX', 'Inbox', role: 'inbox');
      await seedMailbox(r.db, 'imap-p', 'Junk', 'Junk', role: 'junk');
      await seedMailbox(r.db, 'jmap-p', 'INBOX', 'Inbox', role: 'inbox');
      await seedMailbox(r.db, 'jmap-p', 'mbox-junk', 'Spam', role: 'junk');
      await seedEmail(r.db, 'imap-p:5', 'imap-p', 'INBOX', '<abc@example.com>');
      await seedEmail(r.db, 'jmap-p:e1', 'jmap-p', 'INBOX', 'abc@example.com');

      await r.emails.moveEmail('imap-p:5', 'Junk');

      final mirror = await r.emails.getEmail('jmap-p:e1');
      expect(mirror!.mailboxPath, 'mbox-junk');
    });

    test('delete-to-Trash mirrors onto the counterpart Trash', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_imapPair, 'pw');
      await r.accounts.addAccount(_jmapPair, 'pw');
      await seedMailbox(r.db, 'imap-p', 'INBOX', 'Inbox', role: 'inbox');
      await seedMailbox(r.db, 'imap-p', 'Trash', 'Trash', role: 'trash');
      await seedMailbox(r.db, 'jmap-p', 'INBOX', 'Inbox', role: 'inbox');
      await seedMailbox(r.db, 'jmap-p', 'mbox-t', 'Trash', role: 'trash');
      await seedEmail(r.db, 'imap-p:5', 'imap-p', 'INBOX', '<abc@example.com>');
      await seedEmail(r.db, 'jmap-p:e1', 'jmap-p', 'INBOX', 'abc@example.com');

      final dest = await r.emails.deleteEmail('imap-p:5');
      expect(dest, 'Trash');

      final src = await r.emails.getEmail('imap-p:5');
      expect(src!.mailboxPath, 'Trash');
      final mirror = await r.emails.getEmail('jmap-p:e1');
      expect(mirror!.mailboxPath, 'mbox-t');

      for (final id in const ['imap-p', 'jmap-p']) {
        final changes = await (r.db.select(r.db.pendingChanges)
              ..where((t) => t.accountId.equals(id)))
            .get();
        expect(changes, hasLength(1), reason: id);
        expect(changes.first.changeType, 'move');
      }
    });

    test('hard delete (already in Trash) mirrors a hard delete', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_imapPair, 'pw');
      await r.accounts.addAccount(_jmapPair, 'pw');
      await seedMailbox(r.db, 'imap-p', 'Trash', 'Trash', role: 'trash');
      await seedMailbox(r.db, 'jmap-p', 'mbox-t', 'Trash', role: 'trash');
      await seedEmail(r.db, 'imap-p:5', 'imap-p', 'Trash', '<abc@example.com>');
      await seedEmail(r.db, 'jmap-p:e1', 'jmap-p', 'mbox-t', 'abc@example.com');

      final dest = await r.emails.deleteEmail('imap-p:5');
      expect(dest, isNull);

      // Both copies are permanently removed.
      expect(await r.emails.getEmail('imap-p:5'), isNull);
      expect(await r.emails.getEmail('jmap-p:e1'), isNull);

      for (final id in const ['imap-p', 'jmap-p']) {
        final changes = await (r.db.select(r.db.pendingChanges)
              ..where((t) => t.accountId.equals(id)))
            .get();
        expect(changes, hasLength(1), reason: id);
        expect(changes.first.changeType, 'delete');
      }
    });

    test(
        'move mirror is a no-op when the counterpart has not synced the message',
        () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_imapPair, 'pw');
      await r.accounts.addAccount(_jmapPair, 'pw');
      await seedMailbox(r.db, 'imap-p', 'INBOX', 'Inbox', role: 'inbox');
      await seedMailbox(r.db, 'imap-p', 'Archive', 'Archive', role: 'archive');
      await seedMailbox(r.db, 'jmap-p', 'mbox-9', 'Archive', role: 'archive');
      // No jmap-p email row: the counterpart hasn't cached this message yet.
      await seedEmail(r.db, 'imap-p:5', 'imap-p', 'INBOX', '<abc@example.com>');

      await r.emails.moveEmail('imap-p:5', 'Archive');

      final changes = await (r.db.select(r.db.pendingChanges)
            ..where((t) => t.accountId.equals('jmap-p')))
          .get();
      expect(changes, isEmpty);
    });

    test('move mirror skips a counterpart already in the destination',
        () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_imapPair, 'pw');
      await r.accounts.addAccount(_jmapPair, 'pw');
      await seedMailbox(r.db, 'imap-p', 'INBOX', 'Inbox', role: 'inbox');
      await seedMailbox(r.db, 'imap-p', 'Archive', 'Archive', role: 'archive');
      await seedMailbox(r.db, 'jmap-p', 'mbox-9', 'Archive', role: 'archive');
      await seedEmail(r.db, 'imap-p:5', 'imap-p', 'INBOX', '<abc@example.com>');
      // Counterpart is already archived (e.g. from a previous sync).
      await seedEmail(r.db, 'jmap-p:e1', 'jmap-p', 'mbox-9', 'abc@example.com');

      await r.emails.moveEmail('imap-p:5', 'Archive');

      final changes = await (r.db.select(r.db.pendingChanges)
            ..where((t) => t.accountId.equals('jmap-p')))
          .get();
      expect(changes, isEmpty);
    });

    test('move is a no-op mirror when there is no counterpart account',
        () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_imapPair, 'pw');
      await seedMailbox(r.db, 'imap-p', 'INBOX', 'Inbox', role: 'inbox');
      await seedMailbox(r.db, 'imap-p', 'Archive', 'Archive', role: 'archive');
      await seedEmail(r.db, 'imap-p:5', 'imap-p', 'INBOX', '<abc@example.com>');

      await r.emails.moveEmail('imap-p:5', 'Archive');

      final changes = await r.db.select(r.db.pendingChanges).get();
      expect(changes, hasLength(1));
      expect(changes.first.accountId, 'imap-p');
    });
  });

  // Issue #478: one server added twice — once via IMAP, once via JMAP — so
  // every message has two independent local copies. observeAllInboxThreads
  // collapses each counterpart pair to a single row (see the de-duplication
  // group above). Acting on the visible copy must take the twin out of the
  // inbox too; otherwise the "next" mail after the action is the very same
  // message reached through the other protocol.
  group('combined inbox: acting on one copy never re-surfaces its twin (#478)',
      () {
    // Seeds an INBOX copy of a message (mailbox + email + thread) for
    // [accountId]. Both protocol copies of the same server message share a
    // Message-ID (bracketed for IMAP, bare for JMAP) so the pair collapses.
    Future<void> seedInboxCopy(
      ({
        AppDatabase db,
        AccountRepositoryImpl accounts,
        EmailRepositoryImpl emails
      }) r, {
      required String accountId,
      required String emailId,
      required String threadId,
      required String subject,
      required String messageId,
      required DateTime date,
    }) async {
      final existingInbox = await (r.db.select(r.db.mailboxes)
            ..where(
              (t) => t.accountId.equals(accountId) & t.role.equals('inbox'),
            ))
          .getSingleOrNull();
      if (existingInbox == null) {
        await r.db.into(r.db.mailboxes).insert(
              MailboxesCompanion.insert(
                id: '$accountId:INBOX',
                accountId: accountId,
                path: 'INBOX',
                name: 'Inbox',
                role: const Value('inbox'),
              ),
            );
      }
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: emailId,
              accountId: accountId,
              mailboxPath: 'INBOX',
              uid: 0,
              receivedAt: date,
              subject: Value(subject),
              messageId: Value(messageId),
              threadId: Value(threadId),
            ),
          );
      await r.db.into(r.db.threads).insert(
            ThreadsCompanion.insert(
              id: threadId,
              accountId: accountId,
              mailboxPath: 'INBOX',
              subject: Value(subject),
              latestDate: date,
              latestEmailId: emailId,
            ),
          );
    }

    // Two messages, each present in both accounts. 'First' is newest so it
    // sits at the top of the combined inbox.
    Future<void> seedTwoDuplicatedMails(
      ({
        AppDatabase db,
        AccountRepositoryImpl accounts,
        EmailRepositoryImpl emails
      }) r,
    ) async {
      await seedInboxCopy(
        r,
        accountId: 'imap-p',
        emailId: 'imap-p:first',
        threadId: 'imap-first',
        subject: 'First',
        messageId: '<first@example.com>',
        date: DateTime(2024, 6, 2),
      );
      await seedInboxCopy(
        r,
        accountId: 'jmap-p',
        emailId: 'jmap-p:first',
        threadId: 'jmap-first',
        subject: 'First',
        messageId: 'first@example.com',
        date: DateTime(2024, 6, 2),
      );
      await seedInboxCopy(
        r,
        accountId: 'imap-p',
        emailId: 'imap-p:second',
        threadId: 'imap-second',
        subject: 'Second',
        messageId: '<second@example.com>',
        date: DateTime(2024, 6),
      );
      await seedInboxCopy(
        r,
        accountId: 'jmap-p',
        emailId: 'jmap-p:second',
        threadId: 'jmap-second',
        subject: 'Second',
        messageId: 'second@example.com',
        date: DateTime(2024, 6),
      );
    }

    test('archiving the first mail does not resurface its JMAP twin', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_imapPair, 'pw');
      await r.accounts.addAccount(_jmapPair, 'pw');
      // Only the IMAP account has an Archive folder: Stalwart has no Archive
      // mailbox until one is created, and the JMAP counterpart discovers it
      // only on a later mailbox sync — so at archive time the mirror cannot
      // resolve an equivalent destination on the counterpart.
      await r.db.into(r.db.mailboxes).insert(
            MailboxesCompanion.insert(
              id: 'imap-p:Archive',
              accountId: 'imap-p',
              path: 'Archive',
              name: 'Archive',
              role: const Value('archive'),
            ),
          );
      await seedTwoDuplicatedMails(r);

      // Combined inbox shows each mail once, newest first.
      var threads = await r.emails.observeAllInboxThreads().first;
      expect(threads.map((t) => t.subject), ['First', 'Second']);

      // Archive the first (visible, IMAP) copy.
      await r.emails.moveEmail('imap-p:first', 'Archive');

      // The next mail must be the genuinely different 'Second', not the JMAP
      // copy of 'First'.
      threads = await r.emails.observeAllInboxThreads().first;
      expect(
        threads.map((t) => t.subject),
        ['Second'],
        reason: 'the archived mail must not reappear via the JMAP account',
      );
    });

    test('deleting the first mail does not resurface its JMAP twin', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_imapPair, 'pw');
      await r.accounts.addAccount(_jmapPair, 'pw');
      // Only the IMAP account has a Trash folder; the JMAP counterpart must
      // still leave the inbox (falling back to a hard delete).
      await r.db.into(r.db.mailboxes).insert(
            MailboxesCompanion.insert(
              id: 'imap-p:Trash',
              accountId: 'imap-p',
              path: 'Trash',
              name: 'Trash',
              role: const Value('trash'),
            ),
          );
      await seedTwoDuplicatedMails(r);

      await r.emails.deleteEmail('imap-p:first');

      final threads = await r.emails.observeAllInboxThreads().first;
      expect(
        threads.map((t) => t.subject),
        ['Second'],
        reason: 'the deleted mail must not reappear via the JMAP account',
      );
    });

    test('snoozing the first mail does not resurface its JMAP twin', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_imapPair, 'pw');
      await r.accounts.addAccount(_jmapPair, 'pw');
      await seedTwoDuplicatedMails(r);

      await r.emails.snoozeEmail('imap-p:first', DateTime(2026, 5, 10, 15));

      final threads = await r.emails.observeAllInboxThreads().first;
      expect(
        threads.map((t) => t.subject),
        ['Second'],
        reason: 'the snoozed mail must not reappear via the JMAP account',
      );
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

      final emailState = await (r.db.select(r.db.syncStates)
            ..where((t) => t.resourceType.equals('JMAP:Email:mbx1')))
          .getSingle();
      expect(emailState.state, 'est1');
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
      // Skip the periodic reconciliation network call — covered separately.
      await r.db.into(r.db.syncStates).insertOnConflictUpdate(
            SyncStatesCompanion.insert(
              accountId: 'jmap-1',
              resourceType: 'JMAP:Reconcile:mbx1',
              state: DateTime.now().toIso8601String(),
              syncedAt: DateTime.now(),
            ),
          );

      await r.emails.syncEmails('jmap-1', 'mbx1');

      final emails = await r.emails.observeEmails('jmap-1', 'mbx1').first;
      expect(emails.map((e) => e.subject).toSet(), {'First updated', 'Third'});

      final emailState = await (r.db.select(r.db.syncStates)
            ..where((t) => t.resourceType.equals('Email')))
          .getSingle();
      expect(emailState.state, 'est2');
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
      // Skip the periodic reconciliation network call — covered separately.
      await r.db.into(r.db.syncStates).insertOnConflictUpdate(
            SyncStatesCompanion.insert(
              accountId: 'jmap-1',
              resourceType: 'JMAP:Reconcile:mbx1',
              state: DateTime.now().toIso8601String(),
              syncedAt: DateTime.now(),
            ),
          );

      await r.emails.syncEmails('jmap-1', 'mbx1');

      final emailState = await (r.db.select(r.db.syncStates)
            ..where((t) => t.resourceType.equals('Email')))
          .getSingle();
      expect(emailState.state, 'est1');
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

      final emailState = await (r.db.select(r.db.syncStates)
            ..where((t) => t.resourceType.equals('JMAP:Email:mbx1')))
          .getSingle();
      expect(emailState.state, 'est1');
    });

    // #262: Thunderbird "move to Trash" via IMAP surfaces on JMAP as an
    // Email/changes 'updated' entry whose mailboxIds no longer contains the
    // original mailbox. The mail must disappear from that mailbox's view.
    test(
      'incremental sync drops mail from source mailbox when '
      'mailboxIds shifts (regression for #262)',
      () async {
        final r = _makeRepos(
          httpClient: _mockJmapEmails(
            apiResponses: [
              _emailChangesResponse(
                oldState: 'est1',
                newState: 'est2',
                updated: ['e1'],
              ),
              _emailGetOnly(
                state: 'est2',
                list: [
                  // e1 is no longer in inbox mbx1 — moved to Trash mbx-trash.
                  _jmapEmail(id: 'e1', mailboxId: 'mbx-trash', subject: 'x'),
                ],
              ),
            ],
          ),
        );
        await r.accounts.addAccount(_jmapAccount, 'pw');
        await r.db.into(r.db.emails).insertOnConflictUpdate(
              EmailsCompanion.insert(
                id: 'jmap-1:e1',
                accountId: 'jmap-1',
                mailboxPath: 'mbx1',
                uid: 0,
                subject: const Value('x'),
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
        await r.db.into(r.db.syncStates).insertOnConflictUpdate(
              SyncStatesCompanion.insert(
                accountId: 'jmap-1',
                resourceType: 'JMAP:Reconcile:mbx1',
                state: DateTime.now().toIso8601String(),
                syncedAt: DateTime.now(),
              ),
            );

        await r.emails.syncEmails('jmap-1', 'mbx1');

        expect(
          await r.emails.observeEmails('jmap-1', 'mbx1').first,
          isEmpty,
          reason: 'email should leave mbx1 once mailboxIds no longer '
              'contains it',
        );
        final row = await (r.db.select(r.db.emails)
              ..where((t) => t.id.equals('jmap-1:e1')))
            .getSingle();
        expect(row.mailboxPath, 'mbx-trash');
      },
    );

    test(
      'incremental sync deletes local row when mailboxIds becomes empty',
      () async {
        final r = _makeRepos(
          httpClient: _mockJmapEmails(
            apiResponses: [
              _emailChangesResponse(
                oldState: 'est1',
                newState: 'est2',
                updated: ['e1'],
              ),
              _emailGetOnly(
                state: 'est2',
                list: [
                  // mailboxIds is empty — treat as gone.
                  {
                    'id': 'e1',
                    'mailboxIds': <String, dynamic>{},
                    'from': [],
                    'to': [],
                    'cc': [],
                    'receivedAt': '2024-01-01T00:00:00Z',
                  },
                ],
              ),
            ],
          ),
        );
        await r.accounts.addAccount(_jmapAccount, 'pw');
        await r.db.into(r.db.emails).insertOnConflictUpdate(
              EmailsCompanion.insert(
                id: 'jmap-1:e1',
                accountId: 'jmap-1',
                mailboxPath: 'mbx1',
                uid: 0,
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
        await r.db.into(r.db.syncStates).insertOnConflictUpdate(
              SyncStatesCompanion.insert(
                accountId: 'jmap-1',
                resourceType: 'JMAP:Reconcile:mbx1',
                state: DateTime.now().toIso8601String(),
                syncedAt: DateTime.now(),
              ),
            );

        await r.emails.syncEmails('jmap-1', 'mbx1');

        expect(
          await (r.db.select(r.db.emails)
                ..where((t) => t.id.equals('jmap-1:e1')))
              .getSingleOrNull(),
          isNull,
        );
      },
    );

    test(
      'full sync prunes local rows no longer present in Email/query',
      () async {
        final r = _makeRepos(
          httpClient: _mockJmapEmails(
            apiResponses: [
              _emailGetResponse(
                state: 'est1',
                list: [
                  _jmapEmail(id: 'e1', mailboxId: 'mbx1', subject: 'kept'),
                ],
              ),
            ],
          ),
        );
        await r.accounts.addAccount(_jmapAccount, 'pw');
        // Pre-populate a stale row that the server no longer has.
        await r.db.into(r.db.emails).insertOnConflictUpdate(
              EmailsCompanion.insert(
                id: 'jmap-1:e-stale',
                accountId: 'jmap-1',
                mailboxPath: 'mbx1',
                uid: 0,
                subject: const Value('stale'),
                receivedAt: DateTime(2024),
              ),
            );

        await r.emails.syncEmails('jmap-1', 'mbx1');

        final subjects = (await r.emails.observeEmails('jmap-1', 'mbx1').first)
            .map((e) => e.subject)
            .toSet();
        expect(subjects, {'kept'});
      },
    );

    test(
      'incremental sync falls back to full sync on cannotCalculateChanges',
      () async {
        final r = _makeRepos(
          httpClient: _mockJmapEmails(
            apiResponses: [
              // Call 1: Email/changes with error
              {
                'sessionState': 'sess1',
                'methodResponses': [
                  [
                    'error',
                    {'type': 'cannotCalculateChanges'},
                    '0',
                  ],
                ],
              },
              // Call 2: full sync Email/query + Email/get
              _emailGetResponse(
                state: 'est-new',
                list: [
                  _jmapEmail(id: 'e-live', mailboxId: 'mbx1', subject: 'live'),
                ],
              ),
            ],
          ),
        );
        await r.accounts.addAccount(_jmapAccount, 'pw');
        // Stale row that the server no longer has — full sync should prune it.
        await r.db.into(r.db.emails).insertOnConflictUpdate(
              EmailsCompanion.insert(
                id: 'jmap-1:e-ghost',
                accountId: 'jmap-1',
                mailboxPath: 'mbx1',
                uid: 0,
                subject: const Value('ghost'),
                receivedAt: DateTime(2024),
              ),
            );
        await r.db.into(r.db.syncStates).insertOnConflictUpdate(
              SyncStatesCompanion.insert(
                accountId: 'jmap-1',
                resourceType: 'Email',
                state: 'est-ancient',
                syncedAt: DateTime.now(),
              ),
            );

        await r.emails.syncEmails('jmap-1', 'mbx1');

        final subjects = (await r.emails.observeEmails('jmap-1', 'mbx1').first)
            .map((e) => e.subject)
            .toSet();
        expect(
          subjects,
          {'live'},
          reason: 'full-sync reconciliation should drop the ghost row',
        );

        final emailState = await (r.db.select(r.db.syncStates)
              ..where((t) => t.resourceType.equals('JMAP:Email:mbx1')))
            .getSingle();
        expect(emailState.state, 'est-new');
      },
    );

    test(
      'incremental sync drops row that Email/get omits (server treats as gone)',
      () async {
        final r = _makeRepos(
          httpClient: _mockJmapEmails(
            apiResponses: [
              _emailChangesResponse(
                oldState: 'est1',
                newState: 'est2',
                updated: ['e-gone', 'e-live'],
              ),
              _emailGetOnly(
                state: 'est2',
                // e-gone omitted — server no longer has it.
                list: [
                  _jmapEmail(
                    id: 'e-live',
                    mailboxId: 'mbx1',
                    subject: 'live',
                  ),
                ],
              ),
            ],
          ),
        );
        await r.accounts.addAccount(_jmapAccount, 'pw');
        await r.db.into(r.db.emails).insertOnConflictUpdate(
              EmailsCompanion.insert(
                id: 'jmap-1:e-gone',
                accountId: 'jmap-1',
                mailboxPath: 'mbx1',
                uid: 0,
                receivedAt: DateTime(2024),
              ),
            );
        await r.db.into(r.db.emails).insertOnConflictUpdate(
              EmailsCompanion.insert(
                id: 'jmap-1:e-live',
                accountId: 'jmap-1',
                mailboxPath: 'mbx1',
                uid: 0,
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
        await r.db.into(r.db.syncStates).insertOnConflictUpdate(
              SyncStatesCompanion.insert(
                accountId: 'jmap-1',
                resourceType: 'JMAP:Reconcile:mbx1',
                state: DateTime.now().toIso8601String(),
                syncedAt: DateTime.now(),
              ),
            );

        await r.emails.syncEmails('jmap-1', 'mbx1');

        expect(
          await (r.db.select(r.db.emails)
                ..where((t) => t.id.equals('jmap-1:e-gone')))
              .getSingleOrNull(),
          isNull,
        );
        expect(
          await (r.db.select(r.db.emails)
                ..where((t) => t.id.equals('jmap-1:e-live')))
              .getSingleOrNull(),
          isNotNull,
        );
      },
    );

    test(
      'periodic reconcile prunes rows missing from Email/query',
      () async {
        final r = _makeRepos(
          httpClient: _mockJmapEmails(
            apiResponses: [
              // Call 1: Email/changes reports nothing.
              _emailChangesResponse(oldState: 'est1', newState: 'est1'),
              // Call 2: reconcile pass Email/query — only e-live remains.
              {
                'sessionState': 'sess1',
                'methodResponses': [
                  [
                    'Email/query',
                    {
                      'accountId': 'acct1',
                      'ids': ['e-live'],
                      'total': 1,
                    },
                    '0',
                  ],
                ],
              },
              // Call 3: reconcile pass Email/get for keywords on the surviving
              // local row (e-live). Server-side keywords are empty, matching
              // the seeded row's default isSeen=false / isFlagged=false.
              {
                'sessionState': 'sess1',
                'methodResponses': [
                  [
                    'Email/get',
                    {
                      'accountId': 'acct1',
                      'state': 'est1',
                      'list': [
                        {'id': 'e-live', 'keywords': <String, dynamic>{}},
                      ],
                    },
                    '0',
                  ],
                ],
              },
            ],
          ),
        );
        await r.accounts.addAccount(_jmapAccount, 'pw');
        await r.db.into(r.db.emails).insertOnConflictUpdate(
              EmailsCompanion.insert(
                id: 'jmap-1:e-live',
                accountId: 'jmap-1',
                mailboxPath: 'mbx1',
                uid: 0,
                receivedAt: DateTime(2024),
              ),
            );
        // Server-side gone but no destroyed/updated hit us (the exact bug in
        // #262). Reconcile should still find and prune it.
        await r.db.into(r.db.emails).insertOnConflictUpdate(
              EmailsCompanion.insert(
                id: 'jmap-1:e-ghost',
                accountId: 'jmap-1',
                mailboxPath: 'mbx1',
                uid: 0,
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
        // No JMAP:Reconcile:mbx1 row → reconcile pass runs.

        await r.emails.syncEmails('jmap-1', 'mbx1');

        expect(
          await (r.db.select(r.db.emails)
                ..where((t) => t.id.equals('jmap-1:e-ghost')))
              .getSingleOrNull(),
          isNull,
        );
        expect(
          await (r.db.select(r.db.emails)
                ..where((t) => t.id.equals('jmap-1:e-live')))
              .getSingleOrNull(),
          isNotNull,
        );
        final recon = await (r.db.select(r.db.syncStates)
              ..where((t) => t.resourceType.equals('JMAP:Reconcile:mbx1')))
            .getSingle();
        expect(recon.state, isNotEmpty);
      },
    );

    test(
      'periodic reconcile is throttled to at most once per interval',
      () async {
        // Only 1 mocked response — a second network call for reconcile would
        // wrap around and mismatch. The throttle must prevent that.
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
        final freshTimestamp = DateTime.now()
            .subtract(const Duration(minutes: 5))
            .toIso8601String();
        await r.db.into(r.db.syncStates).insertOnConflictUpdate(
              SyncStatesCompanion.insert(
                accountId: 'jmap-1',
                resourceType: 'JMAP:Reconcile:mbx1',
                state: freshTimestamp,
                syncedAt: DateTime.now(),
              ),
            );

        await r.emails.syncEmails('jmap-1', 'mbx1');

        final recon = await (r.db.select(r.db.syncStates)
              ..where((t) => t.resourceType.equals('JMAP:Reconcile:mbx1')))
            .getSingle();
        expect(
          recon.state,
          freshTimestamp,
          reason: 'reconcile ran again when it should have been throttled',
        );
      },
    );
  });

  group('JMAP verifySyncReliability batches Email/get', () {
    test(
      'chunks flag verification so a large mailbox never sends one huge '
      'Email/get (see #513)',
      () async {
        // 600 server ids > _jmapPageSize (500) forces at least two batches.
        const total = 600;
        final serverIds = [for (var i = 0; i < total; i++) 'e$i'];
        // One local row disagrees with the server, and it lives in the second
        // batch (index >= 500) so we prove mismatches aggregate across pages.
        const mismatchIndex = 550;

        final getBatchSizes = <int>[];
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
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final call = (body['methodCalls'] as List).first as List;
          final method = call[0] as String;
          final args = call[1] as Map<String, dynamic>;
          if (method == 'Email/query') {
            final position = (args['position'] as int?) ?? 0;
            final limit = args['limit'] as int;
            final page = serverIds.skip(position).take(limit).toList();
            return http.Response(
              jsonEncode({
                'sessionState': 'sess1',
                'methodResponses': [
                  [
                    'Email/query',
                    {'accountId': 'acct1', 'ids': page, 'total': total},
                    '0',
                  ],
                ],
              }),
              200,
            );
          }
          // Email/get for keywords — record the batch size and echo each id
          // back with its (unseen, unflagged) server keywords.
          final ids = List<String>.from(args['ids'] as List);
          getBatchSizes.add(ids.length);
          return http.Response(
            jsonEncode({
              'sessionState': 'sess1',
              'methodResponses': [
                [
                  'Email/get',
                  {
                    'accountId': 'acct1',
                    'list': [
                      for (final id in ids)
                        {'id': id, 'keywords': <String, dynamic>{}},
                    ],
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
        for (var i = 0; i < total; i++) {
          await r.db.into(r.db.emails).insert(
                EmailsCompanion.insert(
                  id: 'jmap-1:e$i',
                  accountId: 'jmap-1',
                  mailboxPath: 'mbx1',
                  uid: i,
                  receivedAt: DateTime(2024),
                  // Server reports every mail as unseen; only this row claims
                  // to be seen locally, so exactly one mismatch is expected.
                  isSeen: Value(i == mismatchIndex),
                ),
              );
        }

        final result = await r.emails.verifySyncReliability('jmap-1', 'mbx1');

        // Every Email/get stayed within the page size — no single oversized
        // request that a server could reject with requestTooLarge.
        expect(getBatchSizes.length, greaterThan(1));
        expect(getBatchSizes.every((n) => n <= 500), isTrue);
        expect(getBatchSizes.reduce((a, b) => a + b), total);

        // The mismatch in the second batch was still detected.
        expect(result.flagMismatches, hasLength(1));
        expect(result.flagMismatches.single.id, 'jmap-1:e$mismatchIndex');
        expect(result.flagMismatches.single.localSeen, isTrue);
        expect(result.flagMismatches.single.serverSeen, isFalse);
      },
    );
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

    test(
      'destroys the created Sent copy when EmailSubmission/set fails',
      () async {
        // When the server refuses the submission, the email created in the
        // Sent mailbox beforehand must be destroyed so a message that was
        // never actually sent does not linger in the Sent folder.
        final emailSetBodies = <Map<String, dynamic>>[];
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
            emailSetBodies.add(jsonDecode(req.body) as Map<String, dynamic>);
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
                        'em1': {'id': 'newEmailId1'},
                      },
                    },
                    '0',
                  ],
                ],
              }),
              200,
            );
          }
          // EmailSubmission/set fails.
          return http.Response(
            jsonEncode({
              'sessionState': 's1',
              'methodResponses': [
                [
                  'EmailSubmission/set',
                  {
                    'accountId': 'acct1',
                    'notCreated': {
                      'sub1': {'type': 'forbiddenFrom'},
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

        await expectLater(
          r.emails.sendEmail('jmap-1', draft),
          throwsA(isA<JmapException>()),
        );

        // The first Email/set creates the Sent copy; a later Email/set must
        // destroy exactly the email that was created.
        Map<String, dynamic> emailSetArgs(Map<String, dynamic> body) {
          final calls = body['methodCalls'] as List<dynamic>;
          return (calls.first as List<dynamic>)[1] as Map<String, dynamic>;
        }

        final destroyCall = emailSetBodies.firstWhere(
          (body) => emailSetArgs(body).containsKey('destroy'),
          orElse: () => throw StateError(
            'expected an Email/set destroy call after a failed submission',
          ),
        );
        expect(emailSetArgs(destroyCall)['destroy'], contains('newEmailId1'));
      },
    );

    test(
      'forbiddenFrom error includes envelope and identity addresses',
      () async {
        final r = _makeRepos(
          httpClient: mockSend(
            submissionResult: {
              'accountId': 'acct1',
              'notCreated': {
                'sub1': {
                  'type': 'forbiddenFrom',
                  'description':
                      'Envelope mailFrom does not match identity email '
                          'address.',
                },
              },
            },
          ),
        );
        await r.accounts.addAccount(_jmapAccount, 'pw');

        const mismatchedDraft = EmailDraft(
          from: EmailAddress(name: 'Alice', email: 'other@example.com'),
          to: [EmailAddress(name: 'Bob', email: 'bob@example.com')],
          cc: [],
          subject: 'Hello',
          body: 'World',
        );

        await expectLater(
          r.emails.sendEmail('jmap-1', mismatchedDraft),
          throwsA(
            isA<JmapException>().having(
              (e) => e.toString(),
              'message',
              allOf(
                contains('forbiddenFrom'),
                contains('other@example.com'),
                contains('alice@example.com'),
              ),
            ),
          ),
        );
      },
    );

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

    test(
      'logs push_status=unsupported when server has no eventSourceUrl',
      () async {
        final recorder = _PushStatusRecorder();
        final r = _makeRepos(
          httpClient: makeSseClient(),
          appLogger: AppLogger(recorder),
        );
        await r.accounts.addAccount(_jmapAccount, 'pw');

        await r.emails.watchJmapPush('jmap-1', 'pw').toList();

        final pushRows =
            recorder.entries.where((e) => e.event == 'sync.jmap.push').toList();
        expect(pushRows, hasLength(1));
        expect(
          pushRows.single.dataJson,
          contains('"push_status":"unsupported"'),
        );
        expect(pushRows.single.accountId, 'jmap-1');
      },
    );

    test('logs push_status=connected once the SSE stream opens', () async {
      final sseController = StreamController<List<int>>();
      final recorder = _PushStatusRecorder();
      final r = _makeRepos(
        httpClient: makeSseClient(
          eventSourceUrl: 'https://jmap.example.com/events/',
          sseStream: sseController.stream,
        ),
        appLogger: AppLogger(recorder),
      );
      await r.accounts.addAccount(_jmapAccount, 'pw');

      final sub = r.emails.watchJmapPush('jmap-1', 'pw').listen((_) {});
      await Future.delayed(const Duration(milliseconds: 50));

      final connectedRows = recorder.entries
          .where(
            (e) =>
                e.event == 'sync.jmap.push' &&
                (e.dataJson ?? '').contains('"push_status":"connected"'),
          )
          .toList();
      expect(connectedRows, hasLength(1));

      await sub.cancel();
      await sseController.close();
    });

    test('logs push_status=closed when SSE stream ends', () async {
      final sseController = StreamController<List<int>>();
      final recorder = _PushStatusRecorder();
      final r = _makeRepos(
        httpClient: makeSseClient(
          eventSourceUrl: 'https://jmap.example.com/events/',
          sseStream: sseController.stream,
        ),
        appLogger: AppLogger(recorder),
      );
      await r.accounts.addAccount(_jmapAccount, 'pw');

      final sub = r.emails.watchJmapPush('jmap-1', 'pw').listen((_) {});
      await Future.delayed(const Duration(milliseconds: 50));

      await sseController.close();
      await Future.delayed(const Duration(milliseconds: 50));

      final closedRows = recorder.entries
          .where(
            (e) =>
                e.event == 'sync.jmap.push' &&
                (e.dataJson ?? '').contains('"push_status":"closed"'),
          )
          .toList();
      expect(closedRows, hasLength(1));

      await sub.cancel();
    });

    test('expands the RFC 8620 eventSourceUrl template (issue #490)', () async {
      // Stalwart advertises a URI template — the placeholders must be filled
      // in before the request or the server rejects it with HTTP 400.
      final client = _SseTestClient(
        eventSourceUrl: 'https://jmap.example.com/eventsource/'
            '?types={types}&closeafter={closeafter}&ping={ping}',
        sseStream: const Stream.empty(),
      );
      final r = _makeRepos(httpClient: client);
      await r.accounts.addAccount(_jmapAccount, 'pw');

      final sub = r.emails.watchJmapPush('jmap-1', 'pw').listen((_) {});
      await Future.delayed(const Duration(milliseconds: 50));

      final uri = client.capturedSseUri;
      expect(uri, isNotNull);
      expect(uri.toString(), isNot(contains('{')));
      expect(uri!.queryParameters['types'], '*');
      expect(uri.queryParameters['closeafter'], 'no');
      expect(uri.queryParameters['ping'], '30');

      await sub.cancel();
    });

    test('logs the resolved sseUrl on the connected row', () async {
      final sseController = StreamController<List<int>>();
      final recorder = _PushStatusRecorder();
      final r = _makeRepos(
        httpClient: _SseTestClient(
          eventSourceUrl: 'https://jmap.example.com/eventsource/'
              '?types={types}&closeafter={closeafter}&ping={ping}',
          sseStream: sseController.stream,
        ),
        appLogger: AppLogger(recorder),
      );
      await r.accounts.addAccount(_jmapAccount, 'pw');

      final sub = r.emails.watchJmapPush('jmap-1', 'pw').listen((_) {});
      await Future.delayed(const Duration(milliseconds: 50));

      final connected = recorder.entries.singleWhere(
        (e) =>
            e.event == 'sync.jmap.push' &&
            (e.dataJson ?? '').contains('"push_status":"connected"'),
      );
      expect(connected.dataJson, contains('"sseUrl":'));
      expect(connected.dataJson, contains('types=*'));

      await sub.cancel();
      await sseController.close();
    });

    test(
      'logs push_status=sse_status_400 with the response body when the '
      'endpoint rejects the request',
      () async {
        final recorder = _PushStatusRecorder();
        final r = _makeRepos(
          httpClient: _SseTestClient(
            eventSourceUrl: 'https://jmap.example.com/eventsource/',
            sseStream: const Stream.empty(),
            sseStatus: 400,
            sseBody: 'Missing required "types" parameter',
          ),
          appLogger: AppLogger(recorder),
        );
        await r.accounts.addAccount(_jmapAccount, 'pw');

        await r.emails.watchJmapPush('jmap-1', 'pw').toList();

        final row = recorder.entries.singleWhere(
          (e) => e.event == 'sync.jmap.push',
        );
        expect(row.dataJson, contains('"push_status":"sse_status_400"'));
        expect(row.dataJson, contains('"httpStatus":400'));
        expect(row.dataJson, contains('Missing required'));
        expect(row.dataJson, contains('"sseUrl":'));
      },
    );
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
              headersJson: const Value('[]'),
              mimeTreeJson: const Value('{"type":"text/plain"}'),
              cachedAt: Value(DateTime.now()),
            ),
          );

      final body = await r.emails.getEmailBody('acc-1:1');

      expect(body.textBody, 'cached text');
    });

    test(
      'self-heals a cached row that has null mimeTreeJson by refetching',
      () async {
        // A row written before the structure-fetch existed: textBody is
        // present and cachedAt is fresh, but mimeTreeJson is null. The
        // cache should be treated as stale and trigger a network call.
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
                textBody: const Value('legacy text'),
                cachedAt: Value(DateTime.now()),
              ),
            );

        // _makeRepos wires an IMAP connect that throws UnsupportedError, so
        // the cache-bypass attempt surfaces as that error rather than
        // returning the stale row.
        expect(
          () => r.emails.getEmailBody('acc-1:1'),
          throwsA(isA<UnsupportedError>()),
        );
      },
    );

    test('forceRefresh: true bypasses an otherwise-fresh cached row', () async {
      // A fully-populated, fresh cache row would normally be returned. With
      // forceRefresh: true the repo must skip it and attempt a network
      // fetch, which _makeRepos surfaces as UnsupportedError.
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
              headersJson: const Value('[]'),
              mimeTreeJson: const Value('{"type":"text/plain"}'),
              cachedAt: Value(DateTime.now()),
            ),
          );

      expect(
        () => r.emails.getEmailBody('acc-1:1', forceRefresh: true),
        throwsA(isA<UnsupportedError>()),
      );
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

  group('IMAP send hang protection', () {
    const draft = EmailDraft(
      from: EmailAddress(name: 'Alice', email: 'alice@example.com'),
      to: [EmailAddress(name: 'Alice', email: 'alice@example.com')],
      cc: [],
      subject: 'Test',
      body: 'Body',
    );

    test('sendEmail aborts with TimeoutException when SMTP send hangs',
        () async {
      final hangingSmtp = _HangingSmtpClient();
      final r = _makeRepos(
        sendOperationTimeout: const Duration(milliseconds: 50),
        smtpConnect: (Account _, String __, String ___) async => hangingSmtp,
        imapConnect: (Account _, String __, String ___) async =>
            _AppendCapturingImapClient(),
      );
      await r.accounts.addAccount(_account, 'pw');

      await expectLater(
        r.emails.sendEmail('acc-1', draft),
        throwsA(isA<TimeoutException>()),
      );
      expect(
        hangingSmtp.quitCalled,
        isTrue,
        reason: 'quit must run in finally',
      );
    });

    test('sendEmail passes responseTimeout through to IMAP appendMessage',
        () async {
      final spy = _AppendCapturingImapClient();
      final r = _makeRepos(
        sendOperationTimeout: const Duration(seconds: 7),
        smtpConnect: (Account _, String __, String ___) async =>
            _NoOpSmtpClient(),
        imapConnect: (Account _, String __, String ___) async => spy,
      );
      await r.accounts.addAccount(_account, 'pw');

      await r.emails.sendEmail('acc-1', draft);

      expect(spy.lastAppendTimeout, const Duration(seconds: 7));
    });

    test('sendEmail aborts with TimeoutException when SMTP connect hangs',
        () async {
      final r = _makeRepos(
        sendOperationTimeout: const Duration(milliseconds: 50),
        smtpConnect: (Account _, String __, String ___) =>
            Completer<imap.SmtpClient>().future,
        imapConnect: (Account _, String __, String ___) async =>
            _AppendCapturingImapClient(),
      );
      await r.accounts.addAccount(_account, 'pw');

      await expectLater(
        r.emails.sendEmail('acc-1', draft),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('sendEmail aborts with TimeoutException when IMAP connect hangs',
        () async {
      final r = _makeRepos(
        sendOperationTimeout: const Duration(milliseconds: 50),
        smtpConnect: (Account _, String __, String ___) async =>
            _NoOpSmtpClient(),
        imapConnect: (Account _, String __, String ___) =>
            Completer<imap.ImapClient>().future,
      );
      await r.accounts.addAccount(_account, 'pw');

      await expectLater(
        r.emails.sendEmail('acc-1', draft),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('sendEmail aborts with TimeoutException when IMAP createMailbox hangs',
        () async {
      final hangingMailbox = _HangingCreateMailboxImapClient();
      final r = _makeRepos(
        sendOperationTimeout: const Duration(milliseconds: 50),
        smtpConnect: (Account _, String __, String ___) async =>
            _NoOpSmtpClient(),
        imapConnect: (Account _, String __, String ___) async => hangingMailbox,
      );
      await r.accounts.addAccount(_account, 'pw');

      await expectLater(
        r.emails.sendEmail('acc-1', draft),
        throwsA(isA<TimeoutException>()),
      );
      expect(
        hangingMailbox.logoutCalled,
        isTrue,
        reason: 'logout must run in finally',
      );
    });

    test(
      'SMTP connect timeout carries phase name + host:port so the sent-queue '
      'row surfaces the root cause (#323)',
      () async {
        final r = _makeRepos(
          sendOperationTimeout: const Duration(milliseconds: 50),
          smtpConnect: (Account _, String __, String ___) =>
              Completer<imap.SmtpClient>().future,
          imapConnect: (Account _, String __, String ___) async =>
              _AppendCapturingImapClient(),
        );
        await r.accounts.addAccount(_account, 'pw');

        await expectLater(
          r.emails.sendEmail('acc-1', draft),
          throwsA(
            isA<TimeoutException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('SMTP connect/auth timed out'),
                contains('smtp.example.com'),
              ),
            ),
          ),
        );
      },
    );

    test(
      'IMAP connect timeout carries the IMAP host:port',
      () async {
        final r = _makeRepos(
          sendOperationTimeout: const Duration(milliseconds: 50),
          smtpConnect: (Account _, String __, String ___) async =>
              _NoOpSmtpClient(),
          imapConnect: (Account _, String __, String ___) =>
              Completer<imap.ImapClient>().future,
        );
        await r.accounts.addAccount(_account, 'pw');

        await expectLater(
          r.emails.sendEmail('acc-1', draft),
          throwsA(
            isA<TimeoutException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('IMAP connect/login'),
                contains('imap.example.com'),
              ),
            ),
          ),
        );
      },
    );
  });

  group('IMAP folder deleted on server', () {
    test(
      'syncEmails prunes local mailbox when SELECT raises NONEXISTENT',
      () async {
        final r = _makeRepos(
          imapConnect: (Account _, String __, String ___) async =>
              _NonExistentSelectImapClient(),
        );
        await r.accounts.addAccount(_account, 'pw');

        // Seed a local mailbox + email + checkpoint + pending change.
        await r.db.into(r.db.mailboxes).insert(
              MailboxesCompanion.insert(
                id: 'acc-1:Old',
                accountId: 'acc-1',
                path: 'Old',
                name: 'Old',
              ),
            );
        await r.db.into(r.db.emails).insert(
              EmailsCompanion.insert(
                id: 'acc-1:Old:1',
                accountId: 'acc-1',
                mailboxPath: 'Old',
                uid: 1,
                receivedAt: DateTime(2024),
              ),
            );
        await r.db.into(r.db.syncStates).insertOnConflictUpdate(
              SyncStatesCompanion.insert(
                accountId: 'acc-1',
                resourceType: 'IMAP:Old',
                state: '{"uidValidity":1,"lastUid":1}',
                syncedAt: DateTime(2024),
              ),
            );
        await r.db.into(r.db.pendingChanges).insert(
              PendingChangesCompanion.insert(
                accountId: 'acc-1',
                resourceType: 'email',
                resourceId: 'acc-1:Old:1',
                changeType: 'flag_seen',
                payload: jsonEncode({
                  'uid': 1,
                  'mailboxPath': 'Old',
                  'seen': true,
                }),
                createdAt: DateTime.now(),
              ),
            );

        // Must return zero, not throw.
        final result = await r.emails.syncEmails('acc-1', 'Old');
        expect(result.fetched, 0);

        final mailboxes = await r.db.select(r.db.mailboxes).get();
        expect(mailboxes, isEmpty);
        final emails = await r.db.select(r.db.emails).get();
        expect(emails, isEmpty);
        final states = await r.db.select(r.db.syncStates).get();
        expect(states.where((s) => s.resourceType == 'IMAP:Old'), isEmpty);
        final pending = await r.db.select(r.db.pendingChanges).get();
        expect(pending, isEmpty);
      },
    );
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

  group('IMAP getEmailBody with attachment-disposition top-level part', () {
    test(
      'does not crash when ContentInfo.fetchId is empty (issue #182)',
      () async {
        // Regression test for #182: a single-part message whose top-level part
        // is itself marked Content-Disposition: attachment yields a ContentInfo
        // with an empty fetchId. MimeMessage.getPart('') throws, which used to
        // bubble up as an InvalidArgumentException from getEmailBody.
        final r = _makeRepos(
          imapConnect: (Account _, String __, String ___) async =>
              _AttachmentBodyImapClient(),
        );
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

        final body = await r.emails.getEmailBody('acc-1:1');

        final row = await (r.db.select(r.db.emailBodies)
              ..where((t) => t.emailId.equals('acc-1:1')))
            .getSingle();
        final attachments = (jsonDecode(row.attachmentsJson) as List<dynamic>)
            .cast<Map<String, dynamic>>();
        expect(attachments, hasLength(1));
        expect(attachments.first['filename'], 'document.pdf');
        expect(attachments.first['fetchPartId'], '');
        expect(body.emailId, 'acc-1:1');
      },
    );
  });

  group('JMAP fetchRawRfc822', () {
    // Regression tests for #264: the JMAP branch used `.first` on the
    // Email/get list, which threw an unhelpful `Bad state: No element` when
    // the server returned an empty list (email destroyed server-side or the
    // id was rewritten). The IMAP branch already guarded with a descriptive
    // StateError; the JMAP branch now matches.
    test('throws a descriptive StateError when the list is empty', () async {
      final r = _makeRepos(
        httpClient: _mockJmapEmails(
          apiResponses: [
            _emailGetOnly(state: 'es1', list: const []),
          ],
        ),
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

      expect(
        () => r.emails.fetchRawRfc822('jmap-1:e1'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('e1'),
          ),
        ),
      );
    });

    test('throws when the returned email has no blobId', () async {
      final r = _makeRepos(
        httpClient: _mockJmapEmails(
          apiResponses: [
            _emailGetOnly(
              state: 'es1',
              list: [
                {'id': 'e1'},
              ],
            ),
          ],
        ),
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

      expect(
        () => r.emails.fetchRawRfc822('jmap-1:e1'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('blobId'),
          ),
        ),
      );
    });
  });

  group('IMAP preview (issue #228)', () {
    test('syncEmails writes a preview snippet on the email and thread rows',
        () async {
      final r = _makeRepos(
        imapConnect: (Account _, String __, String ___) async =>
            _PreviewSyncImapClient(
          messages: {
            42: _PreviewTestMessage(
              subject: 'Hello',
              from: 'sender@example.com',
              text: 'Line one.\r\nLine two — with a NBSP inside.',
              messageId: '<m42@example.com>',
            ),
          },
        ),
      );
      await r.accounts.addAccount(_account, 'pw');

      await r.emails.syncEmails('acc-1', 'INBOX');

      final emailRow = await (r.db.select(r.db.emails)
            ..where((t) => t.id.equals('acc-1:INBOX:42')))
          .getSingle();
      expect(
        emailRow.preview,
        'Line one. Line two — with a NBSP inside.',
      );

      final threadRow = await r.db.select(r.db.threads).getSingle();
      expect(threadRow.preview, emailRow.preview);
    });

    test('syncEmails derives preview from HTML when there is no text part',
        () async {
      final r = _makeRepos(
        imapConnect: (Account _, String __, String ___) async =>
            _PreviewSyncImapClient(
          messages: {
            7: _PreviewTestMessage(
              subject: 'HTML',
              from: 'sender@example.com',
              html: '<p>Hello <b>world</b></p>',
              messageId: '<m7@example.com>',
            ),
          },
        ),
      );
      await r.accounts.addAccount(_account, 'pw');

      await r.emails.syncEmails('acc-1', 'INBOX');

      final emailRow = await (r.db.select(r.db.emails)
            ..where((t) => t.id.equals('acc-1:INBOX:7')))
          .getSingle();
      expect(emailRow.preview, 'Hello world');
    });

    test('getEmailBody backfills a null preview and refreshes the thread',
        () async {
      final r = _makeRepos(
        imapConnect: (Account _, String __, String ___) async =>
            _PreviewBodyImapClient(),
      );
      await r.accounts.addAccount(_account, 'pw');

      // Seed a message that predates the preview-on-sync change: the row
      // exists but its preview column is still NULL and there's no thread
      // row yet (or one with a null preview).
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:INBOX:1',
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              uid: 1,
              receivedAt: DateTime(2024),
              threadId: const Value('t1'),
            ),
          );
      await r.db.into(r.db.threads).insert(
            ThreadsCompanion.insert(
              id: 't1',
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              latestDate: DateTime(2024),
              latestEmailId: 'acc-1:INBOX:1',
            ),
          );

      await r.emails.getEmailBody('acc-1:INBOX:1');

      final emailRow = await (r.db.select(r.db.emails)
            ..where((t) => t.id.equals('acc-1:INBOX:1')))
          .getSingle();
      expect(emailRow.preview, 'Backfilled preview body.');

      final threadRow = await (r.db.select(r.db.threads)
            ..where((t) => t.id.equals('t1')))
          .getSingle();
      expect(threadRow.preview, 'Backfilled preview body.');
    });

    test('getEmailBody leaves a non-null preview untouched', () async {
      final r = _makeRepos(
        imapConnect: (Account _, String __, String ___) async =>
            _PreviewBodyImapClient(),
      );
      await r.accounts.addAccount(_account, 'pw');

      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:INBOX:1',
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              uid: 1,
              receivedAt: DateTime(2024),
              preview: const Value('Existing preview'),
            ),
          );

      await r.emails.getEmailBody('acc-1:INBOX:1');

      final emailRow = await (r.db.select(r.db.emails)
            ..where((t) => t.id.equals('acc-1:INBOX:1')))
          .getSingle();
      expect(emailRow.preview, 'Existing preview');
    });
  });

  group('diagnoseMailbox (#511)', () {
    Future<void> insertMailboxRow(
      AppDatabase db,
      String accountId,
      String path, {
      int total = 0,
      int unread = 0,
    }) =>
        db.into(db.mailboxes).insert(
              MailboxesCompanion.insert(
                id: '$accountId:$path',
                accountId: accountId,
                path: path,
                name: path,
                totalCount: Value(total),
                unreadCount: Value(unread),
              ),
            );

    Future<void> insertEmailRow(
      AppDatabase db,
      String accountId,
      String path,
      int uid,
    ) =>
        db.into(db.emails).insert(
              EmailsCompanion.insert(
                id: '$accountId:$uid',
                accountId: accountId,
                mailboxPath: path,
                uid: uid,
                receivedAt: DateTime(2024),
              ),
            );

    test('surfaces a stale zero IMAP folder count', () async {
      final client = _DiagnosticsImapClient(
        exists: 3,
        allUids: [1, 2, 3],
        unseenUids: [1],
      );
      final r = _makeRepos(imapConnect: (_, __, ___) async => client);
      await r.accounts.addAccount(_account, 'pw');
      // Cached count is 0 even though the folder holds three messages (#511).
      await insertMailboxRow(r.db, 'acc-1', 'INBOX');
      for (final uid in [1, 2, 3]) {
        await insertEmailRow(r.db, 'acc-1', 'INBOX', uid);
      }

      final d = await r.emails.diagnoseMailbox('acc-1', 'INBOX');

      expect(d.protocol, 'IMAP');
      expect(d.cachedTotal, 0);
      expect(d.localEmailRows, 3);
      expect(d.serverTotal, 3);
      expect(d.serverUnread, 1);
      expect(d.serverMessageCount, 3);
      expect(d.missingLocally, isEmpty);
      expect(d.missingOnServer, isEmpty);
      expect(d.error, isNull);
      expect(d.reachedServer, isTrue);
      expect(d.conclusions.first, contains('shows 0'));
    });

    test('detects IMAP messages missing locally and on the server', () async {
      final client = _DiagnosticsImapClient(
        exists: 2,
        allUids: [1, 2],
        unseenUids: [],
      );
      final r = _makeRepos(imapConnect: (_, __, ___) async => client);
      await r.accounts.addAccount(_account, 'pw');
      // Local cache holds uid 1 (also on the server) and a ghost uid 9.
      await insertEmailRow(r.db, 'acc-1', 'INBOX', 1);
      await insertEmailRow(r.db, 'acc-1', 'INBOX', 9);

      final d = await r.emails.diagnoseMailbox('acc-1', 'INBOX');

      expect(d.serverMessageCount, 2);
      expect(d.missingLocally, ['2']);
      expect(d.missingOnServer, ['acc-1:9']);
    });

    test('counts orphaned thread rows and no longer reports "no '
        'discrepancies" (#523)', () async {
      // Cached/server/local all agree at 1 message, but the folder carries
      // extra thread rows backed by no email — the reported symptom.
      final client = _DiagnosticsImapClient(
        exists: 1,
        allUids: [1],
        unseenUids: [],
      );
      final r = _makeRepos(imapConnect: (_, __, ___) async => client);
      await r.accounts.addAccount(_account, 'pw');
      await insertMailboxRow(r.db, 'acc-1', 'Done', total: 1);
      await insertEmailRow(r.db, 'acc-1', 'Done', 1);
      for (var i = 0; i < 17; i++) {
        await r.db.into(r.db.threads).insert(
              ThreadsCompanion.insert(
                id: 'orphan-$i',
                accountId: 'acc-1',
                mailboxPath: 'Done',
                latestDate: DateTime(2024),
                latestEmailId: 'orphan-$i-latest',
              ),
            );
      }

      final d = await r.emails.diagnoseMailbox('acc-1', 'Done');

      expect(d.localEmailRows, 1);
      expect(d.localThreadRows, 17);
      expect(d.orphanThreadRows, 17);
      // The misleading "No discrepancies found" fallback must not fire.
      expect(
        d.conclusions.any((c) => c.contains('No discrepancies')),
        isFalse,
      );
      expect(d.conclusions.any((c) => c.contains('phantom')), isTrue);
    });

    test('surfaces a stale zero JMAP folder count', () async {
      final r = _makeRepos(httpClient: _mockJmapDiagnostics());
      await r.accounts.addAccount(_jmapAccount, 'pw');
      await insertMailboxRow(r.db, 'jmap-1', 'a');

      final d = await r.emails.diagnoseMailbox('jmap-1', 'a');

      expect(d.protocol, 'JMAP');
      expect(d.cachedTotal, 0);
      expect(d.serverTotal, 5);
      expect(d.serverUnread, 2);
      expect(d.serverMessageCount, 5);
      expect(d.missingLocally, hasLength(5));
      expect(d.missingOnServer, isEmpty);
      expect(d.reachedServer, isTrue);
      expect(d.conclusions.first, contains('shows 0'));
    });

    test('reports the error when the server cannot be reached', () async {
      // Default _makeRepos uses an IMAP connect that always throws.
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      await insertMailboxRow(r.db, 'acc-1', 'INBOX');
      await insertEmailRow(r.db, 'acc-1', 'INBOX', 1);
      await insertEmailRow(r.db, 'acc-1', 'INBOX', 2);

      final d = await r.emails.diagnoseMailbox('acc-1', 'INBOX');

      expect(d.error, isNotNull);
      expect(d.serverMessageCount, isNull);
      expect(d.reachedServer, isFalse);
      expect(d.localEmailRows, 2);
      expect(d.conclusions.first, contains('Could not reach the server'));
    });
  });
}

// ── Fakes for folder diagnostics tests (#511) ────────────────────────────────

/// IMAP fake that reports an EXISTS count and answers `UID SEARCH ALL/UNSEEN`
/// from fixed uid lists, so [EmailRepositoryImpl.diagnoseMailbox] sees the
/// same figures a real server would return for a SELECTed mailbox.
class _DiagnosticsImapClient extends FakeImapClient {
  _DiagnosticsImapClient({
    required this.exists,
    required this.allUids,
    required this.unseenUids,
  });

  final int exists;
  final List<int> allUids;
  final List<int> unseenUids;

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
        messagesExists: exists,
      );

  @override
  Future<imap.SearchImapResult> uidSearchMessages({
    String searchCriteria = 'UNSEEN',
    List<imap.ReturnOption>? returnOptions,
    Duration? responseTimeout,
  }) async {
    final hits = searchCriteria == 'UNSEEN' ? unseenUids : allUids;
    return imap.SearchImapResult()
      ..matchingSequence = imap.MessageSequence.fromIds(hits, isUid: true);
  }
}

/// Mock JMAP transport returning a session, one `Mailbox/get` (total 5,
/// unread 2) and one `Email/query` (five ids) — a folder whose cached count
/// has drifted to zero while the server still holds messages.
http.Client _mockJmapDiagnostics() {
  var callIndex = 0;
  final apiResponses = <Map<String, dynamic>>[
    {
      'sessionState': 'sess1',
      'methodResponses': [
        [
          'Mailbox/get',
          {
            'accountId': 'acct1',
            'state': 'mbstate',
            'list': [
              {'id': 'a', 'totalEmails': 5, 'unreadEmails': 2},
            ],
          },
          '0',
        ],
      ],
    },
    {
      'sessionState': 'sess1',
      'methodResponses': [
        [
          'Email/query',
          {
            'accountId': 'acct1',
            'ids': ['e1', 'e2', 'e3', 'e4', 'e5'],
            'total': 5,
            'position': 0,
          },
          '0',
        ],
      ],
    },
  ];
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

// ── Fakes for IMAP send hang protection tests ────────────────────────────────

class _HangingSmtpClient extends imap.SmtpClient {
  _HangingSmtpClient() : super('fake.host');

  bool quitCalled = false;

  @override
  Future<imap.SmtpResponse> sendMessage(
    imap.MimeMessage message, {
    bool use8BitEncoding = false,
    imap.MailAddress? from,
    List<imap.MailAddress>? recipients,
  }) =>
      Completer<imap.SmtpResponse>().future;

  @override
  Future<imap.SmtpResponse> quit() async {
    quitCalled = true;
    return imap.SmtpResponse(const []);
  }
}

class _NoOpSmtpClient extends imap.SmtpClient {
  _NoOpSmtpClient() : super('fake.host');

  @override
  Future<imap.SmtpResponse> sendMessage(
    imap.MimeMessage message, {
    bool use8BitEncoding = false,
    imap.MailAddress? from,
    List<imap.MailAddress>? recipients,
  }) async =>
      imap.SmtpResponse(const ['250 OK']);

  @override
  Future<imap.SmtpResponse> quit() async => imap.SmtpResponse(const []);
}

class _AppendCapturingImapClient extends FakeImapClient {
  Duration? lastAppendTimeout;

  @override
  Future<imap.Mailbox> createMailbox(String path) async => imap.Mailbox(
        encodedName: path,
        encodedPath: path,
        flags: [],
        pathSeparator: '/',
      );

  @override
  Future<imap.GenericImapResult> appendMessage(
    imap.MimeMessage message, {
    List<String>? flags,
    imap.Mailbox? targetMailbox,
    String? targetMailboxPath,
    Duration? responseTimeout,
  }) async {
    lastAppendTimeout = responseTimeout;
    return imap.GenericImapResult();
  }
}

class _HangingCreateMailboxImapClient extends FakeImapClient {
  bool logoutCalled = false;

  @override
  Future<imap.Mailbox> createMailbox(String path) =>
      Completer<imap.Mailbox>().future;

  @override
  Future<dynamic> logout() async {
    logoutCalled = true;
  }
}

// ── Additional fake IMAP client for "folder deleted" tests ───────────────────

class _NonExistentSelectImapClient extends FakeImapClient {
  @override
  Future<imap.Mailbox> selectMailboxByPath(
    String path, {
    bool enableCondStore = false,
    imap.QResyncParameters? qresync,
  }) async {
    // Mimic enough_mail's `Mailbox does not exist` / `[NONEXISTENT]` failure.
    throw imap.ImapException(this, 'NO [NONEXISTENT] Mailbox does not exist');
  }
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

// ── Fake IMAP client returning a message whose top-level part is itself an
//    attachment (Content-Disposition: attachment, no multipart). This triggers
//    the empty-fetchId path that crashed in issue #182. ───────────────────────

class _AttachmentBodyImapClient extends FakeImapClient {
  static const String _kRawMime = 'MIME-Version: 1.0\r\n'
      'Content-Type: application/pdf; name="document.pdf"\r\n'
      'Content-Disposition: attachment; filename="document.pdf"\r\n'
      'Content-Transfer-Encoding: base64\r\n'
      '\r\n'
      'JVBERi0xLjAKJeLjz9MK\r\n';

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
      );

  @override
  Future<imap.FetchImapResult> uidFetchMessage(
    int messageUid,
    String fetchContentDefinition, {
    Duration? responseTimeout,
  }) async {
    final msg = imap.MimeMessage.parseFromText(_kRawMime)..uid = messageUid;
    return imap.FetchImapResult([msg], null);
  }
}

// ── SSE test helper ──────────────────────────────────────────────────────────

class _SseTestClient extends http.BaseClient {
  _SseTestClient({
    required this.eventSourceUrl,
    required this.sseStream,
    this.sseStatus = 200,
    this.sseBody = '',
  });

  final String? eventSourceUrl;
  final Stream<List<int>> sseStream;

  /// HTTP status to return for the SSE `GET` (200 = happy path).
  final int sseStatus;

  /// Body served alongside a non-200 [sseStatus] (e.g. the server's 400
  /// explanation). Ignored when [sseStatus] is 200.
  final String sseBody;

  /// The exact URI the repo requested for the SSE stream, captured so tests
  /// can assert the RFC 8620 §7.3 template was expanded before sending.
  Uri? capturedSseUri;

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
      capturedSseUri = request.url;
      if (sseStatus != 200) {
        return http.StreamedResponse(
          Stream.value(utf8.encode(sseBody)),
          sseStatus,
        );
      }
      return http.StreamedResponse(sseStream, 200);
    }
    return http.StreamedResponse(Stream.value(utf8.encode('{}')), 200);
  }
}

// ── Fake IMAP clients for the preview-line tests (issue #228) ───────────────

/// Canned message data used to build synthetic IMAP fetch responses.
class _PreviewTestMessage {
  _PreviewTestMessage({
    required this.subject,
    required this.from,
    required this.messageId,
    this.text,
    this.html,
  });

  final String subject;
  final String from;
  final String messageId;
  final String? text;
  final String? html;

  imap.MimeMessage build(int uid) {
    // Emit a bare-bones RFC 822 message so `decodeTextPlainPart()` and
    // `decodeTextHtmlPart()` return the strings we planted here. The IMAP
    // sync path reads `envelope`, `flags`, `size` etc. separately, so we
    // populate those on the parsed MimeMessage.
    final String rawMime;
    if (text != null && html != null) {
      const boundary = '----=_Boundary_Preview';
      rawMime = [
        'MIME-Version: 1.0',
        'Content-Type: multipart/alternative; boundary="$boundary"',
        '',
        '--$boundary',
        'Content-Type: text/plain; charset=UTF-8',
        '',
        text,
        '--$boundary',
        'Content-Type: text/html; charset=UTF-8',
        '',
        html,
        '--$boundary--',
      ].join('\r\n');
    } else if (text != null) {
      rawMime = [
        'MIME-Version: 1.0',
        'Content-Type: text/plain; charset=UTF-8',
        '',
        text,
      ].join('\r\n');
    } else {
      rawMime = [
        'MIME-Version: 1.0',
        'Content-Type: text/html; charset=UTF-8',
        '',
        html ?? '',
      ].join('\r\n');
    }
    final msg = imap.MimeMessage.parseFromText(rawMime)
      ..uid = uid
      ..size = rawMime.length
      ..flags = <String>[]
      ..envelope = imap.Envelope(
        date: DateTime.utc(2024, 6, 15, 12),
        subject: subject,
        from: [imap.MailAddress(null, from)],
        to: const [imap.MailAddress(null, 'alice@example.com')],
        messageId: messageId,
      );
    return msg;
  }
}

/// Minimal IMAP client that lets `_syncEmailsImap` run end-to-end: it
/// implements `selectMailboxByPath`, `uidSearchMessages` (used both for
/// discovering new UIDs and for deleted-message reconciliation) and
/// `uidFetchMessages`, returning the synthesized messages passed in.
class _PreviewSyncImapClient extends FakeImapClient {
  _PreviewSyncImapClient({required this.messages});

  final Map<int, _PreviewTestMessage> messages;

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
        uidValidity: 1,
      );

  @override
  Future<imap.SearchImapResult> uidSearchMessages({
    String searchCriteria = 'ALL',
    List<imap.ReturnOption>? returnOptions,
    Duration? responseTimeout,
  }) async {
    final uids = messages.keys.toList()..sort();
    return imap.SearchImapResult()
      ..matchingSequence = imap.MessageSequence.fromIds(uids, isUid: true);
  }

  @override
  Future<imap.FetchImapResult> uidFetchMessages(
    imap.MessageSequence sequence,
    String? fetchContentDefinition, {
    int? changedSinceModSequence,
    Duration? responseTimeout,
  }) async {
    final built = <imap.MimeMessage>[
      for (final uid in sequence.toList())
        if (messages[uid] != null) messages[uid]!.build(uid),
    ];
    return imap.FetchImapResult(built, null);
  }
}

/// Serves a canned RFC 822 body for `getEmailBody`'s IMAP branch so we can
/// exercise the opportunistic preview backfill path.
class _PreviewBodyImapClient extends FakeImapClient {
  static const String _kRawMime = 'MIME-Version: 1.0\r\n'
      'Content-Type: text/plain; charset=UTF-8\r\n'
      '\r\n'
      'Backfilled preview body.\r\n';

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
      );

  @override
  Future<imap.FetchImapResult> uidFetchMessage(
    int messageUid,
    String fetchContentDefinition, {
    Duration? responseTimeout,
  }) async {
    final msg = imap.MimeMessage.parseFromText(_kRawMime)..uid = messageUid;
    return imap.FetchImapResult([msg], null);
  }
}
