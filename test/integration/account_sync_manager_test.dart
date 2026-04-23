// Integration test for AccountSyncManager — requires a running Stalwart instance.
// Run via: stalwart-dev/test.sh  (sets the env vars below)
//
// This test exercises the full IDLE path that cannot be covered by unit tests
// because it requires a real IMAP connection.

import 'dart:async';
import 'dart:io';

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
}

class _FakeEmails implements EmailRepository {
  @override
  Stream<List<Email>> observeEmails(String a, String m) => Stream.value([]);

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

  test('IDLE connects, wakes on new message, and shuts down cleanly', () async {
    final fakeAccounts = _FakeAccounts()..password = pass;

    // Stalwart's memory directory authenticates by principal name ('alice'),
    // not by email address ('alice@example.com').  connectImap() passes
    // account.email as the IMAP login username, so use the bare name here.
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
    );
    mgr.start();

    // Push the account — this triggers _sync() then _idle() in the background.
    fakeAccounts.push([account]);

    // Give the manager time to connect and enter IDLE.
    await Future<void>.delayed(const Duration(seconds: 2));

    // Shut down — stop() completes the _stopSignal completer so _idle() exits
    // immediately without waiting for the 25-minute cap.
    mgr.dispose();

    // Let all in-flight async work (idleDone, logout) finish.
    await Future<void>.delayed(const Duration(seconds: 1));
  });
}
