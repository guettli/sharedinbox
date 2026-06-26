import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:enough_mail/enough_mail.dart';
import 'package:sharedinbox/core/models/account.dart' as model;
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';
import 'package:test/test.dart';

import '../unit/account_repository_impl_test.dart' show MapSecureStorage;
import '../unit/db_test_helper.dart';
import 'localhost_mapping_client.dart';

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

void main() {
  late String imapHost;
  late int imapPort;
  late String userEmail;
  late String userPass;
  late model.Account account;
  late AppDatabase db;
  late EmailRepositoryImpl repo;
  late MapSecureStorage secureStorage;

  setUpAll(() {
    configureSqliteForTests();
    imapHost = _env('STALWART_IMAP_HOST', '127.0.0.1');
    imapPort = int.parse(_env('STALWART_IMAP_PORT', '1430'));
    userEmail = _env('STALWART_USER_B', 'alice@example.com');
    userPass = _env('STALWART_PASS_B', 'secret');
    account = model.Account(
      id: 'test',
      displayName: 'Alice',
      email: userEmail,
      imapHost: imapHost,
      imapPort: imapPort,
      imapSsl: false,
      smtpHost: '127.0.0.1',
      smtpPort: 1025,
    );
  });

  late LocalhostMappingClient httpClient;

  setUp(() async {
    db = openTestDatabase();
    secureStorage = MapSecureStorage();
    final accounts = AccountRepositoryImpl(db, secureStorage);
    await accounts.addAccount(account, userPass);
    httpClient = LocalhostMappingClient();
    repo = EmailRepositoryImpl(
      db,
      accounts,
      imapConnect: _imapConnectPlain,
      httpClient: httpClient,
    );

    final client = await _imapConnectPlain(account, userEmail, userPass);
    await client.selectMailboxByPath('INBOX');
    final result = await client.uidSearchMessages(searchCriteria: 'ALL');
    final uids = result.matchingSequence?.toList() ?? [];
    if (uids.isNotEmpty) {
      final seq = MessageSequence.fromIds(uids, isUid: true);
      await client.uidMarkDeleted(seq);
      await client.uidExpunge(seq);
    }
    await client.logout();
  });

  tearDown(() {
    db.close();
    httpClient.close();
  });

  test('verifySyncReliability identifies missing local emails', () async {
    // 1. Inject an email directly into the server via IMAP
    final client = await _imapConnectPlain(account, userEmail, userPass);
    await client.selectMailboxByPath('INBOX');
    final builder = MessageBuilder()
      ..from = [const MailAddress('Sender', 'sender@example.com')]
      ..to = [MailAddress('Alice', userEmail)]
      ..subject = 'Ground Truth Test'
      ..text = 'Hello';
    await client.appendMessage(
      builder.buildMimeMessage(),
      targetMailboxPath: 'INBOX',
    );
    await client.logout();

    // 2. Verify reliability (local DB is empty)
    final result = await repo.verifySyncReliability('test', 'INBOX');
    expect(result.isHealthy, isFalse);
    expect(result.missingLocally, hasLength(1));
    expect(result.missingOnServer, isEmpty);
  });

  test(
    'verifySyncReliability identifies extra local emails (missing on server)',
    () async {
      // 1. Manually insert a row into local DB that doesn't exist on server
      await db.into(db.emails).insert(
            EmailsCompanion.insert(
              id: 'test:999',
              accountId: 'test',
              mailboxPath: 'INBOX',
              uid: 999,
              subject: const Value('Ghost'),
              receivedAt: DateTime.now(),
            ),
          );

      // 2. Verify reliability
      final result = await repo.verifySyncReliability('test', 'INBOX');
      expect(result.isHealthy, isFalse);
      expect(result.missingOnServer, contains('test:999'));
      expect(result.missingLocally, isEmpty);
    },
  );

  test('verifySyncReliability identifies flag mismatches', () async {
    // 1. Sync one email
    final client = await _imapConnectPlain(account, userEmail, userPass);
    await client.selectMailboxByPath('INBOX');
    await client.appendMessage(
      (MessageBuilder()
            ..subject = 'Flag Test'
            ..text = 'Body')
          .buildMimeMessage(),
      targetMailboxPath: 'INBOX',
    );
    await client.logout();

    await repo.syncEmails('test', 'INBOX');
    final emails = await repo.observeEmails('test', 'INBOX').first;
    expect(emails, hasLength(1));
    final emailId = emails.first.id;
    expect(emails.first.isSeen, isFalse);

    // 2. Mark as seen on server only
    final client2 = await _imapConnectPlain(account, userEmail, userPass);
    await client2.selectMailboxByPath('INBOX');
    await client2.uidMarkSeen(MessageSequence.fromAll());
    await client2.logout();

    // 3. Verify reliability
    final result = await repo.verifySyncReliability('test', 'INBOX');
    expect(result.isHealthy, isFalse);
    expect(result.flagMismatches, hasLength(1));
    expect(result.flagMismatches.first.id, emailId);
    expect(result.flagMismatches.first.serverSeen, isTrue);
    expect(result.flagMismatches.first.localSeen, isFalse);
  });

  group('JMAP Reliability', () {
    late String stalwartUrl;
    late model.Account jmapAccount;

    setUp(() async {
      stalwartUrl = _env('STALWART_URL', 'http://127.0.0.1:8080');
      jmapAccount = model.Account(
        id: 'test-jmap',
        displayName: 'Alice JMAP',
        email: userEmail,
        type: model.AccountType.jmap,
        jmapUrl: '$stalwartUrl/.well-known/jmap',
        imapHost: imapHost,
        imapPort: imapPort,
        imapSsl: false,
        smtpHost: imapHost,
        smtpPort: 1025,
      );
      final accounts = AccountRepositoryImpl(db, secureStorage);
      await accounts.addAccount(jmapAccount, userPass);
    });

    test('identifies missing local emails in JMAP', () async {
      // 1. Inject via IMAP (Stalwart reflects it in JMAP)
      final client = await _imapConnectPlain(account, userEmail, userPass);
      await client.selectMailboxByPath('INBOX');
      await client.appendMessage(
        (MessageBuilder()..subject = 'JMAP Ground Truth').buildMimeMessage(),
        targetMailboxPath: 'INBOX',
      );
      await client.logout();

      // 2. Need to find the JMAP mailbox ID for INBOX
      final mailboxRepo = MailboxRepositoryImpl(
        db,
        AccountRepositoryImpl(db, secureStorage),
        httpClient: httpClient,
      );
      await mailboxRepo.syncMailboxes('test-jmap');
      final mailboxes = await mailboxRepo.observeMailboxes('test-jmap').first;
      final inbox = mailboxes.firstWhere((m) => m.role == 'inbox');

      // 3. Verify
      final result = await repo.verifySyncReliability('test-jmap', inbox.path);
      expect(result.isHealthy, isFalse);
      expect(result.missingLocally, hasLength(1));
    });
  });
}
