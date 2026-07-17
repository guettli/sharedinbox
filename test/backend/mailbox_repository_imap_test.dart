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
}
