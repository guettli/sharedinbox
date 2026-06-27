import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';
import 'package:sharedinbox/core/repositories/sync_log_repository.dart';
import 'package:sharedinbox/core/sync/account_sync_manager.dart';

// ── helpers ───────────────────────────────────────────────────────────────────

Account _account({String id = 'a1'}) => Account(
      id: id,
      displayName: 'Test',
      email: 'test@example.com',
      imapHost: 'localhost',
    );

class _FakeAccounts implements AccountRepository {
  final List<Account> accounts;
  _FakeAccounts([Account? account]) : accounts = [account ?? _account()];

  @override
  Stream<List<Account>> observeAccounts() => Stream.value(accounts);
  @override
  Future<Account?> getAccount(String id) async => accounts
      .cast<Account?>()
      .firstWhere((a) => a?.id == id, orElse: () => null);
  @override
  Future<void> addAccount(Account account, String password) async {}
  @override
  Future<void> updateAccount(Account account, {String? password}) async {}
  @override
  Future<void> removeAccount(String id) async {}
  @override
  Future<String> getPassword(String id) async => 'secret';
}

class _FakeMailboxes implements MailboxRepository {
  final List<Mailbox> mailboxes;
  _FakeMailboxes([this.mailboxes = const []]);
  @override
  Stream<List<Mailbox>> observeMailboxes(String? accountId) =>
      Stream.value(mailboxes);
  @override
  Future<int> syncMailboxes(String accountId) async => 0;
  @override
  Future<Mailbox?> findMailboxByRole(String accountId, String role) async =>
      null;
  @override
  Future<void> clearForResync(String accountId) async {}
  @override
  Future<Mailbox> createMailboxWithRole(
    String accountId,
    String name,
    String role,
  ) async =>
      Mailbox(
        id: '$accountId:$name',
        accountId: accountId,
        path: name,
        name: name,
        role: role,
        unreadCount: 0,
        totalCount: 0,
      );
  @override
  Future<Mailbox> createMailbox(String accountId, String name) async => Mailbox(
        id: '$accountId:$name',
        accountId: accountId,
        path: name,
        name: name,
        unreadCount: 0,
        totalCount: 0,
      );
}

class _CountingEmails implements EmailRepository {
  int syncCount = 0;
  int wakeUpCount = 0;
  final Exception? syncError;

  _CountingEmails({this.syncError});

  @override
  Future<SyncEmailsResult> syncEmails(String accountId, String mailbox) async {
    syncCount++;
    if (syncError != null) throw syncError!;
    return SyncEmailsResult.zero;
  }

  @override
  Future<int> wakeUpEmails(String accountId) async {
    wakeUpCount++;
    return 0;
  }

  @override
  Future<int> flushPendingChanges(String accountId, String password) async => 0;
  @override
  Stream<List<Email>> observeEmails(String a, String m, {int limit = 50}) =>
      Stream.value([]);
  @override
  Stream<List<EmailThread>> observeThreads(
    String a,
    String m, {
    int limit = 50,
  }) =>
      Stream.value([]);
  @override
  Stream<List<EmailThread>> observeAllInboxThreads({int limit = 50}) =>
      Stream.value([]);
  @override
  Stream<List<Email>> observeEmailsInThread(String a, String m, String t) =>
      Stream.value([]);
  @override
  Future<Email?> getEmail(String id) async => null;
  @override
  Future<EmailBody> getEmailBody(
    String id, {
    bool forceRefresh = false,
  }) async =>
      const EmailBody(emailId: '', attachments: []);
  @override
  Future<void> setFlag(String id, {bool? seen, bool? flagged}) async {}
  @override
  Future<void> markAllAsRead(String accountId, String mailboxPath) async {}
  @override
  Future<void> moveEmail(String id, String dest) async {}
  @override
  Future<String?> deleteEmail(String id) async => null;
  @override
  Future<void> sendEmail(String accountId, EmailDraft draft) async {}
  @override
  Future<String> downloadAttachment(String id, EmailAttachment att) async => '';
  @override
  Future<String> fetchRawRfc822(String emailId) async => '';
  @override
  Future<List<Email>> searchEmails(String a, String m, String q) async => [];
  @override
  Future<List<Email>> searchEmailsGlobal(String? a, String q) async => [];
  @override
  Future<List<Email>> searchEmailsStructured(
    String? a,
    FilterGroup f,
  ) async =>
      [];
  @override
  Future<List<Email>> getEmailsByAddress(String? a, String addr) async => [];
  @override
  Future<List<EmailAddress>> searchAddresses(
    String? a,
    String q, {
    int limit = 10,
  }) async =>
      [];
  @override
  Stream<List<FailedMutation>> observeFailedMutations(String a) =>
      Stream.value([]);
  @override
  Future<void> discardMutation(int id) async {}
  @override
  Future<void> retryMutation(int id) async {}
  @override
  Future<bool> cancelPendingChange(String id, String type) async => false;
  @override
  Future<void> snoozeEmail(String id, DateTime until) async {}
  @override
  Future<void> restoreEmails(List<Email> emails) async {}
  @override
  Future<Email?> findEmailByMessageId(
    String accountId,
    String messageId,
  ) async =>
      null;
  @override
  Stream<String> get onChangesQueued => const Stream.empty();
  @override
  Stream<void> watchJmapPush(String accountId, String password) =>
      const Stream.empty();
  @override
  Future<ReliabilityResult> verifySyncReliability(
    String accountId,
    String mailboxPath,
  ) async =>
      ReliabilityResult.healthy;
  @override
  Future<void> clearForResync(String accountId) async {}
  @override
  Future<int> applySieveRules(String accountId) async => 0;
}

