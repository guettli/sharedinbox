// Integration tests for MailboxRepositoryImpl against a real Stalwart instance.
// Run via: stalwart-dev/test.sh
//
// Uses a per-isolate pool user from stalwart_harness.dart so multiple test
// files can run in parallel.

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';
import 'package:test/test.dart';

import '../unit/account_repository_impl_test.dart' show MapSecureStorage;
import '../unit/db_test_helper.dart';
import 'stalwart_harness.dart';

void main() {
  late StalwartEnv env;
  late StalwartTestUser user;
  late Account account;

  setUpAll(() {
    configureSqliteForTests();
    env = StalwartEnv.fromPlatform();
    user = pickPoolUser(env: env);
    account = user.imapAccount(id: 'test', env: env);
  });

  setUp(() => clearStandardMailboxes(env: env, user: user));

  ({
    AppDatabase db,
    AccountRepositoryImpl accounts,
    MailboxRepositoryImpl mailboxes,
  }) makeRepo() {
    final db = openTestDatabase();
    final accounts = AccountRepositoryImpl(db, MapSecureStorage());
    final mailboxes = MailboxRepositoryImpl(
      db,
      accounts,
      imapConnect: testImapConnect,
    );
    return (db: db, accounts: accounts, mailboxes: mailboxes);
  }

  test('syncMailboxes stores mailboxes from IMAP in DB', () async {
    final r = makeRepo();
    await r.accounts.addAccount(account, user.password);
    await r.mailboxes.syncMailboxes('test');

    final mailboxes = await r.mailboxes.observeMailboxes('test').first;
    expect(mailboxes, isNotEmpty);
    expect(mailboxes.map((m) => m.path), contains('INBOX'));
  });

  test('syncMailboxes populates unread and total counts', () async {
    // Append a message so INBOX has at least 1 unseen message.
    final client = await connectImap(env: env, user: user);
    try {
      await appendMessage(
        client,
        subject: 'count-test',
        userEmail: user.email,
      );
    } finally {
      await client.logout();
    }

    final r = makeRepo();
    await r.accounts.addAccount(account, user.password);
    await r.mailboxes.syncMailboxes('test');

    final mailboxes = await r.mailboxes.observeMailboxes('test').first;
    final inbox = mailboxes.firstWhere((m) => m.path == 'INBOX');
    expect(inbox.totalCount, greaterThan(0));
    expect(inbox.unreadCount, greaterThan(0));
  });

  // Same input as the JMAP test in email_repository_jmap_test.dart: a "/" in
  // the typed name is a hierarchy separator, so both protocols end up with
  // Projects containing 2026.
  test('createMailbox with "/" creates a nested IMAP folder', () async {
    final r = makeRepo();
    await r.accounts.addAccount(account, user.password);

    Future<void> dropProjects() async {
      await r.mailboxes.syncMailboxes('test');
      final all = await r.mailboxes.observeMailboxes('test').first;
      final stale = all
          .where(
            (m) =>
                m.displayPath == 'Projects' ||
                m.displayPath.startsWith('Projects/'),
          )
          .toList()
        ..sort((a, b) => b.displayPath.length.compareTo(a.displayPath.length));
      for (final m in stale) {
        await r.mailboxes.deleteMailbox('test', m.path);
      }
    }

    await dropProjects();
    try {
      final leaf = await r.mailboxes.createMailbox('test', 'Projects/2026');
      expect(leaf.name, '2026');
      expect(leaf.displayPath, 'Projects/2026');

      await r.mailboxes.syncMailboxes('test');
      final all = await r.mailboxes.observeMailboxes('test').first;
      expect(all.where((m) => m.displayPath == 'Projects'), hasLength(1));
      final child = all.singleWhere((m) => m.displayPath == 'Projects/2026');
      expect(child.name, '2026');
    } finally {
      await dropProjects();
    }
  });
}
