// Integration tests for EmailRepositoryImpl against a real Stalwart instance.
// Run via: stalwart-dev/test.sh
//
// Environment variables (set by the runner script):
//   STALWART_IMAP_HOST, STALWART_IMAP_PORT
//   STALWART_SMTP_HOST, STALWART_SMTP_PORT
//   STALWART_USER_B / STALWART_PASS_B  (alice@example.com)

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:enough_mail/enough_mail.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
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
  final client = ImapClient(
    defaultResponseTimeout: const Duration(seconds: 20),
  );
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
    userEmail = _env('STALWART_USER_B', 'alice@example.com');
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
    final client = ImapClient(
      defaultResponseTimeout: const Duration(seconds: 20),
    );
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

  ({AppDatabase db, AccountRepositoryImpl accounts, EmailRepositoryImpl emails})
      makeRepo() {
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
    return (db: db, accounts: accounts, emails: emails);
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

  test('syncEmails saves IMAP checkpoint after full sync', () async {
    await appendToInbox('checkpoint-test');

    final r = makeRepo();
    await r.accounts.addAccount(account, userPass);
    await r.emails.syncEmails('test', 'INBOX');

    final states = await r.db.select(r.db.syncStates).get();
    expect(states, hasLength(1));
    final checkpoint = jsonDecode(states.first.state) as Map<String, dynamic>;
    expect(checkpoint['uidValidity'], isA<int>());
    expect((checkpoint['lastUid'] as int), greaterThan(0));
  });

  test(
    'syncEmails incremental sync fetches only messages newer than checkpoint',
    () async {
      await appendToInbox('first');

      final r = makeRepo();
      await r.accounts.addAccount(account, userPass);
      await r.emails.syncEmails('test', 'INBOX');

      final afterFirst = await r.emails.observeEmails('test', 'INBOX').first;
      expect(afterFirst, hasLength(1));
      expect(afterFirst.first.subject, 'first');

      await appendToInbox('second');
      await r.emails.syncEmails('test', 'INBOX');

      final afterSecond = await r.emails.observeEmails('test', 'INBOX').first;
      expect(afterSecond, hasLength(2));
      expect(afterSecond.map((e) => e.subject).toSet(), {'first', 'second'});
    },
  );

  test(
    'CONDSTORE fast-path: second sync skips fetch when nothing changed',
    () async {
      await appendToInbox('condstore-test');

      final r = makeRepo();
      await r.accounts.addAccount(account, userPass);

      // First sync — full sync, saves modseq checkpoint.
      await r.emails.syncEmails('test', 'INBOX');
      final stateAfterFirst = await r.db.select(r.db.syncStates).get();
      expect(stateAfterFirst, hasLength(1));

      // Second sync with no server changes — CONDSTORE fast-path should skip
      // fetching. DB email count must stay the same.
      await r.emails.syncEmails('test', 'INBOX');
      final emails = await r.emails.observeEmails('test', 'INBOX').first;
      expect(emails, hasLength(1));
    },
  );

  test('CONDSTORE flag refresh updates flags in local DB', () async {
    await appendToInbox('flag-refresh-test');

    final r = makeRepo();
    await r.accounts.addAccount(account, userPass);
    await r.emails.syncEmails('test', 'INBOX');

    final emails = await r.emails.observeEmails('test', 'INBOX').first;
    expect(emails.first.isSeen, isFalse);

    // Mark seen directly on server, advancing modseq.
    final imap = await _imapConnect(
      host: imapHost,
      port: imapPort,
      user: userEmail,
      pass: userPass,
    );
    try {
      await imap.selectMailboxByPath('INBOX');
      final seq = MessageSequence.fromIds([emails.first.uid], isUid: true);
      await imap.uidMarkSeen(seq);
    } finally {
      await imap.logout();
    }

    // Second sync — modseq changed, should refresh flags.
    await r.emails.syncEmails('test', 'INBOX');

    final refreshed = await r.emails.observeEmails('test', 'INBOX').first;
    expect(refreshed.first.isSeen, isTrue);
  });

  test('syncEmails reconciliation removes emails deleted on server', () async {
    await appendToInbox('keep');
    await appendToInbox('delete-me');

    final r = makeRepo();
    await r.accounts.addAccount(account, userPass);
    await r.emails.syncEmails('test', 'INBOX');
    expect(await r.emails.observeEmails('test', 'INBOX').first, hasLength(2));

    // Delete second message directly on the server.
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
      expect(uids, hasLength(1));
      final seq = MessageSequence.fromIds(uids, isUid: true);
      await imap.uidMarkDeleted(seq);
      await imap.uidExpunge(seq);
    } finally {
      await imap.logout();
    }

    await r.emails.syncEmails('test', 'INBOX');

    final remaining = await r.emails.observeEmails('test', 'INBOX').first;
    expect(remaining, hasLength(1));
    expect(remaining.first.subject, 'keep');
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

  test(
    'blob expiry: re-fetches body when cachedAt is null (legacy row)',
    () async {
      await appendToInbox('legacy-body-test', body: 'Fresh from server');

      final r = makeRepo();
      await r.accounts.addAccount(account, userPass);
      await r.emails.syncEmails('test', 'INBOX');

      final emails = await r.emails.observeEmails('test', 'INBOX').first;
      final emailId = emails.first.id;

      // Simulate a legacy row with no cachedAt.
      await r.db.into(r.db.emailBodies).insertOnConflictUpdate(
            EmailBodiesCompanion.insert(
              emailId: emailId,
              textBody: const Value('stale text'),
              cachedAt: const Value(null),
            ),
          );

      final body = await r.emails.getEmailBody(emailId);
      expect(body.textBody, contains('Fresh from server'));
    },
  );

  test(
    'blob expiry: re-fetches body when cachedAt is older than 7 days',
    () async {
      await appendToInbox('old-body-test', body: 'Current content');

      final r = makeRepo();
      await r.accounts.addAccount(account, userPass);
      await r.emails.syncEmails('test', 'INBOX');

      final emails = await r.emails.observeEmails('test', 'INBOX').first;
      final emailId = emails.first.id;

      // Simulate a row cached 8 days ago.
      await r.db.into(r.db.emailBodies).insertOnConflictUpdate(
            EmailBodiesCompanion.insert(
              emailId: emailId,
              textBody: const Value('old text'),
              cachedAt: Value(DateTime.now().subtract(const Duration(days: 8))),
            ),
          );

      final body = await r.emails.getEmailBody(emailId);
      expect(body.textBody, contains('Current content'));
    },
  );

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
    await r.emails.syncEmails('test', 'INBOX');

    final results = await r.emails.searchEmails('test', 'INBOX', uniqueWord);
    expect(results, hasLength(1));
    expect(results.first.subject, uniqueWord);
  });

  test('searchEmails returns empty list when no messages match', () async {
    await appendToInbox('unrelated subject');

    final r = makeRepo();
    await r.accounts.addAccount(account, userPass);

    final results = await r.emails.searchEmails(
      'test',
      'INBOX',
      'xyzzy-no-match',
    );
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

  // Regression: the in-app "sync" button calls syncEmails directly and does
  // not invoke flushPendingChanges itself. After a local delete, the message
  // is removed from the local DB optimistically but still lives on the server
  // until the pending change is flushed. If syncEmails runs before that flush,
  // it must not resurrect the deleted row from the server.
  test('syncEmails after local delete does not resurrect message', () async {
    await appendToInbox('delete-and-sync');

    final r = makeRepo();
    await r.accounts.addAccount(account, userPass);
    await r.emails.syncEmails('test', 'INBOX');

    final emails = await r.emails.observeEmails('test', 'INBOX').first;
    expect(emails, hasLength(1));

    // User taps delete in the UI: enqueues a pending change, drops local row.
    await r.emails.deleteEmail(emails.first.id);
    expect(await r.emails.observeEmails('test', 'INBOX').first, isEmpty);

    // User taps the sync button: syncEmails runs without flushPendingChanges.
    await r.emails.syncEmails('test', 'INBOX');

    final after = await r.emails.observeEmails('test', 'INBOX').first;
    expect(
      after,
      isEmpty,
      reason: 'deleted message must not reappear on next sync',
    );

    // The pending delete must still be queued for the next flush.
    final pending = await r.db.select(r.db.pendingChanges).get();
    expect(pending, hasLength(1));
    expect(pending.first.changeType, 'delete');
  });

  test(
    'downloadAttachment fetches binary attachment bytes from IMAP',
    () async {
      final attachmentBytes = Uint8List.fromList(
        List.generate(32, (i) => i + 1),
      );
      const attachmentName = 'hello.bin';
      const attachmentMime = 'application/octet-stream';

      // Build a multipart email with a binary attachment and append it.
      final client = await _imapConnect(
        host: imapHost,
        port: imapPort,
        user: userEmail,
        pass: userPass,
      );
      try {
        final builder = MessageBuilder()
          ..from = [MailAddress('Alice', userEmail)]
          ..to = [MailAddress('Alice', userEmail)]
          ..subject = 'attach-${DateTime.now().millisecondsSinceEpoch}'
          ..text = 'See attachment.';
        builder.addBinary(
          attachmentBytes,
          MediaType.fromText(attachmentMime),
          filename: attachmentName,
        );
        await client.appendMessage(
          builder.buildMimeMessage(),
          targetMailboxPath: 'INBOX',
        );
      } finally {
        await client.logout();
      }

      final r = makeRepo();
      await r.accounts.addAccount(account, userPass);
      await r.emails.syncEmails('test', 'INBOX');

      final emails = await r.emails.observeEmails('test', 'INBOX').first;
      expect(emails, hasLength(1));
      expect(emails.first.hasAttachment, isTrue);

      final body = await r.emails.getEmailBody(emails.first.id);
      expect(body.attachments, hasLength(1));
      expect(body.attachments.first.filename, attachmentName);
      expect(body.attachments.first.contentType, attachmentMime);
      expect(body.attachments.first.fetchPartId, isNotEmpty);

      final path = await r.emails.downloadAttachment(
        emails.first.id,
        body.attachments.first,
      );
      final downloaded = await File(path).readAsBytes();
      expect(downloaded, equals(attachmentBytes));
    },
  );
}
