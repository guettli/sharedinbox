import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:http/http.dart' as http;
import 'package:sharedinbox/core/models/account.dart' as model;
import 'package:sharedinbox/core/storage/secure_storage.dart';
import 'package:sharedinbox/core/sync/account_comparison.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';
import 'package:test/test.dart';

import 'localhost_mapping_client.dart';

class MapSecureStorage implements SecureStorage {
  final _map = <String, String>{};

  @override
  Future<void> write({required String key, required String? value}) async {
    if (value == null) {
      _map.remove(key);
    } else {
      _map[key] = value;
    }
  }

  @override
  Future<String?> read({required String key}) async => _map[key];

  @override
  Future<void> delete({required String key}) async {
    _map.remove(key);
  }
}

Future<imap.ImapClient> _imapConnectDirect({
  required String host,
  required int port,
  required String user,
  required String pass,
}) async {
  final client = imap.ImapClient(
    defaultResponseTimeout: const Duration(seconds: 20),
  );
  await client.connectToServer(host, port, isSecure: false);
  await client.login(user, pass);
  return client;
}

Future<imap.ImapClient> _imapConnectPlain(
  model.Account account,
  String username,
  String password,
) async {
  return _imapConnectDirect(
    host: account.imapHost,
    port: account.imapPort,
    user: username,
    pass: password,
  );
}

Future<void> _clearMailbox(
  imap.ImapClient client, {
  String mailboxPath = 'INBOX',
}) async {
  final box = await client.selectMailboxByPath(mailboxPath);
  if (box.messagesExists == 0) return;
  final result = await client.uidSearchMessages(searchCriteria: 'ALL');
  final uids = result.matchingSequence?.toList() ?? [];
  if (uids.isEmpty) return;
  final seq = imap.MessageSequence.fromIds(uids, isUid: true);
  await client.uidMarkDeleted(seq);
  await client.uidExpunge(seq);
}

Future<void> _syncAllMailboxes(
  AppDatabase db,
  String accountId,
  EmailRepositoryImpl emailRepo,
  MailboxRepositoryImpl mailboxRepo,
) async {
  await mailboxRepo.syncMailboxes(accountId);
  final mboxes = await (db.select(db.mailboxes)..where((t) => t.accountId.equals(accountId))).get();
  for (final m in mboxes) {
    await emailRepo.syncEmails(accountId, m.path);
  }
}

Future<String> _findMailboxPath(AppDatabase db, String accountId, String roleOrDefaultName) async {
  final match = await (db.select(db.mailboxes)
        ..where((t) => t.accountId.equals(accountId) & (t.role.equals(roleOrDefaultName) | t.name.equals(roleOrDefaultName)))
        ..limit(1))
      .getSingleOrNull();
  return match?.path ?? roleOrDefaultName;
}