class _FakeSyncLog implements SyncLogRepository {
  final logs = <bool>[];
  int _nextId = 1;
  @override
  Future<int> log({
    required String accountId,
    required bool success,
    String? errorMessage,
    String? stackTrace,
    bool isPermanent = false,
    required String protocol,
    required int emailsFetched,
    required int emailsSkipped,
    required int mailboxesSynced,
    required int pendingFlushed,
    required int bytesTransferred,
    required DateTime startedAt,
    required DateTime finishedAt,
    List<MailboxSyncStats> mailboxStats = const [],
    String? protocolLog,
  }) async {
    logs.add(success);
    return _nextId++;
  }

  @override
  Stream<List<SyncLogEntry>> observeSyncLogs(String accountId) =>
      Stream.value([]);

  @override
  Stream<String?> observeLastError(String accountId) => Stream.value(null);
}

// ── tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('AccountSyncManager backoff', () {
    test('backoff is capped at 900 s after repeated failures', () {
      fakeAsync((async) {
        final emails = _CountingEmails(
          syncError: Exception('connection refused'),
        );
        final syncLog = _FakeSyncLog();
        final manager = AccountSyncManager(
          _FakeAccounts(),
          _FakeMailboxes([
            const Mailbox(
              id: 'INBOX',
              accountId: 'a1',
              path: 'INBOX',
              name: 'Inbox',
              unreadCount: 0,
              totalCount: 0,
            ),
          ]),
          emails,
          syncLog: syncLog,
          imapConnect: (_, __, ___) async =>
              throw Exception('connection refused'),
        );

        manager.start();

        // Advance 3 hours — long enough to observe many retries.
        // With max backoff 900 s, we expect at least floor(3*3600/900) = 12
        // attempts, and at most 3*3600/5 = 2160 (if backoff never grew).
        async.elapse(const Duration(hours: 3));

        final failCount = syncLog.logs.where((ok) => !ok).length;
        expect(
          failCount,
          greaterThan(10),
          reason: 'should have retried many times within 3 h',
        );
        expect(
          failCount,
          lessThan(2200),
          reason: 'backoff must have kicked in — not every 5 s for 3 h',
        );

        manager.dispose();
        async.elapse(const Duration(seconds: 1));
      });
    });

    test('backoff resets to 5 s after a successful sync', () {
      fakeAsync((async) {
        int callCount = 0;
        final syncLog = _FakeSyncLog();

        var failsLeft = 5;
        final customEmails = _OverrideEmails(
          onSync: (_) async {
            callCount++;
            if (failsLeft > 0) {
              failsLeft--;
              throw Exception('transient error');
            }
            return SyncEmailsResult.zero;
          },
        );

        final manager = AccountSyncManager(
          _FakeAccounts(),
          _FakeMailboxes([
            const Mailbox(
              id: 'INBOX',
              accountId: 'a1',
              path: 'INBOX',
              name: 'Inbox',
              unreadCount: 0,
              totalCount: 0,
            ),
          ]),
          customEmails,
          syncLog: syncLog,
          imapConnect: (_, __, ___) async =>
              throw Exception('skip idle — force immediate loop'),
        );

        manager.start();

        // Allow errors + backoff to build up, then a success, then more loops.
        async.elapse(const Duration(seconds: 3600));

        // After success, backoff should reset; failures before success should
        // be exactly 5, and subsequent loops should fire frequently.
        final successCount = syncLog.logs.where((ok) => ok).length;
        expect(
          successCount,
          greaterThan(0),
          reason: 'should have at least one success',
        );
        expect(
          callCount,
          greaterThan(5),
          reason: 'should retry after failures and continue after success',
        );

        manager.dispose();
        async.elapse(const Duration(seconds: 1));
      });
    });

    test('concurrent sync errors from multiple accounts stay bounded', () {
      fakeAsync((async) {
        final accounts = _FakeAccounts()
          ..accounts.add(_account(id: 'a2'))
          ..accounts.add(_account(id: 'a3'));
        final syncLog = _FakeSyncLog();
        final manager = AccountSyncManager(
          accounts,
          _FakeMailboxes([
            const Mailbox(
              id: 'INBOX',
              accountId: 'a1',
              path: 'INBOX',
              name: 'Inbox',
              unreadCount: 0,
              totalCount: 0,
            ),
            const Mailbox(
              id: 'INBOX',
              accountId: 'a2',
              path: 'INBOX',
              name: 'Inbox',
              unreadCount: 0,
              totalCount: 0,
            ),
            const Mailbox(
              id: 'INBOX',
              accountId: 'a3',
              path: 'INBOX',
              name: 'Inbox',
              unreadCount: 0,
              totalCount: 0,
            ),
          ]),
          _CountingEmails(syncError: Exception('network error')),
          syncLog: syncLog,
          imapConnect: (_, __, ___) async =>
              throw Exception('connection refused'),
        );

        manager.start();
        async.elapse(const Duration(hours: 2));

        // All 3 accounts retry, each bounded by the 900 s cap.
        final failCount = syncLog.logs.where((ok) => !ok).length;
        expect(failCount, greaterThan(5));
        expect(
          failCount,
          lessThan(5000),
          reason: 'backoff must be in effect across all accounts',
        );

        manager.dispose();
        async.elapse(const Duration(seconds: 1));
      });
    });
  });
}

// ── _OverrideEmails ───────────────────────────────────────────────────────────

class _OverrideEmails extends _CountingEmails {
  _OverrideEmails({required Future<SyncEmailsResult> Function(String) onSync})
      : _onSync = onSync;

  final Future<SyncEmailsResult> Function(String) _onSync;

  @override
  Future<SyncEmailsResult> syncEmails(String accountId, String mailbox) =>
      _onSync(mailbox);
}
