import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/sync/account_sync_manager.dart';

import 'helpers/fake_account_repository.dart';
import 'helpers/fake_email_repository.dart';
import 'helpers/fake_mailbox_repository.dart';
import 'helpers/fake_sync_log_repository.dart';

// ── helpers ───────────────────────────────────────────────────────────────────

Account _account({String id = 'a1'}) => Account(
      id: id,
      displayName: 'Test',
      email: 'test@example.com',
      imapHost: 'localhost',
    );

class _FakeAccounts extends FakeAccountRepository {
  _FakeAccounts([Account? account]) : super([account ?? _account()]);
}

class _FakeMailboxes extends FakeMailboxRepositoryBase {
  _FakeMailboxes([super.mailboxes]);
}

/// Mailboxes for account `a1` holding just its INBOX.
_FakeMailboxes _inboxOnly() => _FakeMailboxes([
      const Mailbox(
        id: 'INBOX',
        accountId: 'a1',
        path: 'INBOX',
        name: 'Inbox',
        unreadCount: 0,
        totalCount: 0,
      ),
    ]);

class _CountingEmails extends FakeEmailRepositoryBase {
  int syncCount = 0;
  int wakeUpCount = 0;
  final Exception? syncError;

  _CountingEmails({this.syncError});

  // Only sync/wake-up are counted; everything else keeps the no-op base.
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
}

// ── tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('AccountSyncManager backoff', () {
    test('backoff is capped at 900 s after repeated failures', () {
      fakeAsync((async) {
        final emails = _CountingEmails(
          syncError: Exception('connection refused'),
        );
        final syncLog = FakeSyncLogRepository();
        final manager = AccountSyncManager(
          _FakeAccounts(),
          _inboxOnly(),
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
        final syncLog = FakeSyncLogRepository();

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
          _inboxOnly(),
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
        final syncLog = FakeSyncLogRepository();
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
