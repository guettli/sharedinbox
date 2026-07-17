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
import 'stalwart_harness.dart' as harness;

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

/// Delivers a message over SMTP (how real mail arrives) rather than IMAP APPEND.
/// Stalwart 0.14.x notably does not bump HIGHESTMODSEQ on SMTP delivery, so this
/// exercises a different server-state path than IMAP APPEND.
Future<void> _smtpDeliver({
  required String host,
  required int port,
  required String userEmail,
  required String password,
  required String subject,
}) async {
  final smtp = SmtpClient('sharedinbox-test');
  await smtp.connectToServer(host, port, isSecure: false);
  await smtp.ehlo();
  await smtp.authenticate(userEmail, password);
  final builder = MessageBuilder()
    ..from = [MailAddress(userEmail, userEmail)]
    ..to = [MailAddress(userEmail, userEmail)]
    ..subject = subject
    ..text = 'Body of $subject';
  await smtp.sendMessage(builder.buildMimeMessage());
  await smtp.quit();
}

void main() {
  late harness.StalwartEnv env;
  late harness.StalwartTestUser user;
  late Directory cacheDir;

  setUpAll(() {
    configureSqliteForTests();
    env = harness.StalwartEnv.fromPlatform();
    user = harness.pickPoolUser(env: env);
    cacheDir = Directory.systemTemp.createTempSync('compare_stalwart_test_');
  });

  tearDownAll(() => cacheDir.deleteSync(recursive: true));

  setUp(() => harness.clearStandardMailboxes(env: env, user: user));

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

    final db = openTestDatabase();
    addTearDown(db.close);
    final accounts = AccountRepositoryImpl(db, MapSecureStorage());
    await accounts.addAccount(imapAccount, user.password);
    await accounts.addAccount(jmapAccount, user.password);

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

  // One full sync cycle for an account, faithfully mirroring what
  // AccountSyncManager._sync does per loop iteration: flush queued mutations,
  // refresh the mailbox list, then sync EVERY mailbox's emails in order. Syncing
  // all folders (not just inbox+trash) matters for JMAP, whose global
  // Email/changes state is advanced by each per-mailbox sync.
  Future<void> syncAccount(
    AppDatabase db,
    EmailRepositoryImpl emails,
    MailboxRepositoryImpl mailboxes,
    String accountId,
  ) async {
    await mailboxes.syncMailboxes(accountId);
    await emails.flushPendingChanges(accountId, user.password);
    // syncMailboxes again in case a flush (e.g. move to Trash) created folders.
    await mailboxes.syncMailboxes(accountId);
    final boxes = await (db.select(db.mailboxes)
          ..where((t) => t.accountId.equals(accountId)))
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
    final imap = await harness.connectImap(env: env, user: user);
    try {
      await harness.appendMessage(
        imap,
        subject: subject,
        userEmail: user.email,
      );
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

  // The reported real-world case: the mailbox holds several messages and the
  // one deleted is NOT the last remaining message.
  test('deleting one of several messages in IMAP propagates to JMAP',
      timeout: const Timeout(Duration(seconds: 90)), () async {
    final w = await setUpWorld();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final subjects = [for (var i = 0; i < 3; i++) 'imap-multi-$stamp-$i'];
    for (final s in subjects) {
      await seedInbox(s);
    }

    await syncAccount(w.db, w.emails, w.mailboxes, w.imap.id);
    await syncAccount(w.db, w.emails, w.mailboxes, w.jmap.id);
    for (final s in subjects) {
      expect(await countBySubject(w.db, w.jmap.id, s, role: 'inbox'), 1);
    }

    // Delete the MIDDLE message via IMAP.
    final victim = subjects[1];
    await w.emails.deleteEmail(await findEmailId(w.db, w.imap.id, victim));
    await syncAccount(w.db, w.emails, w.mailboxes, w.imap.id);

    await syncAccount(w.db, w.emails, w.mailboxes, w.jmap.id);

    expect(
      await countBySubject(w.db, w.jmap.id, victim, role: 'inbox'),
      0,
      reason: 'JMAP inbox still shows a message deleted via IMAP',
    );
    // The other two must remain.
    expect(
      await countBySubject(w.db, w.jmap.id, subjects[0], role: 'inbox'),
      1,
    );
    expect(
      await countBySubject(w.db, w.jmap.id, subjects[2], role: 'inbox'),
      1,
    );
  });

  test('deleting one of several messages in JMAP propagates to IMAP',
      timeout: const Timeout(Duration(seconds: 90)), () async {
    final w = await setUpWorld();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final subjects = [for (var i = 0; i < 3; i++) 'jmap-multi-$stamp-$i'];
    for (final s in subjects) {
      await seedInbox(s);
    }

    await syncAccount(w.db, w.emails, w.mailboxes, w.imap.id);
    await syncAccount(w.db, w.emails, w.mailboxes, w.jmap.id);
    for (final s in subjects) {
      expect(await countBySubject(w.db, w.imap.id, s, role: 'inbox'), 1);
    }

    // Delete the MIDDLE message via JMAP.
    final victim = subjects[1];
    await w.emails.deleteEmail(await findEmailId(w.db, w.jmap.id, victim));
    await syncAccount(w.db, w.emails, w.mailboxes, w.jmap.id);

    await syncAccount(w.db, w.emails, w.mailboxes, w.imap.id);

    expect(
      await countBySubject(w.db, w.imap.id, victim, role: 'inbox'),
      0,
      reason: 'IMAP inbox still shows a message deleted via JMAP',
    );
    expect(
      await countBySubject(w.db, w.imap.id, subjects[0], role: 'inbox'),
      1,
    );
    expect(
      await countBySubject(w.db, w.imap.id, subjects[2], role: 'inbox'),
      1,
    );
  });

  // The set of subjects currently in [accountId]'s inbox.
  Future<Set<String>> inboxSubjects(AppDatabase db, String accountId) async {
    final box = await (db.select(db.mailboxes)
          ..where(
            (t) => t.accountId.equals(accountId) & t.role.equals('inbox'),
          )
          ..limit(1))
        .getSingleOrNull();
    if (box == null) return {};
    final rows = await (db.select(db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) & t.mailboxPath.equals(box.path),
          ))
        .get();
    return {for (final r in rows) r.subject ?? ''};
  }

  // Repeatedly deleting messages from BOTH accounts (interleaved) must keep the
  // two accounts' inboxes converged — none of the deletes may be lost.
  test('repeated deletes from both accounts keep the inboxes converged',
      timeout: const Timeout(Duration(seconds: 120)), () async {
    final w = await setUpWorld();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final subjects = [for (var i = 0; i < 5; i++) 'conv-$stamp-$i'];
    for (final s in subjects) {
      await seedInbox(s);
    }
    await syncAccount(w.db, w.emails, w.mailboxes, w.imap.id);
    await syncAccount(w.db, w.emails, w.mailboxes, w.jmap.id);

    final remaining = {...subjects};

    // (deleterId, the subject to delete) — alternate accounts, never the last.
    final plan = [
      (w.imap.id, subjects[0]),
      (w.jmap.id, subjects[4]),
      (w.imap.id, subjects[2]),
      (w.jmap.id, subjects[1]),
    ];

    for (final (deleterId, subject) in plan) {
      await w.emails.deleteEmail(await findEmailId(w.db, deleterId, subject));
      // Sync the deleter first (flushes to the server), then the other account.
      // Sync each TWICE so a deletion that resurrects on a later sync round is
      // caught.
      final otherId = deleterId == w.imap.id ? w.jmap.id : w.imap.id;
      for (var round = 0; round < 2; round++) {
        await syncAccount(w.db, w.emails, w.mailboxes, deleterId);
        await syncAccount(w.db, w.emails, w.mailboxes, otherId);
      }

      remaining.remove(subject);
      final imapInbox = await inboxSubjects(w.db, w.imap.id);
      final jmapInbox = await inboxSubjects(w.db, w.jmap.id);
      expect(
        imapInbox,
        equals(remaining),
        reason: 'IMAP inbox diverged after deleting "$subject" via $deleterId',
      );
      expect(
        jmapInbox,
        equals(remaining),
        reason: 'JMAP inbox diverged after deleting "$subject" via $deleterId',
      );
    }
  });

  // Second delete = hard delete: deleting a message that already sits in Trash
  // expunges it (IMAP) / destroys it (JMAP) rather than moving it. The other
  // account must observe it leave Trash.
  test('hard delete (delete from Trash) in IMAP propagates to JMAP',
      timeout: const Timeout(Duration(seconds: 120)), () async {
    final w = await setUpWorld();
    final subject = 'hard-imap-${DateTime.now().millisecondsSinceEpoch}';
    await seedInbox(subject);
    await syncAccount(w.db, w.emails, w.mailboxes, w.imap.id);
    await syncAccount(w.db, w.emails, w.mailboxes, w.jmap.id);

    // First delete: INBOX -> Trash.
    await w.emails.deleteEmail(await findEmailId(w.db, w.imap.id, subject));
    await syncAccount(w.db, w.emails, w.mailboxes, w.imap.id);
    await syncAccount(w.db, w.emails, w.mailboxes, w.jmap.id);
    expect(
      await countBySubject(w.db, w.imap.id, subject, role: 'trash'),
      1,
      reason: 'message should be in IMAP Trash after first delete',
    );
    expect(
      await countBySubject(w.db, w.jmap.id, subject, role: 'trash'),
      1,
      reason: 'message should be in JMAP Trash after first delete',
    );

    // Second delete from Trash: hard delete (expunge).
    await w.emails.deleteEmail(await findEmailId(w.db, w.imap.id, subject));
    await syncAccount(w.db, w.emails, w.mailboxes, w.imap.id);
    await syncAccount(w.db, w.emails, w.mailboxes, w.jmap.id);

    expect(
      await countBySubject(w.db, w.jmap.id, subject),
      0,
      reason: 'JMAP still shows a message hard-deleted via IMAP',
    );
  });

  test('hard delete (delete from Trash) in JMAP propagates to IMAP',
      timeout: const Timeout(Duration(seconds: 120)), () async {
    final w = await setUpWorld();
    final subject = 'hard-jmap-${DateTime.now().millisecondsSinceEpoch}';
    await seedInbox(subject);
    await syncAccount(w.db, w.emails, w.mailboxes, w.imap.id);
    await syncAccount(w.db, w.emails, w.mailboxes, w.jmap.id);

    await w.emails.deleteEmail(await findEmailId(w.db, w.jmap.id, subject));
    await syncAccount(w.db, w.emails, w.mailboxes, w.jmap.id);
    await syncAccount(w.db, w.emails, w.mailboxes, w.imap.id);
    expect(await countBySubject(w.db, w.jmap.id, subject, role: 'trash'), 1);
    expect(await countBySubject(w.db, w.imap.id, subject, role: 'trash'), 1);

    await w.emails.deleteEmail(await findEmailId(w.db, w.jmap.id, subject));
    await syncAccount(w.db, w.emails, w.mailboxes, w.jmap.id);
    await syncAccount(w.db, w.emails, w.mailboxes, w.imap.id);

    expect(
      await countBySubject(w.db, w.imap.id, subject),
      0,
      reason: 'IMAP still shows a message hard-deleted via JMAP',
    );
  });

  // Same as the multi-message case, but delivered over SMTP (the real-world
  // path) instead of IMAP APPEND, to catch any server-state quirk (e.g. the
  // Stalwart HIGHESTMODSEQ behaviour) that only shows with delivered mail.
  test('SMTP-delivered: delete one of several in JMAP propagates to IMAP',
      timeout: const Timeout(Duration(seconds: 120)), () async {
    final w = await setUpWorld();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final subjects = [for (var i = 0; i < 3; i++) 'smtp-$stamp-$i'];
    for (final s in subjects) {
      await _smtpDeliver(
        host: env.smtpHost,
        port: env.smtpPort,
        userEmail: user.email,
        password: user.password,
        subject: s,
      );
    }
    // Let Stalwart finish delivery.
    await Future<void>.delayed(const Duration(milliseconds: 800));

    await syncAccount(w.db, w.emails, w.mailboxes, w.imap.id);
    await syncAccount(w.db, w.emails, w.mailboxes, w.jmap.id);
    for (final s in subjects) {
      expect(
        await countBySubject(w.db, w.imap.id, s, role: 'inbox'),
        1,
        reason: 'IMAP should have SMTP-delivered "$s"',
      );
    }

    final victim = subjects[1];
    await w.emails.deleteEmail(await findEmailId(w.db, w.jmap.id, victim));
    await syncAccount(w.db, w.emails, w.mailboxes, w.jmap.id);
    await syncAccount(w.db, w.emails, w.mailboxes, w.imap.id);

    expect(
      await countBySubject(w.db, w.imap.id, victim, role: 'inbox'),
      0,
      reason: 'IMAP inbox still shows a message deleted via JMAP',
    );
    expect(
      await countBySubject(w.db, w.imap.id, subjects[0], role: 'inbox'),
      1,
    );
    expect(
      await countBySubject(w.db, w.imap.id, subjects[2], role: 'inbox'),
      1,
    );
  });
}
