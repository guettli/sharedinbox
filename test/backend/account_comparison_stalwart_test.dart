// Behaviours of a SINGLE Stalwart user connected through TWO accounts at once —
// one IMAP, one JMAP — sharing a single local database. This is exactly what
// happens when the same user is added twice in the app (the real-world Android
// setup). The two sync paths are independent, so these tests guard against them
// drifting out of step.
//
// 1. IMAP and JMAP sync of the same user produce identical local DBs.
// 2/3. Deleting a message in one account propagates to the other: a delete
//      moves the message to Trash on the server, and the next sync of the other
//      account must observe that the message left the INBOX.
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
import 'package:sharedinbox/data/db/database.dart';
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

/// Empties [mailboxPath], swallowing the error if the folder doesn't exist
/// (e.g. Trash hasn't been created yet).
Future<void> _clearMailbox(
  ImapClient client, {
  String mailboxPath = 'INBOX',
}) async {
  try {
    final box = await client.selectMailboxByPath(mailboxPath);
    if (box.messagesExists == 0) return;
    final result = await client.uidSearchMessages(searchCriteria: 'ALL');
    final uids = result.matchingSequence?.toList() ?? [];
    if (uids.isEmpty) return;
    final seq = MessageSequence.fromIds(uids, isUid: true);
    await client.uidMarkDeleted(seq);
    await client.uidExpunge(seq);
  } catch (_) {
    // Mailbox doesn't exist — nothing to clear.
  }
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
      for (final path in const ['INBOX', 'Trash', 'Deleted Items']) {
        await _clearMailbox(client, mailboxPath: path);
      }
    } finally {
      await client.logout();
    }
  });

  // Builds the two-account world shared by every test: one IMAP and one JMAP
  // account for the same Stalwart user, backed by a single in-memory DB so the
  // comparison service sees them side by side.
  Future<
      ({
        AppDatabase db,
        EmailRepositoryImpl emails,
        MailboxRepositoryImpl mailboxes,
        model.Account imap,
        model.Account jmap,
      })> setUpWorld() async {
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

    final db = openTestDatabase();
    addTearDown(db.close);
    final accounts = AccountRepositoryImpl(db, MapSecureStorage());
    await accounts.addAccount(imapAccount, userPass);
    await accounts.addAccount(jmapAccount, userPass);

    final httpClient = LocalhostMappingClient();
    addTearDown(httpClient.close);
    final emails = EmailRepositoryImpl(
      db,
      accounts,
      imapConnect: _imapConnectPlain,
      getCacheDir: () async => cacheDir,
      httpClient: httpClient,
    );
    final mailboxes = MailboxRepositoryImpl(
      db,
      accounts,
      imapConnect: _imapConnectPlain,
      httpClient: httpClient,
    );
    return (
      db: db,
      emails: emails,
      mailboxes: mailboxes,
      imap: imapAccount,
      jmap: jmapAccount,
    );
  }

  // One full sync cycle for an account: flush queued mutations, refresh the
  // mailbox list, then sync the inbox and trash. Mirrors what
  // AccountSyncManager does per loop iteration (trimmed to the folders a delete
  // touches so the test stays fast over fresh IMAP connections).
  Future<void> syncAccount(
    AppDatabase db,
    EmailRepositoryImpl emails,
    MailboxRepositoryImpl mailboxes,
    String accountId,
  ) async {
    await mailboxes.syncMailboxes(accountId);
    await emails.flushPendingChanges(accountId, userPass);
    // syncMailboxes again in case a flush (e.g. move to Trash) created folders.
    await mailboxes.syncMailboxes(accountId);
    final boxes = await (db.select(db.mailboxes)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                (t.role.equals('inbox') | t.role.equals('trash')),
          ))
        .get();
    for (final box in boxes) {
      await emails.syncEmails(accountId, box.path);
    }
  }

  // Counts local email rows for [accountId] whose subject matches, optionally
  // restricted to the mailbox carrying [role] (e.g. 'inbox', 'trash').
  Future<int> countBySubject(
    AppDatabase db,
    String accountId,
    String subject, {
    String? role,
  }) async {
    String? mailboxPath;
    if (role != null) {
      final box = await (db.select(db.mailboxes)
            ..where(
              (t) => t.accountId.equals(accountId) & t.role.equals(role),
            )
            ..limit(1))
          .getSingleOrNull();
      mailboxPath = box?.path;
      if (mailboxPath == null) return 0;
    }
    final rows = await (db.select(db.emails)
          ..where(
            (t) => t.accountId.equals(accountId) & t.subject.equals(subject),
          ))
        .get();
    if (mailboxPath == null) return rows.length;
    return rows.where((r) => r.mailboxPath == mailboxPath).length;
  }

  Future<String> findEmailId(
    AppDatabase db,
    String accountId,
    String subject,
  ) async {
    final row = await (db.select(db.emails)
          ..where(
            (t) => t.accountId.equals(accountId) & t.subject.equals(subject),
          )
          ..limit(1))
        .getSingleOrNull();
    expect(
      row,
      isNotNull,
      reason: 'expected $accountId to have a row for "$subject"',
    );
    return row!.id;
  }

  // Seeds one message into INBOX via a direct IMAP APPEND so both protocols
  // see the same data.
  Future<void> seedInbox(String subject) async {
    final imap = await _imapConnectDirect(
      host: imapHost,
      port: imapPort,
      user: userEmail,
      pass: userPass,
    );
    try {
      await _appendToInbox(imap, subject: subject, userEmail: userEmail);
    } finally {
      await imap.logout();
    }
  }

  test('IMAP and JMAP sync of the same user produce identical local DBs',
      timeout: const Timeout(Duration(seconds: 90)), () async {
    final w = await setUpWorld();

    final ts = DateTime.now().millisecondsSinceEpoch;
    await seedInbox('compare-one-$ts');
    await seedInbox('compare-two-$ts');

    // Sync mailboxes + emails on both sides. JMAP mailbox path is the
    // server's opaque id, so look it up after the mailbox sync.
    await w.mailboxes.syncMailboxes(w.imap.id);
    await w.emails.syncEmails(w.imap.id, 'INBOX');

    await w.mailboxes.syncMailboxes(w.jmap.id);
    final jmapInbox = await (w.db.select(w.db.mailboxes)
          ..where(
            (t) => t.accountId.equals(w.jmap.id) & t.role.equals('inbox'),
          )
          ..limit(1))
        .getSingleOrNull();
    expect(jmapInbox, isNotNull, reason: 'JMAP inbox should be discovered');
    await w.emails.syncEmails(w.jmap.id, jmapInbox!.path);

    final result = await AccountComparison(w.db).compare(w.imap.id, w.jmap.id);

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

  test('delete in IMAP account propagates to the JMAP account',
      timeout: const Timeout(Duration(seconds: 90)), () async {
    final w = await setUpWorld();
    final subject = 'imap-deletes-${DateTime.now().millisecondsSinceEpoch}';
    await seedInbox(subject);

    // Both accounts sync and see the message in their INBOX.
    await syncAccount(w.db, w.emails, w.mailboxes, w.imap.id);
    await syncAccount(w.db, w.emails, w.mailboxes, w.jmap.id);
    expect(
      await countBySubject(w.db, w.imap.id, subject, role: 'inbox'),
      1,
      reason: 'IMAP inbox should have the seeded message',
    );
    expect(
      await countBySubject(w.db, w.jmap.id, subject, role: 'inbox'),
      1,
      reason: 'JMAP inbox should have the seeded message',
    );

    // Delete in the IMAP account, then flush + sync so the server applies it.
    final imapId = await findEmailId(w.db, w.imap.id, subject);
    await w.emails.deleteEmail(imapId);
    await syncAccount(w.db, w.emails, w.mailboxes, w.imap.id);

    // Now sync the JMAP account — it must observe the message left the INBOX.
    await syncAccount(w.db, w.emails, w.mailboxes, w.jmap.id);

    expect(
      await countBySubject(w.db, w.jmap.id, subject, role: 'inbox'),
      0,
      reason: 'JMAP inbox still shows a message deleted via IMAP',
    );
  });

  test('delete in JMAP account propagates to the IMAP account',
      timeout: const Timeout(Duration(seconds: 90)), () async {
    final w = await setUpWorld();
    final subject = 'jmap-deletes-${DateTime.now().millisecondsSinceEpoch}';
    await seedInbox(subject);

    await syncAccount(w.db, w.emails, w.mailboxes, w.imap.id);
    await syncAccount(w.db, w.emails, w.mailboxes, w.jmap.id);
    expect(await countBySubject(w.db, w.imap.id, subject, role: 'inbox'), 1);
    expect(await countBySubject(w.db, w.jmap.id, subject, role: 'inbox'), 1);

    // Delete in the JMAP account, flush + sync.
    final jmapId = await findEmailId(w.db, w.jmap.id, subject);
    await w.emails.deleteEmail(jmapId);
    await syncAccount(w.db, w.emails, w.mailboxes, w.jmap.id);

    // Sync the IMAP account — it must observe the deletion.
    await syncAccount(w.db, w.emails, w.mailboxes, w.imap.id);

    expect(
      await countBySubject(w.db, w.imap.id, subject, role: 'inbox'),
      0,
      reason: 'IMAP inbox still shows a message deleted via JMAP',
    );
  });
}
