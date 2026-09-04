// Integration test: writing mails and sending must work offline (JMAP).
// Closes #184.
//
// Run via: stalwart-dev/test.sh
//
// Uses a per-isolate pool user from stalwart_harness.dart.

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';
import 'package:sharedinbox/data/repositories/outbox_repository_impl.dart';
import 'package:test/test.dart';

import '../unit/account_repository_impl_test.dart' show MapSecureStorage;
import '../unit/db_test_helper.dart';
import 'localhost_mapping_client.dart';
import 'stalwart_harness.dart';

/// Mutable test-only network gate. Setting [online] to false causes the
/// wrapping http.Client to throw [SocketException] for every JMAP request,
/// simulating an offline device without any production-code changes.
class _Network {
  bool online = true;
}

class _GatedHttpClient extends http.BaseClient {
  _GatedHttpClient(this._network, this._inner);
  final _Network _network;
  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (!_network.online) {
      throw const SocketException('test: offline');
    }
    return _inner.send(request);
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}

void main() {
  late StalwartEnv env;
  late StalwartTestUser user;
  late Account account;
  late Directory cacheDir;

  setUpAll(() {
    configureSqliteForTests();
    env = StalwartEnv.fromPlatform();
    user = pickPoolUser(env: env);
    account = user.jmapAccount(id: 'jmap-offline', env: env);
    // Sending reads the app version via package_info_plus (outbox User-Agent
    // header); prime it with a deterministic value for the package:test suite.
    configurePackageInfoForTests();
    cacheDir = Directory.systemTemp.createTempSync('outbox_jmap_test_');
  });

  tearDownAll(() => cacheDir.deleteSync(recursive: true));

  setUp(() async {
    final client = await connectImap(env: env, user: user);
    try {
      await clearMailbox(client);
    } finally {
      await client.logout();
    }
  });

  test(
    'JMAP: enqueue while offline, then flushOutbox after online — message delivered',
    () async {
      final db = openTestDatabase();
      final accounts = AccountRepositoryImpl(db, MapSecureStorage());
      final network = _Network();
      final innerHttp = LocalhostMappingClient();
      final gatedHttp = _GatedHttpClient(network, innerHttp);

      final emails = EmailRepositoryImpl(
        db,
        accounts,
        getCacheDir: () async => cacheDir,
        httpClient: gatedHttp,
        outbox: OutboxRepositoryImpl(db),
      );
      final mailboxes =
          MailboxRepositoryImpl(db, accounts, httpClient: gatedHttp);

      await accounts.addAccount(account, user.password);
      // Bootstrap mailboxes so the JMAP send code can find the Sent mailbox id.
      await mailboxes.syncMailboxes(account.id);

      // ── 1. Go offline and enqueue ────────────────────────────────────────
      network.online = false;
      final subject = 'offline-jmap-${DateTime.now().millisecondsSinceEpoch}';
      final draft = EmailDraft(
        from: EmailAddress(name: user.email, email: user.email),
        to: [EmailAddress(email: user.email)],
        cc: const [],
        subject: subject,
        body: 'Queued while offline.',
      );

      final outboxId = await emails.enqueueSend(account.id, draft);
      expect(outboxId, isNonZero);

      final queued = await db.select(db.outbox).get();
      expect(queued, hasLength(1));

      // ── 2. Flushing while offline must record an error, not deliver ──────
      var flushed = await emails.flushOutbox(account.id, user.password);
      expect(flushed, 0);
      final afterFailedFlush = await db.select(db.outbox).get();
      expect(afterFailedFlush, hasLength(1));
      expect(afterFailedFlush.first.attempts, greaterThanOrEqualTo(1));
      expect(afterFailedFlush.first.lastError, isNotNull);

      // Server confirms nothing arrived.
      final probe = await connectImap(env: env, user: user);
      try {
        final box = await probe.selectMailboxByPath('INBOX');
        expect(box.messagesExists, 0);
      } finally {
        await probe.logout();
      }

      // ── 3. Come back online, retry, flush ────────────────────────────────
      network.online = true;
      final outboxRepo = OutboxRepositoryImpl(db);
      await outboxRepo.retry(outboxId); // clear backoff window
      flushed = await emails.flushOutbox(account.id, user.password);
      expect(flushed, 1);

      final afterFlush = await db.select(db.outbox).get();
      expect(afterFlush, isEmpty);

      // ── 4. Message landed in INBOX via JMAP EmailSubmission/set ──────────
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
        reason: 'JMAP-sent message should arrive after coming online',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
