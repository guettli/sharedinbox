// Integration test: writing mails and sending must work offline (IMAP/SMTP).
// Closes #184.
//
// Run via: stalwart-dev/test.sh
//
// Uses a per-isolate pool user from stalwart_harness.dart.

import 'dart:io';

import 'package:enough_mail/enough_mail.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart' show AppDatabase;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/app_log_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';
import 'package:sharedinbox/data/repositories/outbox_repository_impl.dart';
import 'package:test/test.dart';

import '../unit/account_repository_impl_test.dart' show MapSecureStorage;
import '../unit/db_test_helper.dart';
import 'stalwart_harness.dart';

/// Mutable test-only network gate. Setting [online] to false causes every
/// new IMAP/SMTP connection attempt to throw [SocketException], simulating an
/// offline device without any production-code changes.
class _Network {
  bool online = true;

  /// A connect factory matching production's signature that opens a real IMAP
  /// connection while [online], and throws [SocketException] while offline.
  Future<ImapClient> connectImap(
    Account a,
    String username,
    String password,
  ) async {
    if (!online) {
      throw const SocketException('test: offline');
    }
    final c = ImapClient(
      defaultResponseTimeout: const Duration(seconds: 20),
    );
    await c.connectToServer(a.imapHost, a.imapPort, isSecure: false);
    await c.login(username, password);
    return c;
  }

  /// SMTP counterpart to [connectImap] — real connection while [online],
  /// [SocketException] while offline.
  Future<SmtpClient> connectSmtp(
    Account a,
    String username,
    String password,
  ) async {
    if (!online) {
      throw const SocketException('test: offline');
    }
    final atIndex = a.email.lastIndexOf('@');
    final domain = atIndex != -1 ? a.email.substring(atIndex + 1) : a.smtpHost;
    final c = SmtpClient(domain);
    await c.connectToServer(a.smtpHost, a.smtpPort, isSecure: false);
    await c.ehlo();
    await c.authenticate(username, password);
    return c;
  }
}

/// Builds an [EmailRepositoryImpl] whose IMAP/SMTP connections are gated by
/// [network] — the shared setup for the offline round-trip tests.
EmailRepositoryImpl _gatedEmails(
  AppDatabase db,
  AccountRepositoryImpl accounts,
  _Network network,
  Directory cacheDir,
) =>
    EmailRepositoryImpl(
      db,
      accounts,
      imapConnect: network.connectImap,
      smtpConnect: network.connectSmtp,
      getCacheDir: () async => cacheDir,
      outbox: OutboxRepositoryImpl(db),
    );

