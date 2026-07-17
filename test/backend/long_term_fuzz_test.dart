// Long-running fuzz test against a live Stalwart server: emits progress to
// stdout so a stuck cycle is visible in the test runner output.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:sharedinbox/core/models/account.dart' as model;
import 'package:sharedinbox/core/storage/secure_storage.dart';
import 'package:sharedinbox/core/sync/account_comparison.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';
import 'package:test/test.dart';

import 'localhost_mapping_client.dart';
import 'stalwart_harness.dart';

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

Future<void> _clearMailbox(
  imap.ImapClient client, {
  String mailboxPath = 'INBOX',
}) =>
    clearMailbox(client, mailboxPath: mailboxPath);

Future<void> _syncAllMailboxes(
  AppDatabase db,
  String accountId,
  EmailRepositoryImpl emailRepo,
  MailboxRepositoryImpl mailboxRepo,
) async {
  await mailboxRepo.syncMailboxes(accountId);
  final mboxes = await (db.select(db.mailboxes)
        ..where((t) => t.accountId.equals(accountId)))
      .get();
  for (final m in mboxes) {
    await emailRepo.syncEmails(accountId, m.path);
  }
}

Future<String> _findMailboxPath(
  AppDatabase db,
  String accountId,
  String roleOrDefaultName,
) async {
  final match = await (db.select(db.mailboxes)
        ..where(
          (t) =>
              t.accountId.equals(accountId) &
              (t.role.equals(roleOrDefaultName) |
                  t.name.equals(roleOrDefaultName)),
        )
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
        '  mid: ${diff.messageId}, kind: ${diff.kind}, fields: ${diff.fields}',
      );
    }
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('long term IMAP and JMAP sync fuzzing',
      timeout: const Timeout(Duration(minutes: 5)), () async {
    final env = StalwartEnv.fromPlatform();
    final user = pickPoolUser(env: env);

    print('=== STARTING SYNC FUZZ CYCLE ===');
    print('Connecting as ${user.email} to JMAP: ${env.stalwartUrl}, '
        'IMAP: ${env.imapHost}:${env.imapPort}');

    // 1. Initial cleanup on the server
    final imapClient = await connectImap(env: env, user: user);
    try {
      await _clearMailbox(imapClient);
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
      email: user.email,
      imapHost: env.imapHost,
      imapPort: env.imapPort,
      imapSsl: false,
      smtpHost: env.smtpHost,
      smtpPort: env.smtpPort,
    );
    final jmapAccount = model.Account(
      id: 'compare-jmap',
      displayName: 'Alice (JMAP)',
      email: user.email,
      type: model.AccountType.jmap,
      jmapUrl: '${env.stalwartUrl}/.well-known/jmap',
      imapHost: env.imapHost,
      imapPort: env.imapPort,
      imapSsl: false,
      smtpHost: env.smtpHost,
      smtpPort: env.smtpPort,
    );

    await accounts.addAccount(imapAccount, user.password);
    await accounts.addAccount(jmapAccount, user.password);

    final tempDir = Directory.systemTemp.createTempSync('long_term_fuzz_');
    final httpClient = LocalhostMappingClient();
    final emailRepo = EmailRepositoryImpl(
      db,
      accounts,
      imapConnect: testImapConnect,
      getCacheDir: () async => tempDir,
      httpClient: httpClient,
    );
    final mailboxRepo = MailboxRepositoryImpl(
      db,
      accounts,
      imapConnect: testImapConnect,
      httpClient: httpClient,
    );

    // 3. Do some CRUD operations directly on the Stalwart server via IMAP
    print('Step 3: Appending random messages via IMAP...');
    final imapSender = await connectImap(env: env, user: user);
    try {
      for (int i = 0; i < 5; i++) {
        final ts = DateTime.now().microsecondsSinceEpoch;
        final builder = imap.MessageBuilder()
          ..from = [imap.MailAddress(user.email, user.email)]
          ..to = [imap.MailAddress(user.email, user.email)]
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

    final mboxesA = await (db.select(db.mailboxes)
          ..where((t) => t.accountId.equals(imapAccount.id)))
        .get();
    print('IMAP Mailboxes:');
    for (final m in mboxesA) {
      print('  path: ${m.path}, name: ${m.name}, role: ${m.role}');
    }
    final mboxesB = await (db.select(db.mailboxes)
          ..where((t) => t.accountId.equals(jmapAccount.id)))
        .get();
    print('JMAP Mailboxes:');
    for (final m in mboxesB) {
      print('  path: ${m.path}, name: ${m.name}, role: ${m.role}');
    }

    final emailsA = await (db.select(db.emails)
          ..where((t) => t.accountId.equals(imapAccount.id)))
        .get();
    print('IMAP Emails:');
    for (final e in emailsA) {
      print(
        '  id: ${e.id}, mbox: ${e.mailboxPath}, msgId: ${e.messageId}, subject: ${e.subject}',
      );
    }
    final emailsB = await (db.select(db.emails)
          ..where((t) => t.accountId.equals(jmapAccount.id)))
        .get();
    print('JMAP Emails:');
    for (final e in emailsB) {
      print(
        '  id: ${e.id}, mbox: ${e.mailboxPath}, msgId: ${e.messageId}, subject: ${e.subject}',
      );
    }

    print('Comparing initial state...');
    var result =
        await AccountComparison(db).compare(imapAccount.id, jmapAccount.id);
    _printComparison(result);
    expect(result.isIdentical, isTrue, reason: 'Initial sync mismatch!');

    // 5. CRUD: IMAP mutations
    print('Step 5: Performing local IMAP mutations...');
    final imapEmails = await (db.select(db.emails)
          ..where((t) => t.accountId.equals(imapAccount.id)))
        .get();
    expect(
      imapEmails.length,
      greaterThanOrEqualTo(3),
      reason: 'Expected at least 3 emails for testing IMAP mutations',
    );

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
    await emailRepo.flushPendingChanges(imapAccount.id, user.password);

    // Sync both sides to pull updates
    print('  Syncing after IMAP mutations...');
    await _syncAllMailboxes(db, imapAccount.id, emailRepo, mailboxRepo);
    await _syncAllMailboxes(db, jmapAccount.id, emailRepo, mailboxRepo);

    // Compare
    result =
        await AccountComparison(db).compare(imapAccount.id, jmapAccount.id);
    _printComparison(result);
    expect(
      result.isIdentical,
      isTrue,
      reason: 'Mismatch after IMAP mutations!',
    );

    // 6. CRUD: JMAP mutations
    print('Step 6: Performing local JMAP mutations...');
    final jmapEmails = await (db.select(db.emails)
          ..where((t) => t.accountId.equals(jmapAccount.id)))
        .get();
    expect(
      jmapEmails.length,
      greaterThanOrEqualTo(2),
      reason: 'Expected at least 2 emails remaining for JMAP mutations',
    );

    // Seen flag change (unseen)
    print('  Marking email 1 unread via JMAP...');
    await emailRepo.setFlag(jmapEmails[0].id, seen: false);

    // Flagged flag change (unflagged)
    print('  Unflagging email 2 via JMAP...');
    await emailRepo.setFlag(jmapEmails[1].id, flagged: false);

    // Move to Archive
    print('  Moving email 1 to Archive via JMAP...');
    final jmapArchivePath =
        await _findMailboxPath(db, jmapAccount.id, 'archive');
    await emailRepo.moveEmail(jmapEmails[0].id, jmapArchivePath);

    // Flush JMAP changes to server
    print('  Flushing JMAP mutations to server...');
    await emailRepo.flushPendingChanges(jmapAccount.id, user.password);

    // Sync both sides to pull updates. Stalwart 0.14.x doesn't always bump the
    // IMAP HIGHESTMODSEQ on the same tick the JMAP mutation lands — sync the
    // pair twice so CONDSTORE picks up the change on the second pass.
    print('  Syncing after JMAP mutations...');
    for (var round = 0; round < 2; round++) {
      await _syncAllMailboxes(db, jmapAccount.id, emailRepo, mailboxRepo);
      await _syncAllMailboxes(db, imapAccount.id, emailRepo, mailboxRepo);
    }

    // Compare
    result =
        await AccountComparison(db).compare(imapAccount.id, jmapAccount.id);
    _printComparison(result);
    expect(
      result.isIdentical,
      isTrue,
      reason: 'Mismatch after JMAP mutations!',
    );

    // 7. CRUD: Hard delete from Trash on both sides
    print('Step 7: Hard deleting emails from Trash...');
    // A: Hard delete on JMAP side
    final jmapTrashPath = await _findMailboxPath(db, jmapAccount.id, 'trash');
    final jmapTrashEmails = await (db.select(db.emails)
          ..where(
            (t) =>
                t.accountId.equals(jmapAccount.id) &
                t.mailboxPath.equals(jmapTrashPath),
          ))
        .get();
    if (jmapTrashEmails.isNotEmpty) {
      print('  Hard deleting email via JMAP...');
      await emailRepo.deleteEmail(jmapTrashEmails.first.id);
      await emailRepo.flushPendingChanges(jmapAccount.id, user.password);
    }

    // B: Hard delete on IMAP side
    final imapTrashEmails = await (db.select(db.emails)
          ..where(
            (t) =>
                t.accountId.equals(imapAccount.id) &
                t.mailboxPath.equals(imapTrashPath),
          ))
        .get();
    if (imapTrashEmails.isNotEmpty) {
      print('  Hard deleting email via IMAP...');
      await emailRepo.deleteEmail(imapTrashEmails.first.id);
      await emailRepo.flushPendingChanges(imapAccount.id, user.password);
    }

    // Sync both sides to pull updates
    print('  Syncing after hard deletes...');
    await _syncAllMailboxes(db, imapAccount.id, emailRepo, mailboxRepo);
    await _syncAllMailboxes(db, jmapAccount.id, emailRepo, mailboxRepo);

    // Compare final state
    result =
        await AccountComparison(db).compare(imapAccount.id, jmapAccount.id);
    _printComparison(result);
    expect(result.isIdentical, isTrue, reason: 'Mismatch after hard deletes!');

    tempDir.deleteSync(recursive: true);
    await db.close();
    httpClient.close();
  });
}
