import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';
import 'package:sharedinbox/core/sync/account_sync_manager.dart';

// ── Fakes ─────────────────────────────────────────────────────────────────────

class FakeAccountRepository implements AccountRepository {
  // sync:true so listeners fire immediately inside push() — lets us control
  // the event order in tests without await.
  final _ctrl = StreamController<List<Account>>.broadcast(sync: true);

  @override
  Stream<List<Account>> observeAccounts() => _ctrl.stream;

  @override
  Future<Account?> getAccount(String id) async => null;

  @override
  Future<void> addAccount(Account account, String password) async {}

  @override
  Future<void> removeAccount(String id) async {}

  @override
  Future<String> getPassword(String accountId) async => 'password';

  void push(List<Account> accounts) => _ctrl.add(accounts);

  void close() => _ctrl.close();
}

class FakeMailboxRepository implements MailboxRepository {
  @override
  Stream<List<Mailbox>> observeMailboxes(String accountId) => Stream.value([]);

  @override
  Future<void> syncMailboxes(String accountId) async {}
}

class FakeEmailRepository implements EmailRepository {
  @override
  Stream<List<Email>> observeEmails(String accountId, String mailboxPath) =>
      Stream.value([]);

  @override
  Future<Email?> getEmail(String emailId) async => null;

  @override
  Future<EmailBody> getEmailBody(String emailId) async =>
      const EmailBody(emailId: '', attachments: []);

  @override
  Future<void> syncEmails(String accountId, String mailboxPath) async {}

  @override
  Future<void> setFlag(String emailId, {bool? seen, bool? flagged}) async {}

  @override
  Future<void> moveEmail(String emailId, String destMailboxPath) async {}

  @override
  Future<void> deleteEmail(String emailId) async {}

  @override
  Future<void> sendEmail(String accountId, EmailDraft draft) async {}

  @override
  Future<List<Email>> searchEmails(
    String accountId,
    String mailboxPath,
    String query,
  ) async =>
      [];
}

// ── Helpers ───────────────────────────────────────────────────────────────────

const _account = Account(
  id: 'test-account',
  displayName: 'Test',
  email: 'test@example.com',
  imapHost: 'imap.example.com',
  imapPort: 993,
  imapSsl: true,
  smtpHost: 'smtp.example.com',
  smtpPort: 587,
  smtpSsl: false,
);

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('AccountSyncManager', () {
    test('dispose without start does not throw', () {
      final mgr = AccountSyncManager(
        FakeAccountRepository(),
        FakeMailboxRepository(),
        FakeEmailRepository(),
      );
      expect(mgr.dispose, returnsNormally);
    });

    test('start and immediate dispose (no accounts) does not throw', () {
      final accounts = FakeAccountRepository();
      final mgr = AccountSyncManager(
        accounts,
        FakeMailboxRepository(),
        FakeEmailRepository(),
      );
      mgr.start();
      mgr.dispose();
    });

    test('starts a sync when an account is pushed, then stops on dispose',
        () async {
      final accounts = FakeAccountRepository();
      final mailboxes = FakeMailboxRepository();
      final emails = FakeEmailRepository();

      final mgr = AccountSyncManager(accounts, mailboxes, emails);
      mgr.start();

      // With sync:true controller the listener fires synchronously, creating
      // an _AccountSync and calling start().  The async _loop() then suspends
      // at the first await inside _sync().
      accounts.push([_account]);

      // Calling dispose() here sets _running = false on the sync before the
      // loop reaches _idle(), so _idle() exits early without a network call.
      mgr.dispose();

      // Drain microtasks so the abandoned _loop() future completes cleanly.
      await pumpEventQueue(times: 10);
    });

    test('stops sync for removed account', () async {
      final accounts = FakeAccountRepository();
      final mgr = AccountSyncManager(
        accounts,
        FakeMailboxRepository(),
        FakeEmailRepository(),
      );
      mgr.start();

      accounts.push([_account]);
      // Remove the account — the manager should stop its sync.
      accounts.push([]);

      mgr.dispose();
      await pumpEventQueue(times: 10);
    });
  });
}