void _printComparison(AccountComparisonResult result) {
  print('Fuzz cycle comparison results:');
  print('  isIdentical: ${result.isIdentical}');
  print('  mailboxes diff count: ${result.mailboxes.length}');
  print('  emails diff count: ${result.emails.length}');
  print('  bodies diff count: ${result.bodies.length}');
  print('  unmatchable count: ${result.unmatchable.length}');

  if (!result.isIdentical) {
    print('=== MAILBOX DIFFS ===');
    for (final diff in result.mailboxes) {
      print('  key: ${diff.key}, kind: ${diff.kind}');
    }
    print('=== EMAIL DIFFS ===');
    for (final diff in result.emails) {
      print(
          '  mid: ${diff.messageId}, kind: ${diff.kind}, fields: ${diff.fields}');
    }
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('long term IMAP and JMAP sync fuzzing',
      timeout: const Timeout(Duration(minutes: 5)), () async {
    final stalwartUrl =
        Platform.environment['STALWART_URL'] ?? 'http://127.0.0.1:8080';
    final imapHost = Platform.environment['STALWART_IMAP_HOST'] ?? '127.0.0.1';
    final imapPort =
        int.parse(Platform.environment['STALWART_IMAP_PORT'] ?? '1430');
    final smtpHost = Platform.environment['STALWART_SMTP_HOST'] ?? '127.0.0.1';
    final smtpPort =
        int.parse(Platform.environment['STALWART_SMTP_PORT'] ?? '1025');
    final userEmail =
        Platform.environment['STALWART_USER_B'] ?? 'alice@example.com';
    final userPass = Platform.environment['STALWART_PASS_B'] ?? 'secret';

    print('=== STARTING SYNC FUZZ CYCLE ===');
    print('Connecting to JMAP: $stalwartUrl, IMAP: $imapHost:$imapPort');

    // 1. Initial cleanup on the server
    final imapClient = await _imapConnectDirect(
      host: imapHost,
      port: imapPort,
      user: userEmail,
      pass: userPass,
    );
    try {
      await _clearMailbox(imapClient, mailboxPath: 'INBOX');
      for (final mbox in ['Trash', 'Archive', 'Sent']) {
        try {
          await imapClient.createMailbox(mbox);
        } catch (_) {}
        try {
          await _clearMailbox(imapClient, mailboxPath: mbox);
        } catch (_) {}
      }
    } finally {
      await imapClient.logout();
    }

    // 2. Setup database and repositories
    final db = AppDatabase(NativeDatabase.memory());
    final secureStorage = MapSecureStorage();
    final accounts = AccountRepositoryImpl(db, secureStorage);

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

    await accounts.addAccount(imapAccount, userPass);
    await accounts.addAccount(jmapAccount, userPass);

    final tempDir = Directory.systemTemp.createTempSync('long_term_fuzz_');
    final httpClient = LocalhostMappingClient();
    final emailRepo = EmailRepositoryImpl(
      db,
      accounts,
      imapConnect: _imapConnectPlain,
      getCacheDir: () async => tempDir,
      httpClient: httpClient,
    );
    final mailboxRepo = MailboxRepositoryImpl(
      db,
      accounts,
      imapConnect: _imapConnectPlain,
      httpClient: httpClient,
    );

    // 3. Do some CRUD operations directly on the Stalwart server via IMAP
    print('Step 3: Appending random messages via IMAP...');
    final imapSender = await _imapConnectDirect(
      host: imapHost,
      port: imapPort,
      user: userEmail,
      pass: userPass,
    );
    try {
      for (int i = 0; i < 5; i++) {
        final ts = DateTime.now().microsecondsSinceEpoch;
        final builder = imap.MessageBuilder()
          ..from = [imap.MailAddress('Sender', userEmail)]
          ..to = [imap.MailAddress('Receiver', userEmail)]
          ..subject = 'Fuzz Message $i - $ts'
          ..text = 'This is fuzz body $i for timestamp $ts';
        await imapSender.appendMessage(
          builder.buildMimeMessage(),
          targetMailboxPath: 'INBOX',
        );
      }
    } finally {
      await imapSender.logout();
    }

    // 4. Initial Sync and Verification
    print('Step 4: Syncing all mailboxes for initial check...');
    await _syncAllMailboxes(db, imapAccount.id, emailRepo, mailboxRepo);
    await _syncAllMailboxes(db, jmapAccount.id, emailRepo, mailboxRepo);

    final mboxesA = await (db.select(db.mailboxes)..where((t) => t.accountId.equals(imapAccount.id))).get();
    print('IMAP Mailboxes:');
    for (final m in mboxesA) {
      print('  path: ${m.path}, name: ${m.name}, role: ${m.role}');
    }
    final mboxesB = await (db.select(db.mailboxes)..where((t) => t.accountId.equals(jmapAccount.id))).get();
    print('JMAP Mailboxes:');
    for (final m in mboxesB) {
      print('  path: ${m.path}, name: ${m.name}, role: ${m.role}');
    }

    final emailsA = await (db.select(db.emails)..where((t) => t.accountId.equals(imapAccount.id))).get();
    print('IMAP Emails:');
    for (final e in emailsA) {
      print('  id: ${e.id}, mbox: ${e.mailboxPath}, msgId: ${e.messageId}, subject: ${e.subject}');
    }
    final emailsB = await (db.select(db.emails)..where((t) => t.accountId.equals(jmapAccount.id))).get();
    print('JMAP Emails:');
    for (final e in emailsB) {
      print('  id: ${e.id}, mbox: ${e.mailboxPath}, msgId: ${e.messageId}, subject: ${e.subject}');
    }

    print('Comparing initial state...');
    var result = await AccountComparison(db).compare(imapAccount.id, jmapAccount.id);
    _printComparison(result);
    expect(result.isIdentical, isTrue, reason: 'Initial sync mismatch!');

    // 5. CRUD: IMAP mutations
    print('Step 5: Performing local IMAP mutations...');
    final imapEmails = await (db.select(db.emails)..where((t) => t.accountId.equals(imapAccount.id))).get();
    expect(imapEmails.length, greaterThanOrEqualTo(3),
        reason: 'Expected at least 3 emails for testing IMAP mutations');

    // Seen flag change
    print('  Marking email 1 read via IMAP...');
    await emailRepo.setFlag(imapEmails[0].id, seen: true);

    // Flagged flag change
    print('  Flagging email 2 via IMAP...');
    await emailRepo.setFlag(imapEmails[1].id, flagged: true);

    // Move to Trash
    print('  Moving email 3 to Trash via IMAP...');
    final imapTrashPath = await _findMailboxPath(db, imapAccount.id, 'trash');
    await emailRepo.moveEmail(imapEmails[2].id, imapTrashPath);

    // Flush IMAP changes to server
    print('  Flushing IMAP mutations to server...');
    await emailRepo.flushPendingChanges(imapAccount.id, userPass);

    // Sync both sides to pull updates
    print('  Syncing after IMAP mutations...');
    await _syncAllMailboxes(db, imapAccount.id, emailRepo, mailboxRepo);
    await _syncAllMailboxes(db, jmapAccount.id, emailRepo, mailboxRepo);

    // Compare
    result = await AccountComparison(db).compare(imapAccount.id, jmapAccount.id);
    _printComparison(result);
    expect(result.isIdentical, isTrue, reason: 'Mismatch after IMAP mutations!');

    // 6. CRUD: JMAP mutations
    print('Step 6: Performing local JMAP mutations...');
    final jmapEmails = await (db.select(db.emails)..where((t) => t.accountId.equals(jmapAccount.id))).get();
    expect(jmapEmails.length, greaterThanOrEqualTo(2),
        reason: 'Expected at least 2 emails remaining for JMAP mutations');

    // Seen flag change (unseen)
    print('  Marking email 1 unread via JMAP...');
    await emailRepo.setFlag(jmapEmails[0].id, seen: false);

    // Flagged flag change (unflagged)
    print('  Unflagging email 2 via JMAP...');
    await emailRepo.setFlag(jmapEmails[1].id, flagged: false);

    // Move to Archive
    print('  Moving email 1 to Archive via JMAP...');
    final jmapArchivePath = await _findMailboxPath(db, jmapAccount.id, 'archive');
    await emailRepo.moveEmail(jmapEmails[0].id, jmapArchivePath);

    // Flush JMAP changes to server
    print('  Flushing JMAP mutations to server...');
    await emailRepo.flushPendingChanges(jmapAccount.id, userPass);

    // Sync both sides to pull updates
    print('  Syncing after JMAP mutations...');
    await _syncAllMailboxes(db, imapAccount.id, emailRepo, mailboxRepo);
    await _syncAllMailboxes(db, jmapAccount.id, emailRepo, mailboxRepo);

    // Compare
    result = await AccountComparison(db).compare(imapAccount.id, jmapAccount.id);
    _printComparison(result);
    expect(result.isIdentical, isTrue, reason: 'Mismatch after JMAP mutations!');

    // 7. CRUD: Hard delete from Trash on both sides
    print('Step 7: Hard deleting emails from Trash...');
    // A: Hard delete on JMAP side
    final jmapTrashPath = await _findMailboxPath(db, jmapAccount.id, 'trash');
    final jmapTrashEmails = await (db.select(db.emails)
          ..where((t) => t.accountId.equals(jmapAccount.id) & t.mailboxPath.equals(jmapTrashPath)))
        .get();
    if (jmapTrashEmails.isNotEmpty) {
      print('  Hard deleting email via JMAP...');
      await emailRepo.deleteEmail(jmapTrashEmails.first.id);
      await emailRepo.flushPendingChanges(jmapAccount.id, userPass);
    }

    // B: Hard delete on IMAP side
    final imapTrashEmails = await (db.select(db.emails)
          ..where((t) => t.accountId.equals(imapAccount.id) & t.mailboxPath.equals(imapTrashPath)))
        .get();
    if (imapTrashEmails.isNotEmpty) {
      print('  Hard deleting email via IMAP...');
      await emailRepo.deleteEmail(imapTrashEmails.first.id);
      await emailRepo.flushPendingChanges(imapAccount.id, userPass);
    }

    // Sync both sides to pull updates
    print('  Syncing after hard deletes...');
    await _syncAllMailboxes(db, imapAccount.id, emailRepo, mailboxRepo);
    await _syncAllMailboxes(db, jmapAccount.id, emailRepo, mailboxRepo);

    // Compare final state
    result = await AccountComparison(db).compare(imapAccount.id, jmapAccount.id);
    _printComparison(result);
    expect(result.isIdentical, isTrue, reason: 'Mismatch after hard deletes!');

    tempDir.deleteSync(recursive: true);
    db.close();
    httpClient.close();
  });
}
