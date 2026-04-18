import 'package:drift/drift.dart' show Value;
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';

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

Future<imap.ImapClient> _noImapConnect(Account a, String u, String p) =>
    Future.error(UnsupportedError('IMAP unavailable in unit tests'));

({
  AppDatabase db,
  AccountRepositoryImpl accounts,
  MailboxRepositoryImpl mailboxes,
}) _makeRepos() {
  final db = openTestDatabase();
  final accounts = AccountRepositoryImpl(db, MapSecureStorage());
  final mailboxes = MailboxRepositoryImpl(
    db,
    accounts,
    imapConnect: _noImapConnect,
  );
  return (db: db, accounts: accounts, mailboxes: mailboxes);
}

({
  AppDatabase db,
  AccountRepositoryImpl accounts,
  MailboxRepositoryImpl mailboxes,
  FakeImapClient fakeImap,
}) _makeReposWithFake() {
  final db = openTestDatabase();
  final accounts = AccountRepositoryImpl(db, MapSecureStorage());
  final fakeImap = FakeImapClient();
  final mailboxes = MailboxRepositoryImpl(
    db,
    accounts,
    imapConnect: (_, __, ___) async => fakeImap,
  );
  return (db: db, accounts: accounts, mailboxes: mailboxes, fakeImap: fakeImap);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUpAll(configureSqliteForTests);

  group('MailboxRepositoryImpl', () {
    test('observeMailboxes emits empty list initially', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      final mailboxes = await r.mailboxes.observeMailboxes('acc-1').first;
      expect(mailboxes, isEmpty);
    });

    test('observeMailboxes reflects inserted rows ordered by path', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');

      for (final (path, name) in [
        ('Sent', 'Sent'),
        ('INBOX', 'Inbox'),
        ('Drafts', 'Drafts'),
      ]) {
        await r.db.into(r.db.mailboxes).insert(
              MailboxesCompanion.insert(
                id: 'acc-1:$path',
                accountId: 'acc-1',
                path: path,
                name: name,
              ),
            );
      }

      final mailboxes = await r.mailboxes.observeMailboxes('acc-1').first;
      expect(mailboxes.map((m) => m.path).toList(), ['Drafts', 'INBOX', 'Sent']);
    });

    test('observeMailboxes only returns mailboxes for the given account',
        () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');

      const other = Account(
        id: 'acc-2',
        displayName: 'Bob',
        email: 'bob@example.com',
        imapHost: 'imap.example.com',
        smtpHost: 'smtp.example.com',
      );
      await r.accounts.addAccount(other, 'pw2');

      await r.db.into(r.db.mailboxes).insert(
            MailboxesCompanion.insert(
              id: 'acc-1:INBOX',
              accountId: 'acc-1',
              path: 'INBOX',
              name: 'Inbox',
            ),
          );
      await r.db.into(r.db.mailboxes).insert(
            MailboxesCompanion.insert(
              id: 'acc-2:INBOX',
              accountId: 'acc-2',
              path: 'INBOX',
              name: 'Inbox',
            ),
          );

      final mailboxes = await r.mailboxes.observeMailboxes('acc-1').first;
      expect(mailboxes, hasLength(1));
      expect(mailboxes.first.id, 'acc-1:INBOX');
    });

    test('observeMailboxes maps unread/total counts', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');

      await r.db.into(r.db.mailboxes).insert(
            MailboxesCompanion.insert(
              id: 'acc-1:INBOX',
              accountId: 'acc-1',
              path: 'INBOX',
              name: 'Inbox',
              unreadCount: const Value(5),
              totalCount: const Value(42),
            ),
          );

      final mailboxes = await r.mailboxes.observeMailboxes('acc-1').first;
      expect(mailboxes.first.unreadCount, 5);
      expect(mailboxes.first.totalCount, 42);
    });

    test('syncMailboxes propagates IMAP error', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      expect(
        () => r.mailboxes.syncMailboxes('acc-1'),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('syncMailboxes stores mailboxes from IMAP in DB', () async {
      final r = _makeReposWithFake();
      await r.accounts.addAccount(_account, 'pw');
      r.fakeImap.listMailboxesResult = [
        imap.Mailbox(
          encodedName: 'INBOX',
          encodedPath: 'INBOX',
          flags: [],
          pathSeparator: '/',
        ),
        imap.Mailbox(
          encodedName: 'Sent',
          encodedPath: 'Sent',
          flags: [],
          pathSeparator: '/',
        ),
      ];

      await r.mailboxes.syncMailboxes('acc-1');

      final mailboxes =
          await r.mailboxes.observeMailboxes('acc-1').first;
      expect(mailboxes, hasLength(2));
      expect(mailboxes.map((m) => m.path).toSet(), {'INBOX', 'Sent'});
      // statusMailbox fake returns 3 unread / 10 total for all mailboxes
      expect(mailboxes.first.unreadCount, 3);
      expect(mailboxes.first.totalCount, 10);
      expect(r.fakeImap.logoutCalled, isTrue);
    });

    test('syncMailboxes still stores mailbox when statusMailbox throws', () async {
      final r = _makeReposWithFake();
      await r.accounts.addAccount(_account, 'pw');
      r.fakeImap.throwOnStatus = true;
      r.fakeImap.listMailboxesResult = [
        imap.Mailbox(
          encodedName: 'INBOX',
          encodedPath: 'INBOX',
          flags: [],
          pathSeparator: '/',
        ),
      ];

      await r.mailboxes.syncMailboxes('acc-1');

      final mailboxes =
          await r.mailboxes.observeMailboxes('acc-1').first;
      // Mailbox is stored even though STATUS failed; counts default to 0.
      expect(mailboxes, hasLength(1));
      expect(mailboxes.first.unreadCount, 0);
      expect(mailboxes.first.totalCount, 0);
    });
  });
}
