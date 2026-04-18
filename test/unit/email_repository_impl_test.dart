import 'package:drift/drift.dart' show Value;
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter_test/flutter_test.dart';

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

Future<imap.ImapClient> _noImapConnect(Account a, String p) =>
    Future.error(UnsupportedError('IMAP unavailable in unit tests'));

Future<imap.SmtpClient> _noSmtpConnect(Account a, String p) =>
    Future.error(UnsupportedError('SMTP unavailable in unit tests'));

({
  AppDatabase db,
  AccountRepositoryImpl accounts,
  EmailRepositoryImpl emails,
}) _makeRepos() {
  final db = openTestDatabase();
  final storage = MapSecureStorage();
  final accounts = AccountRepositoryImpl(db, storage);
  final emails = EmailRepositoryImpl(
    db,
    accounts,
    imapConnect: _noImapConnect,
    smtpConnect: _noSmtpConnect,
  );
  return (db: db, accounts: accounts, emails: emails);
}

({
  AppDatabase db,
  AccountRepositoryImpl accounts,
  EmailRepositoryImpl emails,
  FakeImapClient fakeImap,
  FakeSmtpClient fakeSmtp,
}) _makeReposWithFakes() {
  final db = openTestDatabase();
  final accounts = AccountRepositoryImpl(db, MapSecureStorage());
  final fakeImap = FakeImapClient();
  final fakeSmtp = FakeSmtpClient();
  final emails = EmailRepositoryImpl(
    db,
    accounts,
    imapConnect: (_, __) async => fakeImap,
    smtpConnect: (_, __) async => fakeSmtp,
  );
  return (
    db: db,
    accounts: accounts,
    emails: emails,
    fakeImap: fakeImap,
    fakeSmtp: fakeSmtp,
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

    test('setFlag seen=true calls uidMarkSeen and updates DB', () async {
      final r = _makeReposWithFakes();
      await r.accounts.addAccount(_account, 'pw');
      await r.db.into(r.db.emails).insert(EmailsCompanion.insert(
            id: 'acc-1:5',
            accountId: 'acc-1',
            mailboxPath: 'INBOX',
            uid: 5,
            receivedAt: DateTime(2024),
          ));

      await r.emails.setFlag('acc-1:5', seen: true);

      expect(r.fakeImap.markSeenCalls, 1);
      expect(r.fakeImap.markUnseenCalls, 0);
      final email = await r.emails.getEmail('acc-1:5');
      expect(email!.isSeen, isTrue);
      expect(r.fakeImap.logoutCalled, isTrue);
    });

    test('setFlag seen=false calls uidMarkUnseen', () async {
      final r = _makeReposWithFakes();
      await r.accounts.addAccount(_account, 'pw');
      await r.db.into(r.db.emails).insert(EmailsCompanion.insert(
            id: 'acc-1:5',
            accountId: 'acc-1',
            mailboxPath: 'INBOX',
            uid: 5,
            receivedAt: DateTime(2024),
          ));

      await r.emails.setFlag('acc-1:5', seen: false);

      expect(r.fakeImap.markUnseenCalls, 1);
      final email = await r.emails.getEmail('acc-1:5');
      expect(email!.isSeen, isFalse);
    });

    test('setFlag flagged=true calls uidMarkFlagged', () async {
      final r = _makeReposWithFakes();
      await r.accounts.addAccount(_account, 'pw');
      await r.db.into(r.db.emails).insert(EmailsCompanion.insert(
            id: 'acc-1:5',
            accountId: 'acc-1',
            mailboxPath: 'INBOX',
            uid: 5,
            receivedAt: DateTime(2024),
          ));

      await r.emails.setFlag('acc-1:5', flagged: true);

      expect(r.fakeImap.markFlaggedCalls, 1);
      final email = await r.emails.getEmail('acc-1:5');
      expect(email!.isFlagged, isTrue);
    });

    test('setFlag flagged=false calls uidMarkUnflagged', () async {
      final r = _makeReposWithFakes();
      await r.accounts.addAccount(_account, 'pw');
      await r.db.into(r.db.emails).insert(EmailsCompanion.insert(
            id: 'acc-1:5',
            accountId: 'acc-1',
            mailboxPath: 'INBOX',
            uid: 5,
            receivedAt: DateTime(2024),
          ));

      await r.emails.setFlag('acc-1:5', flagged: false);

      expect(r.fakeImap.markUnflaggedCalls, 1);
    });

    test('moveEmail removes email from DB and calls uidMove', () async {
      final r = _makeReposWithFakes();
      await r.accounts.addAccount(_account, 'pw');
      await r.db.into(r.db.emails).insert(EmailsCompanion.insert(
            id: 'acc-1:5',
            accountId: 'acc-1',
            mailboxPath: 'INBOX',
            uid: 5,
            receivedAt: DateTime(2024),
          ));

      await r.emails.moveEmail('acc-1:5', 'Archive');

      expect(r.fakeImap.moveEmailCalls, 1);
      expect(await r.emails.getEmail('acc-1:5'), isNull);
      expect(r.fakeImap.logoutCalled, isTrue);
    });

    test('deleteEmail removes email from DB and marks deleted', () async {
      final r = _makeReposWithFakes();
      await r.accounts.addAccount(_account, 'pw');
      await r.db.into(r.db.emails).insert(EmailsCompanion.insert(
            id: 'acc-1:5',
            accountId: 'acc-1',
            mailboxPath: 'INBOX',
            uid: 5,
            receivedAt: DateTime(2024),
          ));

      await r.emails.deleteEmail('acc-1:5');

      expect(r.fakeImap.markDeletedCalls, 1);
      expect(r.fakeImap.expungeCalls, 1);
      expect(await r.emails.getEmail('acc-1:5'), isNull);
      expect(r.fakeImap.logoutCalled, isTrue);
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
  });
}
