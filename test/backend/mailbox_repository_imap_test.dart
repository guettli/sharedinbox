// Integration tests for MailboxRepositoryImpl against a real Stalwart instance.
// Run via: stalwart-dev/test.sh
//
// Environment variables (set by the runner script):
//   STALWART_IMAP_HOST, STALWART_IMAP_PORT
//   STALWART_USER_B / STALWART_PASS_B  (alice@example.com)

import 'dart:io';

import 'package:enough_mail/enough_mail.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';
import 'package:test/test.dart';

import '../unit/account_repository_impl_test.dart' show MapSecureStorage;
import '../unit/db_test_helper.dart';

String _env(String key, [String fallback = '']) =>
    Platform.environment[key] ?? fallback;

Future<ImapClient> _imapConnect({
  required String host,
  required int port,
  required String user,
  required String pass,
}) async {
  final client = ImapClient(
    defaultResponseTimeout: const Duration(seconds: 20),
  );
  await client.connectToServer(host, port, isSecure: false);
  await client.login(user, pass);
  return client;
}

void main() {
  late String imapHost;
  late int imapPort;
  late String userEmail;
  late String userPass;
  late Account account;

  setUpAll(() {
    configureSqliteForTests();
    imapHost = _env('STALWART_IMAP_HOST', '127.0.0.1');
    imapPort = int.parse(_env('STALWART_IMAP_PORT', '1430'));
    userEmail = _env('STALWART_USER_B', 'alice@example.com');
    userPass = _env('STALWART_PASS_B', 'secret');
    account = Account(
      id: 'test',
      displayName: 'Alice',
      email: userEmail,
      imapHost: imapHost,
      imapPort: imapPort,
      imapSsl: false,
      smtpHost: imapHost,
      smtpPort: 1025,
    );
  });

  Future<ImapClient> testImapConnect(
    Account a,
    String username,
    String password,
  ) async {
    final client = ImapClient(
      defaultResponseTimeout: const Duration(seconds: 20),
    );
    await client.connectToServer(a.imapHost, a.imapPort, isSecure: false);
    await client.login(username, password);
    return client;
  }

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
    await r.accounts.addAccount(account, userPass);
    await r.mailboxes.syncMailboxes('test');

    final mailboxes = await r.mailboxes.observeMailboxes('test').first;
    expect(mailboxes, isNotEmpty);
    expect(mailboxes.map((m) => m.path), contains('INBOX'));
  });

  test('syncMailboxes populates unread and total counts', () async {
    // Append a message so INBOX has at least 1 unseen message.
    final client = await _imapConnect(
      host: imapHost,
      port: imapPort,
      user: userEmail,
      pass: userPass,
    );
    try {
      await client.selectMailboxByPath('INBOX');
      final msg = MessageBuilder()
        ..from = [MailAddress('Alice', userEmail)]
        ..to = [MailAddress('Alice', userEmail)]
        ..subject = 'count-test'
        ..text = 'body';
      await client.appendMessage(
        msg.buildMimeMessage(),
        targetMailboxPath: 'INBOX',
      );
    } finally {
      await client.logout();
    }

    final r = makeRepo();
    await r.accounts.addAccount(account, userPass);
    await r.mailboxes.syncMailboxes('test');

    final mailboxes = await r.mailboxes.observeMailboxes('test').first;
    final inbox = mailboxes.firstWhere((m) => m.path == 'INBOX');
    expect(inbox.totalCount, greaterThan(0));
    expect(inbox.unreadCount, greaterThan(0));
  });
}
