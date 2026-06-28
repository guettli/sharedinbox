// Integration test: writing mails and sending must work offline (JMAP).
// Closes #184.
//
// Run via: stalwart-dev/test.sh
//
// Environment variables (set by the runner script):
//   STALWART_URL       — JMAP base URL, e.g. http://127.0.0.1:8080
//   STALWART_IMAP_HOST, STALWART_IMAP_PORT
//   STALWART_USER_B / STALWART_PASS_B  (alice@example.com)

import 'dart:io';

import 'package:enough_mail/enough_mail.dart';
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

String _env(String key, [String fallback = '']) =>
    Platform.environment[key] ?? fallback;

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
      id: 'jmap-offline',
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
    cacheDir = Directory.systemTemp.createTempSync('outbox_jmap_test_');
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

      await accounts.addAccount(account, userPass);
      // Bootstrap mailboxes so the JMAP send code can find the Sent mailbox id.
      await mailboxes.syncMailboxes(account.id);

      // ── 1. Go offline and enqueue ────────────────────────────────────────
      network.online = false;
      final subject = 'offline-jmap-${DateTime.now().millisecondsSinceEpoch}';
      final draft = EmailDraft(
        from: EmailAddress(name: 'Alice', email: userEmail),
        to: [EmailAddress(email: userEmail)],
        cc: const [],
        subject: subject,
        body: 'Queued while offline.',
      );

      final outboxId = await emails.enqueueSend(account.id, draft);
      expect(outboxId, isNonZero);

      final queued = await db.select(db.outbox).get();
      expect(queued, hasLength(1));

      // ── 2. Flushing while offline must record an error, not deliver ──────
      var flushed = await emails.flushOutbox(account.id, userPass);
      expect(flushed, 0);
      final afterFailedFlush = await db.select(db.outbox).get();
      expect(afterFailedFlush, hasLength(1));
      expect(afterFailedFlush.first.attempts, greaterThanOrEqualTo(1));
      expect(afterFailedFlush.first.lastError, isNotNull);

      // Server confirms nothing arrived.
      final probe = await _imapConnect(
        host: imapHost,
        port: imapPort,
        user: userEmail,
        pass: userPass,
      );
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
      flushed = await emails.flushOutbox(account.id, userPass);
      expect(flushed, 1);

      final afterFlush = await db.select(db.outbox).get();
      expect(afterFlush, isEmpty);

      // ── 4. Message landed in INBOX via JMAP EmailSubmission/set ──────────
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      var found = false;
      while (!found && DateTime.now().isBefore(deadline)) {
        final c = await _imapConnect(
          host: imapHost,
          port: imapPort,
          user: userEmail,
          pass: userPass,
        );
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
