// Shared test harness for backend integration tests against real Stalwart.
//
// Each test file runs in its own Dart isolate; `pickUser()` shards across a
// pool of pre-seeded Stalwart users (alice1..alice32 / bob1..bob32 from
// stalwart-dev/config.toml) keyed by pid % [poolSize], so two files running
// concurrently under `flutter test`'s default concurrency operate on
// disjoint mailbox namespaces and never race in INBOX/Trash resets.
//
// Tests that must use the fixed alice@/bob@ identities (dual-account
// comparison, chaos monkey, concurrent-sync) opt into a second sequential
// pass by annotating with `@Tags(['exclusive'])`.
//
// Environment variables read (all with sensible dev defaults):
//   STALWART_URL         — JMAP base URL (e.g. http://127.0.0.1:8080)
//   STALWART_IMAP_HOST, STALWART_IMAP_PORT
//   STALWART_SMTP_HOST, STALWART_SMTP_PORT
//   STALWART_POOL_SIZE   — pool size override (default 32, must match config)

import 'dart:io';

import 'package:enough_mail/enough_mail.dart';
import 'package:sharedinbox/core/models/account.dart';

/// Default size of the user pool defined in stalwart-dev/config.toml.
/// Keep in sync with the number of aliceN/bobN principals seeded there.
const int _defaultPoolSize = 32;

/// A single pre-seeded Stalwart user, materialised as an [Account] template
/// so tests can plug it into whichever [AccountType] they need.
class StalwartTestUser {
  StalwartTestUser({
    required this.email,
    required this.password,
  });

  final String email;
  final String password;

  /// Builds an IMAP-backed [Account] rooted at the given [id].
  Account imapAccount({
    required String id,
    required StalwartEnv env,
  }) =>
      Account(
        id: id,
        displayName: email,
        email: email,
        imapHost: env.imapHost,
        imapPort: env.imapPort,
        imapSsl: false,
        smtpHost: env.smtpHost,
        smtpPort: env.smtpPort,
      );

  /// Builds a JMAP-backed [Account] rooted at the given [id].
  Account jmapAccount({
    required String id,
    required StalwartEnv env,
  }) =>
      Account(
        id: id,
        displayName: email,
        email: email,
        type: AccountType.jmap,
        jmapUrl: '${env.stalwartUrl}/.well-known/jmap',
        imapHost: env.imapHost,
        imapPort: env.imapPort,
        imapSsl: false,
        smtpHost: env.smtpHost,
        smtpPort: env.smtpPort,
      );
}

/// Snapshot of the Stalwart runtime environment: server endpoints resolved
/// from the runner-exported vars (falling back to the localhost dev
/// defaults so tests still run when the vars are missing).
class StalwartEnv {
  StalwartEnv({
    required this.stalwartUrl,
    required this.imapHost,
    required this.imapPort,
    required this.smtpHost,
    required this.smtpPort,
    required this.poolSize,
  });

  final String stalwartUrl;
  final String imapHost;
  final int imapPort;
  final String smtpHost;
  final int smtpPort;
  final int poolSize;

  static StalwartEnv fromPlatform() {
    String read(String key, String fallback) =>
        Platform.environment[key] ?? fallback;
    return StalwartEnv(
      stalwartUrl: read('STALWART_URL', 'http://127.0.0.1:8080'),
      imapHost: read('STALWART_IMAP_HOST', '127.0.0.1'),
      imapPort: int.parse(read('STALWART_IMAP_PORT', '1430')),
      smtpHost: read('STALWART_SMTP_HOST', '127.0.0.1'),
      smtpPort: int.parse(read('STALWART_SMTP_PORT', '1025')),
      poolSize: int.parse(
        read('STALWART_POOL_SIZE', '$_defaultPoolSize'),
      ),
    );
  }
}

/// Picks a sharded pool user for the current Dart isolate.
///
/// Uses `pid % poolSize` so every isolate gets a stable assignment across
/// runs. Two isolates can hash to the same user under high concurrency; in
/// that case they still serialise on the shared Stalwart user rather than
/// racing, which is safe if slower.
///
/// [prefix] picks the `aliceN` or `bobN` family. Pass `pidOverride` from a
/// test to force a specific shard (e.g. for the second account in a dual-
/// account test that needs both an alice and its matching bob).
StalwartTestUser pickPoolUser({
  required StalwartEnv env,
  String prefix = 'alice',
  int? pidOverride,
}) {
  final n = env.poolSize;
  final shard = ((pidOverride ?? pid) % n).abs() + 1;
  return StalwartTestUser(
    email: '$prefix$shard@example.com',
    password: 'secret',
  );
}

/// Plain-text IMAP connect for the local dev Stalwart (no TLS cert).
Future<ImapClient> connectImap({
  required StalwartEnv env,
  required StalwartTestUser user,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final client = ImapClient(defaultResponseTimeout: timeout);
  await client.connectToServer(env.imapHost, env.imapPort, isSecure: false);
  await client.login(user.email, user.password);
  return client;
}

/// Deletes every message in [mailboxPath], swallowing the error if the
/// folder doesn't exist yet (e.g. Trash created lazily on first move).
Future<void> clearMailbox(
  ImapClient client, {
  String mailboxPath = 'INBOX',
}) async {
  try {
    final box = await client.selectMailboxByPath(mailboxPath);
    if (box.messagesExists == 0) return;
    final result = await client.uidSearchMessages(searchCriteria: 'ALL');
    final uids = result.matchingSequence?.toList() ?? const <int>[];
    if (uids.isEmpty) return;
    final seq = MessageSequence.fromIds(uids, isUid: true);
    await client.uidMarkDeleted(seq);
    await client.uidExpunge(seq);
  } catch (_) {
    // Folder absent → nothing to clear.
  }
}

/// Convenience: clears the standard reset targets (INBOX + Trash-ish
/// folders) for the given user via a single IMAP connection.
Future<void> clearStandardMailboxes({
  required StalwartEnv env,
  required StalwartTestUser user,
}) async {
  final client = await connectImap(env: env, user: user);
  try {
    for (final path in const ['INBOX', 'Trash', 'Deleted Items']) {
      await clearMailbox(client, mailboxPath: path);
    }
  } finally {
    await client.logout();
  }
}

/// Appends a plain-text message to [mailboxPath] via IMAP APPEND.
Future<void> appendMessage(
  ImapClient client, {
  required String subject,
  required String userEmail,
  String body = 'Body',
  String mailboxPath = 'INBOX',
}) async {
  final msg = MessageBuilder()
    ..from = [MailAddress(userEmail, userEmail)]
    ..to = [MailAddress(userEmail, userEmail)]
    ..subject = subject
    ..text = body;
  await client.appendMessage(
    msg.buildMimeMessage(),
    targetMailboxPath: mailboxPath,
  );
}

/// Standard plain-text IMAP connect used by repository tests.
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

/// Standard plain-text SMTP connect used by repository tests.
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