void main() {
  late StalwartEnv env;
  late StalwartTestUser user;
  late Account account;
  late Directory cacheDir;

  setUpAll(() {
    configureSqliteForTests();
    env = StalwartEnv.fromPlatform();
    user = pickPoolUser(env: env);
    account = user.imapAccount(id: 'imap-offline', env: env);
    cacheDir = Directory.systemTemp.createTempSync('outbox_imap_test_');
  });

  tearDownAll(() => cacheDir.deleteSync(recursive: true));

  setUp(() async {
    final client = await connectImap(env: env, user: user);
    try {
      await clearMailbox(client);
      await clearMailbox(client, mailboxPath: 'Sent');
    } finally {
      await client.logout();
    }
  });

  test(
    'IMAP: enqueue while offline, then flushOutbox after online — message delivered',
    () async {
      final db = openTestDatabase();
      final storage = MapSecureStorage();
      final accounts = AccountRepositoryImpl(db, storage);
      final network = _Network();

      // Wrap real connect functions in the [_Network] gate. Production code
      // sees the same factory signature; only the test seam toggles offline.
      final emails = _gatedEmails(db, accounts, network, cacheDir);
      await accounts.addAccount(account, user.password);

      // ── 1. Go offline and enqueue ────────────────────────────────────────
      network.online = false;
      final subject = 'offline-imap-${DateTime.now().millisecondsSinceEpoch}';
      final draft = EmailDraft(
        from: EmailAddress(name: user.email, email: user.email),
        to: [EmailAddress(email: user.email)],
        cc: const [],
        subject: subject,
        body: 'Queued while offline.',
      );

      // enqueueSend must NOT touch the network.
      final outboxId = await emails.enqueueSend(account.id, draft);
      expect(outboxId, isNonZero);

      final queued = await db.select(db.outbox).get();
      expect(queued, hasLength(1), reason: 'message should sit in the queue');

      // ── 2. While still offline, flush — message stays queued, attempts++ ─
      var flushed = await emails.flushOutbox(account.id, user.password);
      expect(flushed, 0);
      final afterFailedFlush = await db.select(db.outbox).get();
      expect(afterFailedFlush, hasLength(1));
      expect(afterFailedFlush.first.attempts, greaterThanOrEqualTo(1));
      expect(afterFailedFlush.first.lastError, isNotNull);

      // Independent IMAP probe — server has nothing yet.
      final probe = await connectImap(env: env, user: user);
      try {
        final box = await probe.selectMailboxByPath('INBOX');
        expect(
          box.messagesExists,
          0,
          reason: 'no message should have reached the server while offline',
        );
      } finally {
        await probe.logout();
      }

      // ── 3. Reset backoff (simulate user-driven retry / next sync cycle) ──
      // No-op (backoff active).
      await emails.flushOutbox(account.id, user.password);
      // Clear the backoff so the next call is eligible immediately.
      final outboxRepo = OutboxRepositoryImpl(db);
      await outboxRepo.retry(outboxId);

      // ── 4. Come back online and flush ────────────────────────────────────
      network.online = true;
      flushed = await emails.flushOutbox(account.id, user.password);
      expect(
        flushed,
        1,
        reason: 'outbox should drain when network is restored',
      );

      final afterFlush = await db.select(db.outbox).get();
      expect(
        afterFlush,
        isEmpty,
        reason: 'successfully sent rows must be deleted',
      );

      // ── 5. Verify the message landed in the recipient's INBOX ────────────
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      var found = false;
      while (!found && DateTime.now().isBefore(deadline)) {
        final c = await connectImap(env: env, user: user);
        try {
          await c.selectMailboxByPath('INBOX');
          final result = await c.uidSearchMessages(
            searchCriteria: 'SUBJECT "$subject"',
          );
          final uids = result.matchingSequence?.toList() ?? [];
          if (uids.isNotEmpty) found = true;
        } finally {
          await c.logout();
        }
        if (!found) await Future<void>.delayed(const Duration(seconds: 1));
      }
      expect(
        found,
        isTrue,
        reason: 'message should be delivered to INBOX after coming online',
      );

      // ── 6. And a copy was APPEND-ed to Sent ──────────────────────────────
      final sentProbe = await connectImap(env: env, user: user);
      try {
        await sentProbe.selectMailboxByPath('Sent');
        final result = await sentProbe.uidSearchMessages(
          searchCriteria: 'SUBJECT "$subject"',
        );
        final uids = result.matchingSequence?.toList() ?? [];
        expect(
          uids,
          isNotEmpty,
          reason: 'sent copy should be APPENDed to Sent folder',
        );
      } finally {
        await sentProbe.logout();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'IMAP: a failing Sent-copy APPEND commits the send and never re-sends it',
    () async {
      // Regression for #755: once SMTP has accepted the message it is sent. If
      // saving the copy to the IMAP Sent folder then fails, the send must still
      // count as complete — the row deleted, not rescheduled — so no later
      // retry can deliver the message a second time.
      final db = openTestDatabase();
      final storage = MapSecureStorage();
      final accounts = AccountRepositoryImpl(db, storage);
      final appLog = AppLogRepositoryImpl(db);

      // SMTP is healthy; IMAP always fails to connect, so the Sent-copy APPEND
      // that runs after a successful send throws.
      Future<SmtpClient> healthySmtp(
        Account a,
        String username,
        String password,
      ) async {
        final atIndex = a.email.lastIndexOf('@');
        final domain =
            atIndex != -1 ? a.email.substring(atIndex + 1) : a.smtpHost;
        final c = SmtpClient(domain);
        await c.connectToServer(a.smtpHost, a.smtpPort, isSecure: false);
        await c.ehlo();
        await c.authenticate(username, password);
        return c;
      }

      Future<ImapClient> brokenImap(
        Account a,
        String username,
        String password,
      ) async {
        throw const SocketException('test: IMAP unavailable for Sent copy');
      }

      final emails = EmailRepositoryImpl(
        db,
        accounts,
        imapConnect: brokenImap,
        smtpConnect: healthySmtp,
        getCacheDir: () async => cacheDir,
        outbox: OutboxRepositoryImpl(db),
        appLogger: AppLogger(appLog),
      );
      await accounts.addAccount(account, user.password);

      final subject = 'sentcopy-fail-${DateTime.now().millisecondsSinceEpoch}';
      final draft = EmailDraft(
        from: EmailAddress(name: user.email, email: user.email),
        to: [EmailAddress(email: user.email)],
        cc: const [],
        subject: subject,
        body: 'Sent copy will fail, but the message must go out exactly once.',
      );

      final outboxId = await emails.enqueueSend(account.id, draft);
      expect(outboxId, isNonZero);

      // SMTP send succeeds, IMAP Sent-copy fails — the row must still be
      // deleted (sent), not rescheduled for a retry.
      final flushed = await emails.flushOutbox(account.id, user.password);
      expect(flushed, 1, reason: 'a completed SMTP send must count as sent');
      expect(
        await db.select(db.outbox).get(),
        isEmpty,
        reason: 'the row must be removed, not left for a duplicate retry',
      );

      // The failed Sent copy is reported as a warning, not swallowed silently.
      final logDeadline = DateTime.now().add(const Duration(seconds: 5));
      var logged = false;
      while (DateTime.now().isBefore(logDeadline)) {
        final logs = await (db.select(db.appLogs)
              ..where((t) => t.event.equals('outbox.send.sent_copy_failed')))
            .get();
        if (logs.isNotEmpty) {
          logged = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(
        logged,
        isTrue,
        reason: 'a failed Sent copy should be recorded in the app log',
      );

      // A second flush has nothing to do — proving the message is not re-sent.
      expect(await emails.flushOutbox(account.id, user.password), 0);

      // And the recipient received the message exactly once.
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      var matches = 0;
      while (DateTime.now().isBefore(deadline)) {
        final c = await connectImap(env: env, user: user);
        try {
          await c.selectMailboxByPath('INBOX');
          final result = await c.uidSearchMessages(
            searchCriteria: 'SUBJECT "$subject"',
          );
          matches = result.matchingSequence?.toList().length ?? 0;
        } finally {
          await c.logout();
        }
        if (matches >= 1) break;
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      expect(
        matches,
        1,
        reason: 'the message must be delivered exactly once (no duplicate)',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'IMAP: sendNow reports transientFailed offline and sent once online',
    () async {
      final db = openTestDatabase();
      final storage = MapSecureStorage();
      final accounts = AccountRepositoryImpl(db, storage);
      final network = _Network();

      final emails = _gatedEmails(db, accounts, network, cacheDir);
      await accounts.addAccount(account, user.password);

      final subject = 'sendnow-${DateTime.now().millisecondsSinceEpoch}';
      final draft = EmailDraft(
        from: EmailAddress(name: user.email, email: user.email),
        to: [EmailAddress(email: user.email)],
        cc: const [],
        subject: subject,
        body: 'sendNow outcome test.',
      );
      final rowId = await emails.enqueueSend(account.id, draft);

      // Offline: sendNow reports a transient failure and keeps the row queued.
      network.online = false;
      final offline = await emails.sendNow(account.id, outboxRowId: rowId);
      expect(offline.outcome, SendNowOutcome.transientFailed);
      expect(await db.select(db.outbox).get(), hasLength(1));

      // Online: sendNow reports the concrete success and drains the row.
      network.online = true;
      await OutboxRepositoryImpl(db).retry(rowId); // clear the failed backoff
      final online = await emails.sendNow(account.id, outboxRowId: rowId);
      expect(online.outcome, SendNowOutcome.sent);
      expect(await db.select(db.outbox).get(), isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
