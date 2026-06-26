// Integration tests for EmailRepositoryImpl JMAP path against a real Stalwart instance.
// Run via: stalwart-dev/test.sh
//
// Environment variables (set by the runner script):
//   STALWART_URL       — JMAP base URL, e.g. http://127.0.0.1:8080
//   STALWART_IMAP_HOST, STALWART_IMAP_PORT
//   STALWART_SMTP_PORT
//   STALWART_USER_B / STALWART_PASS_B  (alice@example.com)

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:enough_mail/enough_mail.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
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

void main() {
  late String stalwartUrl;
  late String imapHost;
  late int imapPort;
  late String smtpPort;
  late String userEmail;
  late String userPass;
  late Account account;
  late Directory cacheDir;

  setUpAll(() {
    configureSqliteForTests();
    stalwartUrl = _env('STALWART_URL', 'http://127.0.0.1:8080');
    imapHost = _env('STALWART_IMAP_HOST', '127.0.0.1');
    imapPort = int.parse(_env('STALWART_IMAP_PORT', '1430'));
    smtpPort = _env('STALWART_SMTP_PORT', '1025');
    userEmail = _env('STALWART_USER_B', 'alice@example.com');
    userPass = _env('STALWART_PASS_B', 'secret');
    account = Account(
      id: 'test-jmap',
      displayName: 'Alice',
      email: userEmail,
      type: AccountType.jmap,
      jmapUrl: '$stalwartUrl/.well-known/jmap',
      imapHost: imapHost,
      imapPort: imapPort,
      imapSsl: false,
      smtpHost: imapHost,
      smtpPort: int.parse(smtpPort),
    );
    cacheDir = Directory.systemTemp.createTempSync('repo_jmap_test_');
  });

  tearDownAll(() => cacheDir.deleteSync(recursive: true));

  setUp(() async {
    final client = await _imapConnect(
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

  ({
    AppDatabase db,
    AccountRepositoryImpl accounts,
    EmailRepositoryImpl emails,
    MailboxRepositoryImpl mailboxes,
  }) makeRepo() {
    final db = openTestDatabase();
    final accounts = AccountRepositoryImpl(db, MapSecureStorage());
    final httpClient = LocalhostMappingClient();
    final emails = EmailRepositoryImpl(
      db,
      accounts,
      getCacheDir: () async => cacheDir,
      httpClient: httpClient,
    );
    final mailboxes =
        MailboxRepositoryImpl(db, accounts, httpClient: httpClient);
    return (db: db, accounts: accounts, emails: emails, mailboxes: mailboxes);
  }

  // Syncs mailboxes and returns the JMAP ID for the INBOX mailbox.
  Future<String> setupAndGetInboxId(
    AppDatabase db,
    AccountRepositoryImpl accounts,
    MailboxRepositoryImpl mailboxes,
  ) async {
    await accounts.addAccount(account, userPass);
    await mailboxes.syncMailboxes('test-jmap');
    final row = await (db.select(db.mailboxes)
          ..where(
            (t) => t.accountId.equals('test-jmap') & t.role.equals('inbox'),
          )
          ..limit(1))
        .getSingleOrNull();
    if (row == null) throw StateError('INBOX not found after syncMailboxes');
    return row.path;
  }

  Future<void> appendToInbox(String subject, {String body = 'Body'}) async {
    final client = await _imapConnect(
      host: imapHost,
      port: imapPort,
      user: userEmail,
      pass: userPass,
    );
    try {
      final msg = MessageBuilder()
        ..from = [MailAddress('Alice', userEmail)]
        ..to = [MailAddress('Alice', userEmail)]
        ..subject = subject
        ..text = body;
      await client.appendMessage(
        msg.buildMimeMessage(),
        targetMailboxPath: 'INBOX',
      );
    } finally {
      await client.logout();
    }
  }

  test('syncEmails full sync fetches messages and stores in DB', () async {
    final subject = 'jmap-full-${DateTime.now().millisecondsSinceEpoch}';
    await appendToInbox(subject);

    final r = makeRepo();
    final inboxId = await setupAndGetInboxId(r.db, r.accounts, r.mailboxes);
    await r.emails.syncEmails('test-jmap', inboxId);

    final emails = await r.emails.observeEmails('test-jmap', inboxId).first;
    expect(emails, hasLength(1));
    expect(emails.first.subject, subject);
    expect(emails.first.isSeen, isFalse);
  });

  test(
    'syncEmails saves state and incremental sync picks up new messages',
    () async {
      final r = makeRepo();
      final inboxId = await setupAndGetInboxId(r.db, r.accounts, r.mailboxes);

      await appendToInbox('first');
      await r.emails.syncEmails('test-jmap', inboxId);
      expect(
        await r.emails.observeEmails('test-jmap', inboxId).first,
        hasLength(1),
      );

      await appendToInbox('second');
      await r.emails.syncEmails('test-jmap', inboxId);
      final emails = await r.emails.observeEmails('test-jmap', inboxId).first;
      expect(emails, hasLength(2));
      expect(emails.map((e) => e.subject).toSet(), {'first', 'second'});
    },
  );

  test('syncEmails removes email deleted on server from local DB', () async {
    await appendToInbox('keep');
    await appendToInbox('delete-me');

    final r = makeRepo();
    final inboxId = await setupAndGetInboxId(r.db, r.accounts, r.mailboxes);
    await r.emails.syncEmails('test-jmap', inboxId);
    expect(
      await r.emails.observeEmails('test-jmap', inboxId).first,
      hasLength(2),
    );

    // Delete via IMAP directly on the server.
    final imap = await _imapConnect(
      host: imapHost,
      port: imapPort,
      user: userEmail,
      pass: userPass,
    );
    try {
      await imap.selectMailboxByPath('INBOX');
      final search = await imap.uidSearchMessages(
        searchCriteria: 'SUBJECT "delete-me"',
      );
      final uids = search.matchingSequence?.toList() ?? [];
      final seq = MessageSequence.fromIds(uids, isUid: true);
      await imap.uidMarkDeleted(seq);
      await imap.uidExpunge(seq);
    } finally {
      await imap.logout();
    }

    await r.emails.syncEmails('test-jmap', inboxId);
    final remaining = await r.emails.observeEmails('test-jmap', inboxId).first;
    expect(remaining, hasLength(1));
    expect(remaining.first.subject, 'keep');
  });

  test('getEmailBody fetches and caches body via JMAP', () async {
    await appendToInbox('body-test', body: 'Hello from JMAP integration');

    final r = makeRepo();
    final inboxId = await setupAndGetInboxId(r.db, r.accounts, r.mailboxes);
    await r.emails.syncEmails('test-jmap', inboxId);

    final emails = await r.emails.observeEmails('test-jmap', inboxId).first;
    final emailId = emails.first.id;

    final body = await r.emails.getEmailBody(emailId);
    expect(body.textBody, contains('Hello from JMAP integration'));

    // Second call should hit the cache (no network error = cache used).
    final cached = await r.emails.getEmailBody(emailId);
    expect(cached.textBody, body.textBody);
  });

  test('getEmailBody(forceRefresh: true) bypasses cache via JMAP', () async {
    await appendToInbox('force-refresh', body: 'Force refresh body');

    final r = makeRepo();
    final inboxId = await setupAndGetInboxId(r.db, r.accounts, r.mailboxes);
    await r.emails.syncEmails('test-jmap', inboxId);

    final emails = await r.emails.observeEmails('test-jmap', inboxId).first;
    final emailId = emails.first.id;

    // Warm the cache, then artificially rewind `cachedAt` so a refresh
    // is observable via a strictly-newer timestamp on the second fetch.
    await r.emails.getEmailBody(emailId);
    final stale = DateTime.now().subtract(const Duration(hours: 1));
    await (r.db.update(r.db.emailBodies)
          ..where((t) => t.emailId.equals(emailId)))
        .write(EmailBodiesCompanion(cachedAt: Value(stale)));

    final refreshed = await r.emails.getEmailBody(emailId, forceRefresh: true);
    expect(refreshed.textBody, contains('Force refresh body'));

    final row = await (r.db.select(r.db.emailBodies)
          ..where((t) => t.emailId.equals(emailId)))
        .getSingle();
    expect(row.cachedAt!.isAfter(stale), isTrue);
  });

  test(
    'getEmailBody self-heals when cached row has null mimeTreeJson (JMAP)',
    () async {
      await appendToInbox('self-heal', body: 'Self-heal body');

      final r = makeRepo();
      final inboxId = await setupAndGetInboxId(r.db, r.accounts, r.mailboxes);
      await r.emails.syncEmails('test-jmap', inboxId);

      final emails = await r.emails.observeEmails('test-jmap', inboxId).first;
      final emailId = emails.first.id;

      // Simulate a row written by an older app version: textBody only, no
      // bodyStructure or headers, and the timestamp well within TTL.
      await r.db.into(r.db.emailBodies).insertOnConflictUpdate(
            EmailBodiesCompanion.insert(
              emailId: emailId,
              textBody: const Value('legacy text'),
              attachmentsJson: const Value('[]'),
              cachedAt: Value(DateTime.now()),
              // headersJson and mimeTreeJson deliberately left absent.
            ),
          );
      var row = await (r.db.select(r.db.emailBodies)
            ..where((t) => t.emailId.equals(emailId)))
          .getSingle();
      expect(row.mimeTreeJson, isNull);
      expect(row.headersJson, isNull);

      // A normal (non-forced) read should trigger a network fetch because
      // the cached row lacks mimeTreeJson, and persist the refreshed data.
      await r.emails.getEmailBody(emailId);

      row = await (r.db.select(r.db.emailBodies)
            ..where((t) => t.emailId.equals(emailId)))
          .getSingle();
      expect(row.mimeTreeJson, isNotNull);
      expect(row.headersJson, isNotNull);
    },
  );

  test(
    'sendEmail submits via JMAP EmailSubmission and creates Sent copy',
    () async {
      final subject = 'jmap-send-${DateTime.now().millisecondsSinceEpoch}';
      final r = makeRepo();
      await r.accounts.addAccount(account, userPass);
      await r.mailboxes.syncMailboxes('test-jmap');

      await r.emails.sendEmail(
        'test-jmap',
        EmailDraft(
          from: EmailAddress(name: 'Alice', email: userEmail),
          to: [EmailAddress(name: 'Alice', email: userEmail)],
          cc: [],
          subject: subject,
          body: 'Integration test message via JMAP',
        ),
      );

      // A sent copy should appear in the Sent mailbox.
      final sentRow = await (r.db.select(r.db.mailboxes)
            ..where(
              (t) => t.accountId.equals('test-jmap') & t.role.equals('sent'),
            )
            ..limit(1))
          .getSingleOrNull();
      final sentId = sentRow?.path;

      if (sentId != null) {
        await r.emails.syncEmails('test-jmap', sentId);
        final sentEmails =
            await r.emails.observeEmails('test-jmap', sentId).first;
        expect(sentEmails.any((e) => e.subject == subject), isTrue);
      } else {
        // If no Sent mailbox exists, just verify sendEmail didn't throw.
      }
    },
  );

  test('flushPendingChanges marks email as seen on server', () async {
    await appendToInbox('flag-test');

    final r = makeRepo();
    final inboxId = await setupAndGetInboxId(r.db, r.accounts, r.mailboxes);
    await r.emails.syncEmails('test-jmap', inboxId);

    final emails = await r.emails.observeEmails('test-jmap', inboxId).first;
    await r.emails.setFlag(emails.first.id, seen: true);
    await r.emails.flushPendingChanges('test-jmap', userPass);

    final client = await _imapConnect(
      host: imapHost,
      port: imapPort,
      user: userEmail,
      pass: userPass,
    );
    try {
      await client.selectMailboxByPath('INBOX');
      final seen = await client.uidSearchMessages(searchCriteria: 'SEEN');
      expect(seen.matchingSequence?.toList() ?? [], isNotEmpty);
    } finally {
      await client.logout();
    }
  });

  test('flushPendingChanges deletes email from server', () async {
    await appendToInbox('delete-test');

    final r = makeRepo();
    final inboxId = await setupAndGetInboxId(r.db, r.accounts, r.mailboxes);
    await r.emails.syncEmails('test-jmap', inboxId);

    final emails = await r.emails.observeEmails('test-jmap', inboxId).first;
    await r.emails.deleteEmail(emails.first.id);
    await r.emails.flushPendingChanges('test-jmap', userPass);

    final client = await _imapConnect(
      host: imapHost,
      port: imapPort,
      user: userEmail,
      pass: userPass,
    );
    try {
      final inbox = await client.selectMailboxByPath('INBOX');
      expect(inbox.messagesExists, 0);
    } finally {
      await client.logout();
    }
  });

  test('flushPendingChanges moves email to Trash on server', () async {
    await appendToInbox('move-test');

    final r = makeRepo();
    final inboxId = await setupAndGetInboxId(r.db, r.accounts, r.mailboxes);
    await r.emails.syncEmails('test-jmap', inboxId);

    // Find a destination mailbox (Trash).
    final trashRow = await (r.db.select(r.db.mailboxes)
          ..where(
            (t) => t.accountId.equals('test-jmap') & t.role.equals('trash'),
          )
          ..limit(1))
        .getSingleOrNull();
    if (trashRow == null) {
      markTestSkipped('No trash mailbox found on this Stalwart instance');
      return;
    }
    final trashId = trashRow.path;

    final emails = await r.emails.observeEmails('test-jmap', inboxId).first;
    await r.emails.moveEmail(emails.first.id, trashId);
    await r.emails.flushPendingChanges('test-jmap', userPass);

    // Re-sync both mailboxes to see updated state.
    await r.emails.syncEmails('test-jmap', inboxId);
    final inboxAfter = await r.emails.observeEmails('test-jmap', inboxId).first;
    expect(inboxAfter, isEmpty);

    await r.emails.syncEmails('test-jmap', trashId);
    final trashAfter = await r.emails.observeEmails('test-jmap', trashId).first;
    expect(trashAfter, isNotEmpty);
  });
}
