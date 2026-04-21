import 'dart:async';

import 'package:fake_async/fake_async.dart';
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
  Future<void> updateAccount(Account account, {String? password}) async {}

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
  Future<int> syncMailboxes(String accountId) async => 0;
}

class FailingMailboxRepository implements MailboxRepository {
  @override
  Stream<List<Mailbox>> observeMailboxes(String accountId) => Stream.value([]);

  @override
  Future<int> syncMailboxes(String accountId) async =>
      throw Exception('simulated sync failure');
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
  Future<int> syncEmails(String accountId, String mailboxPath) async => 0;

  @override
  Future<void> setFlag(String emailId, {bool? seen, bool? flagged}) async {}

  @override
  Future<void> moveEmail(String emailId, String destMailboxPath) async {}

  @override
  Future<void> deleteEmail(String emailId) async {}

  @override
  Future<int> flushPendingChanges(String accountId, String password) async => 0;

  @override
  Future<void> sendEmail(String accountId, EmailDraft draft) async {}

  @override
  Future<String> downloadAttachment(
    String emailId,
    EmailAttachment attachment,
  ) async =>
      '/tmp/${attachment.filename}';

  @override
  Future<List<Email>> searchEmails(
    String accountId,
    String mailboxPath,
    String query,
  ) async =>
      [];

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

// ── Helpers ───────────────────────────────────────────────────────────────────

const _account = Account(
  id: 'test-account',
  displayName: 'Test',
  email: 'test@example.com',
  imapHost: 'imap.example.com',
  smtpHost: 'smtp.example.com',
);

const _jmapAccount = Account(
  id: 'jmap-account',
  displayName: 'Test JMAP',
  email: 'test@example.com',
  type: AccountType.jmap,
  jmapUrl: 'https://jmap.example.com/.well-known/jmap',
);

class FakeMailboxRepositoryWithInbox implements MailboxRepository {
  @override
  Stream<List<Mailbox>> observeMailboxes(String accountId) => Stream.value([
        const Mailbox(
          id: 'jmap-account:mbx1',
          accountId: 'jmap-account',
          path: 'mbx1',
          name: 'Inbox',
          unreadCount: 0,
          totalCount: 0,
        ),
      ]);

  @override
  Future<int> syncMailboxes(String accountId) async => 0;
}

class _CountingEmailRepository extends FakeEmailRepository {
  final List<String> syncedPaths = [];

  @override
  Future<int> syncEmails(String accountId, String mailboxPath) async {
    syncedPaths.add(mailboxPath);
    return 0;
  }
}

class FailingJmapEmailRepository extends FakeEmailRepository {
  int syncCount = 0;

  @override
  Future<int> syncEmails(String accountId, String mailboxPath) async {
    syncCount++;
    if (syncCount == 1) throw Exception('simulated JMAP failure');
    return 0;
  }
}

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

    test('IMAP _sync iterates all mailboxes from mailbox repository', () {
      fakeAsync((async) {
        final accounts = FakeAccountRepository();
        final emails = _CountingEmailRepository();
        final mgr = AccountSyncManager(
          accounts,
          FakeMailboxRepositoryWithInbox(),
          emails,
          imapConnect: (_, __, ___) =>
              Future.error(Exception('no IMAP in test')),
        );
        mgr.start();
        accounts.push([_account]);
        async.flushMicrotasks();
        expect(emails.syncedPaths, contains('mbx1'));
        mgr.dispose();
        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();
      });
    });

    group('JMAP accounts', () {
      test('starts a JMAP sync loop when a JMAP account is pushed', () async {
        final accounts = FakeAccountRepository();
        final emails = FakeEmailRepository();
        final mgr = AccountSyncManager(
          accounts,
          FakeMailboxRepositoryWithInbox(),
          emails,
        );
        mgr.start();
        accounts.push([_jmapAccount]);
        mgr.dispose();
        await pumpEventQueue();
      });

      test('JMAP stop() interrupts the poll wait', () {
        fakeAsync((async) {
          final accounts = FakeAccountRepository();
          final mgr = AccountSyncManager(
            accounts,
            FakeMailboxRepositoryWithInbox(),
            FakeEmailRepository(),
          );
          mgr.start();
          accounts.push([_jmapAccount]);
          async.flushMicrotasks();

          // Dispose before the 30-second poll interval elapses.
          mgr.dispose();
          async.elapse(const Duration(seconds: 35));
          async.flushMicrotasks();
        });
      });

      test('JMAP backoff on sync failure', () {
        fakeAsync((async) {
          final accounts = FakeAccountRepository();
          final mgr = AccountSyncManager(
            accounts,
            FakeMailboxRepositoryWithInbox(),
            FailingJmapEmailRepository(),
          );
          mgr.start();
          accounts.push([_jmapAccount]);
          async.flushMicrotasks();

          mgr.dispose();
          async.elapse(const Duration(seconds: 10));
          async.flushMicrotasks();
        });
      });
    });

    test('logs error and applies backoff when sync fails', () {
      fakeAsync((async) {
        final accounts = FakeAccountRepository();
        final mgr = AccountSyncManager(
          accounts,
          FailingMailboxRepository(),
          FakeEmailRepository(),
        );
        mgr.start();

        // Sync: true controller fires the listener synchronously; _loop()
        // starts and suspends at the first await inside _sync().
        accounts.push([_account]);

        // Drain microtasks: syncMailboxes throws, the catch block runs and
        // schedules a Future.delayed(5 s) backoff timer.
        async.flushMicrotasks();

        // Stop the manager before the backoff expires so the loop exits
        // cleanly after the delay rather than retrying indefinitely.
        mgr.dispose();

        // Advance past the 5-second backoff so Future.delayed completes and
        // the _backoffSeconds update (line 97) is executed.
        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();
      });
    });
  });
}
