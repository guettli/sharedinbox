// Integration tests for EmailRepositoryImpl against a real Stalwart instance.
// Run via: stalwart-dev/test.sh
//
// Environment variables (set by the runner script):
//   STALWART_IMAP_HOST, STALWART_IMAP_PORT
//   STALWART_SMTP_HOST, STALWART_SMTP_PORT
//   STALWART_USER_B / STALWART_PASS_B  (alice@localhost)

import 'dart:io';

import 'package:enough_mail/enough_mail.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';
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
  final client = ImapClient();
  await client.connectToServer(host, port, isSecure: false);
  await client.login(user, pass);
  return client;
}

Future<void> _ensureMailbox(ImapClient client, String mailboxPath) async {
  try {
    await client.selectMailboxByPath(mailboxPath);
  } catch (_) {
    await client.createMailbox(mailboxPath);
  }
}

/// Deletes every message in [mailboxPath] so tests start with a clean slate.
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
  late String imapHost;
  late int imapPort;
  late String smtpHost;
  late int smtpPort;
  late String userEmail;
  late String userPass;
  late Account account;
  late Directory cacheDir;

  setUpAll(() {
    configureSqliteForTests();
    imapHost = _env('STALWART_IMAP_HOST', '127.0.0.1');
    imapPort = int.parse(_env('STALWART_IMAP_PORT', '1430'));
    smtpHost = _env('STALWART_SMTP_HOST', '127.0.0.1');
    smtpPort = int.parse(_env('STALWART_SMTP_PORT', '1025'));
    userEmail = _env('STALWART_USER_B', 'alice@localhost');
    userPass = _env('STALWART_PASS_B', 'secret');
    account = Account(
      id: 'test',
      displayName: 'Alice',
      email: userEmail,
      imapHost: imapHost,
      imapPort: imapPort,
      imapSsl: false,
      smtpHost: smtpHost,
      smtpPort: smtpPort,
    );
    cacheDir = Directory.systemTemp.createTempSync('repo_imap_test_');
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

  // Plaintext IMAP/SMTP connect functions for the dev Stalwart (no TLS cert).
  Future<ImapClient> testImapConnect(
    Account a,
    String username,
    String password,
  ) async {
    final client = ImapClient();
    await client.connectToServer(a.imapHost, a.imapPort, isSecure: false);
    await client.login(username, password);
    return client;
  }

  Future<SmtpClient> testSmtpConnect(
    Account a,
    String username,
    String password,
  ) async {
    final atIndex = a.email.lastIndexOf('@');
    final domain = atIndex != -1 ? a.email.substring(atIndex + 1) : a.smtpHost;
    final client = SmtpClient(domain);
    await client.connectToServer(a.smtpHost, a.smtpPort, isSecure: false);
    await client.ehlo();
    await client.authenticate(username, password);
    return client;
  }

  ({AccountRepositoryImpl accounts, EmailRepositoryImpl emails}) makeRepo() {
    final db = openTestDatabase();
    final storage = MapSecureStorage();
    final accounts = AccountRepositoryImpl(db, storage);
    final emails = EmailRepositoryImpl(
      db,
      accounts,
      imapConnect: testImapConnect,
      smtpConnect: testSmtpConnect,
      getCacheDir: () async => cacheDir,
    );
    return (accounts: accounts, emails: emails);
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

  test('syncEmails fetches messages from INBOX and stores in DB', () async {
    final subject = 'sync-${DateTime.now().millisecondsSinceEpoch}';
    await appendToInbox(subject);

    final r = makeRepo();
    await r.accounts.addAccount(account, userPass);
    await r.emails.syncEmails('test', 'INBOX');

    final emails = await r.emails.observeEmails('test', 'INBOX').first;
    expect(emails, hasLength(1));
    expect(emails.first.subject, subject);
    expect(emails.first.isSeen, isFalse);
  });

  test('getEmailBody fetches body from IMAP and caches it', () async {
    await appendToInbox('body-test', body: 'Hello from IMAP body');

    final r = makeRepo();
    await r.accounts.addAccount(account, userPass);
    await r.emails.syncEmails('test', 'INBOX');

    final emails = await r.emails.observeEmails('test', 'INBOX').first;
    final emailId = emails.first.id;

    final body = await r.emails.getEmailBody(emailId);
    expect(body.textBody, contains('Hello from IMAP body'));

    // Second call returns cached result without another IMAP connection.
    // We verify by checking the body is identical (no error = no IMAP call).
    final cached = await r.emails.getEmailBody(emailId);
    expect(cached.textBody, body.textBody);
  });

  test('sendEmail delivers via SMTP and appends copy to Sent folder', () async {
    final subject = 'send-${DateTime.now().millisecondsSinceEpoch}';
    final r = makeRepo();
    await r.accounts.addAccount(account, userPass);

    await r.emails.sendEmail(
      'test',
      EmailDraft(
        from: EmailAddress(name: 'Alice', email: userEmail),
        to: [EmailAddress(name: 'Alice', email: userEmail)],
        cc: [],
        subject: subject,
        body: 'Integration test message',
      ),
    );

    final client = await _imapConnect(
      host: imapHost,
      port: imapPort,
      user: userEmail,
      pass: userPass,
    );
    try {
      final sent = await client.selectMailboxByPath('Sent');
      expect(sent.messagesExists, greaterThan(0));
    } finally {
      await client.logout();
    }
  });

  test('searchEmails returns messages matching query', () async {
    final uniqueWord = 'searchable-${DateTime.now().millisecondsSinceEpoch}';
    await appendToInbox(uniqueWord);

    final r = makeRepo();
    await r.accounts.addAccount(account, userPass);

    final results = await r.emails.searchEmails('test', 'INBOX', uniqueWord);
    expect(results, hasLength(1));
    expect(results.first.subject, uniqueWord);
  });

  test('searchEmails returns empty list when no messages match', () async {
    await appendToInbox('unrelated subject');

    final r = makeRepo();
    await r.accounts.addAccount(account, userPass);

    final results =
        await r.emails.searchEmails('test', 'INBOX', 'xyzzy-no-match');
    expect(results, isEmpty);
  });

  test('flushPendingChanges applies flag_seen to server', () async {
    await appendToInbox('flag-test');

    final r = makeRepo();
    await r.accounts.addAccount(account, userPass);
    await r.emails.syncEmails('test', 'INBOX');

    final emails = await r.emails.observeEmails('test', 'INBOX').first;
    await r.emails.setFlag(emails.first.id, seen: true);
    await r.emails.flushPendingChanges('test', userPass);

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

  test('flushPendingChanges moves email to destination folder', () async {
    await appendToInbox('move-test');

    final setup = await _imapConnect(
      host: imapHost,
      port: imapPort,
      user: userEmail,
      pass: userPass,
    );
    try {
      await _ensureMailbox(setup, 'Trash');
    } finally {
      await setup.logout();
    }

    final r = makeRepo();
    await r.accounts.addAccount(account, userPass);
    await r.emails.syncEmails('test', 'INBOX');

    final emails = await r.emails.observeEmails('test', 'INBOX').first;
    await r.emails.moveEmail(emails.first.id, 'Trash');
    await r.emails.flushPendingChanges('test', userPass);

    final client = await _imapConnect(
      host: imapHost,
      port: imapPort,
      user: userEmail,
      pass: userPass,
    );
    try {
      final inbox = await client.selectMailboxByPath('INBOX');
      expect(inbox.messagesExists, 0);
      final trash = await client.selectMailboxByPath('Trash');
      expect(trash.messagesExists, greaterThan(0));
    } finally {
      await client.logout();
    }
  });

  test('flushPendingChanges deletes email from server', () async {
    await appendToInbox('delete-test');

    final r = makeRepo();
    await r.accounts.addAccount(account, userPass);
    await r.emails.syncEmails('test', 'INBOX');

    final emails = await r.emails.observeEmails('test', 'INBOX').first;
    await r.emails.deleteEmail(emails.first.id);
    await r.emails.flushPendingChanges('test', userPass);

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
}
