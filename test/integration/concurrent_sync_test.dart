// Integration test — requires a running Stalwart instance.
// Run via: stalwart-dev/test.sh  (sets the env vars below)
//
// Concurrently syncs via IMAP (alice) and JMAP (bob), sends emails in both
// directions, and verifies the in-memory Drift DB cache is consistent.
//
// Env vars:
//   STALWART_URL           — JMAP base URL (e.g. http://127.0.0.1:8080)
//   STALWART_IMAP_HOST     — IMAP hostname (default 127.0.0.1)
//   STALWART_IMAP_PORT     — IMAP port
//   STALWART_SMTP_PORT     — SMTP port
//   STALWART_USER_B / STALWART_PASS_B  — alice (IMAP account)
//   STALWART_USER_C / STALWART_PASS_C  — bob   (JMAP account)

import 'dart:io';

import 'package:drift/native.dart';
import 'package:enough_mail/enough_mail.dart' as enough_mail;
import 'package:enough_mail/enough_mail.dart' as mail;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sharedinbox/core/models/account.dart' as model;
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/storage/secure_storage.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

String _env(String key) {
  final v = Platform.environment[key];
  if (v == null || v.isEmpty) throw StateError('$key is not set');
  return v;
}

/// In-memory SecureStorage backed by a plain map — no flutter_secure_storage.
class _MemSecureStorage implements SecureStorage {
  final _map = <String, String>{};

  @override
  Future<String?> read({required String key}) async => _map[key];

  @override
  Future<void> write({required String key, required String? value}) async {
    if (value == null) {
      _map.remove(key);
    } else {
      _map[key] = value;
    }
  }

  @override
  Future<void> delete({required String key}) async => _map.remove(key);
}

