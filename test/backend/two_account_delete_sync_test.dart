// Reproduces the real-world setup of the Android app: a SINGLE Stalwart user
// connected through TWO accounts at once — one IMAP, one JMAP — backed by one
// local database (exactly what happens when the same user is added twice).
//
// The reported bug: deleting a message in one account does not make it
// disappear from the other account. Because both accounts talk to the same
// server user, a delete in account A moves the message to Trash on the server,
// and the next sync of account B must observe that the message left the INBOX.
//
// Run via: stalwart-dev/test.sh test/backend/two_account_delete_sync_test.dart
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
  final client =
      ImapClient(defaultResponseTimeout: const Duration(seconds: 20));
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
  final client =
      ImapClient(defaultResponseTimeout: const Duration(seconds: 20));
  await client.connectToServer(host, port, isSecure: false);
  await client.login(user, pass);
  return client;
}

Future<void> _clearMailboxByPath(ImapClient client, String mailboxPath) async {
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
    // Mailbox doesn't exist yet (e.g. Trash) — nothing to clear.
  }
}

/// Empties the mailboxes a delete test touches so each run starts clean.
Future<void> _clearAllMailboxes(ImapClient client) async {
  await _clearMailboxByPath(client, 'INBOX');
  await _clearMailboxByPath(client, 'Trash');
  await _clearMailboxByPath(client, 'Deleted Items');
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
    cacheDir = Directory.systemTemp.createTempSync('two_account_delete_test_');
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
      await _clearAllMailboxes(client);
    } finally {
      await client.logout();
    }
  });

  // Builds the two-account world: a shared DB with one IMAP and one JMAP
  // account, both pointing at the same Stalwart user.
  Future<
      ({
        AppDatabase db,
        EmailRepositoryImpl emails,
        MailboxRepositoryImpl mailboxes,
        model.Account imap,
        model.Account jmap,
      })> setUpWorld() async {
    final imapAccount = model.Account(
      id: 'imap',
      displayName: 'Alice (IMAP)',
      email: userEmail,
      imapHost: imapHost,
      imapPort: imapPort,
      imapSsl: false,
      smtpHost: smtpHost,
      smtpPort: smtpPort,
    );
    final jmapAccount = model.Account(
      id: 'jmap',
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
  // mailbox list, then sync every mailbox's emails. Mirrors what
  // AccountSyncManager does per loop iteration.
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
    // Sync only the mailboxes relevant to a delete: the inbox the message
    // leaves and the trash it lands in. (Syncing every default folder over
    // fresh IMAP connections is needlessly slow.)
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
            ..where((t) => t.accountId.equals(accountId) & t.role.equals(role))
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

  test('delete in IMAP account propagates to the JMAP account',
      timeout: const Timeout(Duration(seconds: 90)), () async {
    final w = await setUpWorld();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final subject = 'imap-deletes-$ts';

    // Seed one message via IMAP APPEND.
    final seed = await _imapConnectDirect(
      host: imapHost,
      port: imapPort,
      user: userEmail,
      pass: userPass,
    );
    try {
      await _appendToInbox(seed, subject: subject, userEmail: userEmail);
    } finally {
      await seed.logout();
    }

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
      reason: 'BUG: JMAP inbox still shows a message deleted via IMAP',
    );
  });

  test('delete in JMAP account propagates to the IMAP account',
      timeout: const Timeout(Duration(seconds: 90)), () async {
    final w = await setUpWorld();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final subject = 'jmap-deletes-$ts';

    final seed = await _imapConnectDirect(
      host: imapHost,
      port: imapPort,
      user: userEmail,
      pass: userPass,
    );
    try {
      await _appendToInbox(seed, subject: subject, userEmail: userEmail);
    } finally {
      await seed.logout();
    }

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
      reason: 'BUG: IMAP inbox still shows a message deleted via JMAP',
    );
  });
}
