// Compares the local DB rows produced by IMAP and JMAP sync of the same
// Stalwart user. The sync logic for the two protocols is independent, so this
// guards against either path drifting out of step with the other.
//
// Run via: stalwart-dev/test.sh test/backend/account_comparison_stalwart_test.dart
//
// Environment variables (set by the runner script):
//   STALWART_URL       — JMAP base URL, e.g. http://127.0.0.1:8080
//   STALWART_IMAP_HOST, STALWART_IMAP_PORT
//   STALWART_SMTP_HOST, STALWART_SMTP_PORT
//   STALWART_USER_B / STALWART_PASS_B  (alice@example.com)

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:enough_mail/enough_mail.dart';
import 'package:sharedinbox/core/models/account.dart' as model;
import 'package:sharedinbox/core/sync/account_comparison.dart';
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';
import 'package:test/test.dart';

import '../unit/account_repository_impl_test.dart' show MapSecureStorage;
import '../unit/db_test_helper.dart';

String _env(String key, [String fallback = '']) =>
    Platform.environment[key] ?? fallback;

Future<ImapClient> _imapConnectPlain(
  model.Account account,
  String username,
  String password,
) async {
  final client = ImapClient(
    defaultResponseTimeout: const Duration(seconds: 20),
  );
  await client.connectToServer(
    account.imapHost,
    account.imapPort,
    isSecure: false,
  );
  await client.login(username, password);
  return client;
}

Future<ImapClient> _imapConnectDirect({
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

Future<void> _clearMailbox(
  ImapClient client, {
  String mailboxPath = 'INBOX',
}) async {
  final box = await client.selectMailboxByPath(mailboxPath);
  if (box.messagesExists == 0) return;
  final result = await client.uidSearchMessages(searchCriteria: 'ALL');
  final uids = result.matchingSequence?.toList() ?? [];
  if (uids.isEmpty) return;
  final seq = MessageSequence.fromIds(uids, isUid: true);
  await client.uidMarkDeleted(seq);
  await client.uidExpunge(seq);
}

Future<void> _appendToInbox(
  ImapClient client, {
  required String subject,
  required String userEmail,
  String body = 'Hello',
}) async {
  final msg = MessageBuilder()
    ..from = [MailAddress('Alice', userEmail)]
    ..to = [MailAddress('Alice', userEmail)]
    ..subject = subject
    ..text = body;
  await client.appendMessage(
    msg.buildMimeMessage(),
    targetMailboxPath: 'INBOX',
  );
}

void main() {
  late String stalwartUrl;
  late String imapHost;
  late int imapPort;
  late String smtpHost;
  late int smtpPort;
  late String userEmail;
  late String userPass;
  late Directory cacheDir;

  setUpAll(() {
    configureSqliteForTests();
    stalwartUrl = _env('STALWART_URL', 'http://127.0.0.1:8080');
    imapHost = _env('STALWART_IMAP_HOST', '127.0.0.1');
    imapPort = int.parse(_env('STALWART_IMAP_PORT', '1430'));
    smtpHost = _env('STALWART_SMTP_HOST', '127.0.0.1');
    smtpPort = int.parse(_env('STALWART_SMTP_PORT', '1025'));
    userEmail = _env('STALWART_USER_B', 'alice@example.com');
    userPass = _env('STALWART_PASS_B', 'secret');
    cacheDir = Directory.systemTemp.createTempSync('compare_stalwart_test_');
  });

  tearDownAll(() => cacheDir.deleteSync(recursive: true));

  setUp(() async {
    final client = await _imapConnectDirect(
      host: imapHost,
      port: imapPort,
      user: userEmail,
      pass: userPass,
    );
    try {
      await _clearMailbox(client);
    } finally {
      await client.logout();
    }
  });

  test('IMAP and JMAP sync of the same user produce identical local DBs',
      () async {
    final imapAccount = model.Account(
      id: 'compare-imap',
      displayName: 'Alice (IMAP)',
      email: userEmail,
      imapHost: imapHost,
      imapPort: imapPort,
      imapSsl: false,
      smtpHost: smtpHost,
      smtpPort: smtpPort,
    );
    final jmapAccount = model.Account(
      id: 'compare-jmap',
      displayName: 'Alice (JMAP)',
      email: userEmail,
      type: model.AccountType.jmap,
      jmapUrl: '$stalwartUrl/.well-known/jmap',
      imapHost: imapHost,
      imapPort: imapPort,
      imapSsl: false,
      smtpHost: smtpHost,
      smtpPort: smtpPort,
    );

    // Both accounts share a single in-memory DB so the comparison service
    // sees them side by side.
    final db = openTestDatabase();
    addTearDown(db.close);
    final secureStorage = MapSecureStorage();
    final accounts = AccountRepositoryImpl(db, secureStorage);
    await accounts.addAccount(imapAccount, userPass);
    await accounts.addAccount(jmapAccount, userPass);

    final emailRepo = EmailRepositoryImpl(
      db,
      accounts,
      imapConnect: _imapConnectPlain,
      getCacheDir: () async => cacheDir,
    );
    final mailboxRepo = MailboxRepositoryImpl(
      db,
      accounts,
      imapConnect: _imapConnectPlain,
    );

    // Seed two emails via IMAP APPEND so both protocols see the same data.
    final imap = await _imapConnectDirect(
      host: imapHost,
      port: imapPort,
      user: userEmail,
      pass: userPass,
    );
    try {
      final ts = DateTime.now().millisecondsSinceEpoch;
      await _appendToInbox(
        imap,
        subject: 'compare-one-$ts',
        userEmail: userEmail,
      );
      await _appendToInbox(
        imap,
        subject: 'compare-two-$ts',
        userEmail: userEmail,
      );
    } finally {
      await imap.logout();
    }

    // Sync mailboxes + emails on both sides. JMAP mailbox path is the
    // server's opaque id, so look it up after the mailbox sync.
    await mailboxRepo.syncMailboxes(imapAccount.id);
    await emailRepo.syncEmails(imapAccount.id, 'INBOX');

    await mailboxRepo.syncMailboxes(jmapAccount.id);
    final jmapInbox = await (db.select(db.mailboxes)
          ..where(
            (t) => t.accountId.equals(jmapAccount.id) & t.role.equals('inbox'),
          )
          ..limit(1))
        .getSingleOrNull();
    expect(jmapInbox, isNotNull, reason: 'JMAP inbox should be discovered');
    await emailRepo.syncEmails(jmapAccount.id, jmapInbox!.path);

    final result =
        await AccountComparison(db).compare(imapAccount.id, jmapAccount.id);

    expect(
      result.isIdentical,
      isTrue,
      reason: 'Expected zero diff but found:\n'
          'mailboxes=${result.mailboxes.length}, '
          'emails=${result.emails.length}, '
          'bodies=${result.bodies.length}, '
          'unmatchable=${result.unmatchable.length}',
    );
  });
}