/// Plain-text IMAP connect for the local Stalwart dev server (no TLS).
Future<enough_mail.ImapClient> _connectImapPlaintext(
  model.Account account,
  String username,
  String password,
) async {
  final client = enough_mail.ImapClient(
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

Future<void> _sendMessage({
  required String host,
  required int port,
  required String from,
  required String pass,
  required String to,
  required String subject,
}) async {
  final smtp = mail.SmtpClient('sharedinbox-test');
  await smtp.connectToServer(host, port, isSecure: false);
  await smtp.ehlo();
  await smtp.authenticate(from, pass);
  final builder = mail.MessageBuilder()
    ..from = [mail.MailAddress('', from)]
    ..to = [mail.MailAddress('', to)]
    ..subject = subject
    ..text = 'Concurrent sync test body — $subject';
  await smtp.sendMessage(builder.buildMimeMessage());
  await smtp.quit();
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  late String imapHost;
  late int imapPort;
  late int smtpPort;
  late String jmapUrl;
  late String aliceUser, alicePass;
  late String bobUser, bobPass;
  late AppDatabase db;
  late AccountRepository accounts;

  setUpAll(() {
    imapHost = Platform.environment['STALWART_IMAP_HOST'] ?? '127.0.0.1';
    imapPort = int.parse(_env('STALWART_IMAP_PORT'));
    smtpPort = int.parse(_env('STALWART_SMTP_PORT'));
    jmapUrl = _env('STALWART_URL');
    aliceUser = _env('STALWART_USER_B');
    alicePass = _env('STALWART_PASS_B');
    bobUser = _env('STALWART_USER_C');
    bobPass = _env('STALWART_PASS_C');
  });

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    accounts = AccountRepositoryImpl(db, _MemSecureStorage());
  });

  tearDown(() async {
    await db.close();
  });

  test(
    'concurrent IMAP + JMAP sync caches all emails without errors',
    timeout: const Timeout(Duration(seconds: 30)),
    () async {
      final ts = DateTime.now().millisecondsSinceEpoch;
      const msgCount = 2;

      // ── 1. Send emails in both directions ─────────────────────────────────────
      // alice → bob  (alice uses IMAP; bob uses JMAP)
      // bob   → alice (cross-direction)
      for (var i = 0; i < msgCount; i++) {
        await _sendMessage(
          host: imapHost,
          port: smtpPort,
          from: aliceUser,
          pass: alicePass,
          to: bobUser,
          subject: 'alice-to-bob-$ts-$i',
        );
        await _sendMessage(
          host: imapHost,
          port: smtpPort,
          from: bobUser,
          pass: bobPass,
          to: aliceUser,
          subject: 'bob-to-alice-$ts-$i',
        );
      }
      // Give Stalwart a moment to deliver all messages.
      await Future<void>.delayed(const Duration(milliseconds: 800));

      // ── 2. Insert accounts ─────────────────────────────────────────────────────
      final aliceAccount = model.Account(
        id: 'alice',
        displayName: 'Alice',
        email: aliceUser,
        imapHost: imapHost,
        imapPort: imapPort,
        imapSsl: false,
        smtpHost: imapHost,
        smtpPort: smtpPort,
      );
      final bobAccount = model.Account(
        id: 'bob',
        displayName: 'Bob',
        email: bobUser,
        type: model.AccountType.jmap,
        jmapUrl: '$jmapUrl/.well-known/jmap',
        smtpHost: imapHost,
        smtpPort: smtpPort,
      );

      await accounts.addAccount(aliceAccount, alicePass);
      await accounts.addAccount(bobAccount, bobPass);

      final httpClient = http.Client();
      addTearDown(httpClient.close);

      final mailboxRepo = MailboxRepositoryImpl(
        db,
        accounts,
        imapConnect: _connectImapPlaintext,
        httpClient: httpClient,
      );
      final emailRepo = EmailRepositoryImpl(
        db,
        accounts,
        imapConnect: _connectImapPlaintext,
        httpClient: httpClient,
      );

      // ── 3. Sync mailboxes concurrently ─────────────────────────────────────────
      await Future.wait([
        mailboxRepo.syncMailboxes('alice'),
        mailboxRepo.syncMailboxes('bob'),
      ]);

      final allMailboxes = await db.select(db.mailboxes).get();
      expect(
        allMailboxes,
        isNotEmpty,
        reason: 'mailboxes should be cached after sync',
      );

      // Grab INBOX paths for each account.
      // IMAP: path is the mailbox path string (e.g. "INBOX").
      // JMAP: path is the server-assigned JMAP mailbox ID; match by role or name.
      final aliceInbox = allMailboxes
          .firstWhere(
            (m) => m.accountId == 'alice' && m.path.toUpperCase() == 'INBOX',
          )
          .path;
      final bobInbox = allMailboxes
          .firstWhere(
            (m) =>
                m.accountId == 'bob' &&
                (m.role == 'inbox' || m.name.toLowerCase() == 'inbox'),
          )
          .path;

      // ── 4. Sync emails concurrently — run twice to exercise incremental sync ───
      for (var round = 0; round < 2; round++) {
        await Future.wait([
          emailRepo.syncEmails('alice', aliceInbox),
          emailRepo.syncEmails('bob', bobInbox),
        ]);
      }

      // ── 5. Verify DB consistency ───────────────────────────────────────────────
      final allEmails = await db.select(db.emails).get();

      // No duplicate email IDs.
      final ids = allEmails.map((e) => e.id).toList();
      expect(
        ids.toSet().length,
        equals(ids.length),
        reason: 'duplicate email IDs in DB',
      );

      // Alice and bob each received at least msgCount messages.
      final aliceEmails =
          allEmails.where((e) => e.accountId == 'alice').toList();
      final bobEmails = allEmails.where((e) => e.accountId == 'bob').toList();
      expect(
        aliceEmails.length,
        greaterThanOrEqualTo(msgCount),
        reason: "alice's inbox should contain synced emails",
      );
      expect(
        bobEmails.length,
        greaterThanOrEqualTo(msgCount),
        reason: "bob's inbox should contain synced emails",
      );

      // All rows have a non-empty account ID.
      for (final e in allEmails) {
        expect(e.accountId, isNotEmpty);
      }

      // No pending changes left in the queue.
      final pending = await db.select(db.pendingChanges).get();
      expect(pending, isEmpty, reason: 'no outbound mutations expected');
    },
  );
}
