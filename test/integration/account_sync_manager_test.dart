// Integration test for AccountSyncManager — requires a running Stalwart instance.
// Run via: stalwart-dev/test.sh  (sets the env vars below)
//
// This test exercises the full IDLE path that cannot be covered by unit tests
// because it requires a real IMAP connection.

import 'dart:async';
import 'dart:io';

import 'package:enough_mail/enough_mail.dart'
    show ImapClient, SmtpClient, MessageBuilder, MailAddress;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';
import 'package:sharedinbox/core/sync/account_sync_manager.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

String _env(String key) {
  final v = Platform.environment[key];
  if (v == null || v.isEmpty) throw StateError('$key not set');
  return v;
}

// Fake repos that do nothing — the sync manager only needs real IMAP for IDLE.
class _FakeAccounts implements AccountRepository {
  final _ctrl = StreamController<List<Account>>.broadcast(sync: true);
  String password = '';

  @override
  Stream<List<Account>> observeAccounts() => _ctrl.stream;

  @override
  Future<Account?> getAccount(String id) async => null;

  @override
  Future<void> addAccount(Account account, String pass) async {}

  @override
  Future<void> updateAccount(Account account, {String? password}) async {}

  @override
  Future<void> removeAccount(String id) async {}

  @override
  Future<String> getPassword(String accountId) async => password;

  void push(List<Account> accounts) => _ctrl.add(accounts);
}

class _FakeMailboxes implements MailboxRepository {
  @override
  Stream<List<Mailbox>> observeMailboxes(String accountId) => Stream.value([]);

  @override
  Future<int> syncMailboxes(String accountId) async => 0;

  @override
  Future<Mailbox?> findMailboxByRole(String accountId, String role) async =>
      null;
}

class _FakeEmails implements EmailRepository {
  @override
  Stream<List<Email>> observeEmails(String a, String m) => Stream.value([]);

  @override
  Stream<List<EmailThread>> observeThreads(String a, String m) =>
      Stream.value([]);

  @override
  Future<Email?> getEmail(String id) async => null;

  @override
  Future<EmailBody> getEmailBody(String id) async =>
      const EmailBody(emailId: '', attachments: []);

  @override
  Future<SyncEmailsResult> syncEmails(String a, String m) async =>
      SyncEmailsResult.zero;

  @override
  Future<void> setFlag(String id, {bool? seen, bool? flagged}) async {}

  @override
  Future<void> moveEmail(String id, String dest) async {}

  @override
  Future<void> deleteEmail(String id) async {}

  @override
  Stream<String> get onChangesQueued => const Stream.empty();

  @override
  Future<int> flushPendingChanges(String accountId, String password) async => 0;

  @override
  Future<void> sendEmail(String a, EmailDraft d) async {}

  @override
  Future<String> downloadAttachment(
    String emailId,
    EmailAttachment attachment,
  ) async =>
      '/tmp/${attachment.filename}';

  @override
  Future<List<Email>> searchEmails(String a, String m, String q) async => [];

  @override
  Future<List<Email>> searchEmailsGlobal(String a, String q) async => [];

  @override
  Future<List<Email>> getEmailsByAddress(String a, String address) async => [];

  @override
  Stream<void> watchJmapPush(String accountId, String password) =>
      const Stream.empty();

  @override
  Stream<List<FailedMutation>> observeFailedMutations(String accountId) =>
      Stream.value([]);

  @override
  Future<void> discardMutation(int id) async {}

  @override
  Future<void> retryMutation(int id) async {}
}

Future<void> _sendMessage({
  required String host,
  required int port,
  required String from,
  required String pass,
  required String to,
  required String subject,
}) async {
  final smtp = SmtpClient('sharedinbox-test');
  await smtp.connectToServer(host, port, isSecure: false);
  await smtp.ehlo();
  await smtp.authenticate(from, pass);
  final builder = MessageBuilder()
    ..from = [MailAddress('', from)]
    ..to = [MailAddress('', to)]
    ..subject = subject
    ..text = 'IDLE wake-up test body';
  await smtp.sendMessage(builder.buildMimeMessage());
  await smtp.quit();
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  late String imapHost;
  late int imapPort;
  late int smtpPort;
  late String user, pass;

  setUpAll(() {
    imapHost = Platform.environment['STALWART_IMAP_HOST'] ?? '127.0.0.1';
    imapPort = int.parse(_env('STALWART_IMAP_PORT'));
    smtpPort = int.parse(_env('STALWART_SMTP_PORT'));
    user = _env('STALWART_USER_B'); // alice
    pass = _env('STALWART_PASS_B');
  });

  test(
    'IDLE connects, wakes on new message, and shuts down cleanly',
    timeout: const Timeout(Duration(seconds: 30)),
    () async {
      final firstIdleConnected = Completer<void>();
      final secondIdleConnected = Completer<void>();
      Object? connectError;

      Future<ImapClient> trackingConnect(
        Account account,
        String username,
        String password,
      ) async {
        try {
          final client = ImapClient(
            defaultResponseTimeout: const Duration(seconds: 20),
          );
          await client.connectToServer(
            account.imapHost,
            account.imapPort,
            isSecure: false,
          );
          await client.login(username, password);
          if (!firstIdleConnected.isCompleted) {
            firstIdleConnected.complete();
          } else if (!secondIdleConnected.isCompleted) {
            secondIdleConnected.complete();
          }
          return client;
        } catch (e) {
          connectError ??= e;
          rethrow;
        }
      }

      final fakeAccounts = _FakeAccounts()..password = pass;
      final account = Account(
        id: 'integration-test',
        displayName: 'Integration Test',
        email: user,
        imapHost: imapHost,
        imapPort: imapPort,
        imapSsl: false,
        smtpHost: imapHost,
        smtpPort: smtpPort,
      );

      final mgr = AccountSyncManager(
        fakeAccounts,
        _FakeMailboxes(),
        _FakeEmails(),
        imapConnect: trackingConnect,
      );
      addTearDown(mgr.dispose);
      mgr.start();
      fakeAccounts.push([account]);

      // 1. IDLE connects
      await firstIdleConnected.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () =>
            fail('IDLE did not connect within 5s; error: $connectError'),
      );
      expect(connectError, isNull, reason: 'IMAP connect should succeed');

      // 2. Wakes on new message — deliver a message and wait for IDLE to
      //    reconnect, which proves the manager woke up and re-entered IDLE.
      await _sendMessage(
        host: imapHost,
        port: smtpPort,
        from: user,
        pass: pass,
        to: user,
        subject: 'wake-idle-${DateTime.now().millisecondsSinceEpoch}',
      );
      await secondIdleConnected.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () =>
            fail('IDLE did not reconnect after new message within 10s'),
      );
      expect(connectError, isNull, reason: 'reconnect should succeed');

      // 3. Shuts down cleanly — dispose() must return quickly without hanging
      //    on the 25-minute IDLE cap.
      mgr.dispose();
      await Future<void>.delayed(const Duration(seconds: 1));
    },
  );
}
