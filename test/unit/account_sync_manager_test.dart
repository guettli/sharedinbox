import 'dart:async';

import 'package:flutter/services.dart' show MissingPluginException;
import 'package:mockito/annotations.dart';
import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';
import 'package:sharedinbox/core/repositories/sync_log_repository.dart';
import 'package:sharedinbox/core/sync/account_sync_manager.dart';
import 'package:test/test.dart';

@GenerateMocks([AccountRepository, MailboxRepository, EmailRepository])
import 'account_sync_manager_test.mocks.dart';

void main() {
  late MockAccountRepository accounts;
  late MockMailboxRepository mailboxes;
  late MockEmailRepository emails;
  late AccountSyncManager manager;

  setUp(() {
    accounts = MockAccountRepository();
    mailboxes = MockMailboxRepository();
    emails = MockEmailRepository();
    manager = AccountSyncManager(accounts, mailboxes, emails);
  });

  test('syncNow kicks the active sync loop', () async {
    // This is hard to test without real loops, but we can verify it doesn't crash.
    manager.syncNow('unknown');
  });

  // Regression test for issue #200: when flutter_secure_storage throws
  // MissingPluginException (channel unavailable on the device), the IMAP sync
  // loop must stop permanently instead of retrying indefinitely with backoff.
  test(
    'MissingPluginException from secure storage stops IMAP sync loop permanently',
    () async {
      final syncLog = FakeSyncLogRepository();

      final m = AccountSyncManager(
        _AccountRepositoryWithMissingPlugin(),
        FakeMailboxRepositoryWithInbox(),
        FakeEmailRepository(),
        syncLog: syncLog,
      );

      m.start();

      // Allow the first sync cycle to run and fail.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(syncLog.logs, hasLength(1));
      expect(syncLog.logs.first.success, isFalse);

      // Kicking the loop should have no effect once it has stopped permanently.
      m.syncNow('1');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Before the fix: kick triggers a retry → 2 log entries.
      // After the fix: loop is permanently stopped → still exactly 1 entry.
      expect(syncLog.logs, hasLength(1));

      m.dispose();
    },
  );
}

class FakeEmailRepository implements EmailRepository {
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
  Future<SyncEmailsResult> syncEmails(String a, String m) async =>
      SyncEmailsResult.zero;
  @override
  Future<void> setFlag(String id, {bool? seen, bool? flagged}) async {}
  @override
  Future<void> markAllAsRead(String accountId, String mailboxPath) async {}
  @override
  Future<void> moveEmail(String id, String dest) async {}

  @override
  Future<bool> cancelPendingChange(String id, String type) async => false;

  @override
  Future<void> snoozeEmail(String emailId, DateTime until) async {}

  @override
  Future<int> wakeUpEmails(String accountId) async => 0;

  @override
  Future<void> restoreEmails(List<Email> emails) async {}

  @override
  Future<Email?> findEmailByMessageId(
    String accountId,
    String messageId,
  ) async =>
      null;

  @override
  Future<String?> deleteEmail(String id) async => null;
  @override
  Stream<String> get onChangesQueued => const Stream.empty();
  @override
  Future<int> flushPendingChanges(String a, String p) async => 0;
  @override
  Future<void> sendEmail(String a, EmailDraft d) async {}
  @override
  Future<String> downloadAttachment(String id, EmailAttachment a) async => '';
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
  Future<List<Email>> getEmailsByAddress(String? a, String address) async => [];
  @override
  Future<List<EmailAddress>> searchAddresses(
    String? a,
    String q, {
    int limit = 10,
  }) async =>
      [];
  @override
  Stream<void> watchJmapPush(String a, String p) => const Stream.empty();
  @override
  Stream<List<FailedMutation>> observeFailedMutations(String a) =>
      Stream.value([]);
  @override
  Future<void> discardMutation(int id) async {}
  @override
  Future<void> retryMutation(int id) async {}

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

class _Log {
  _Log({required this.success});
  final bool success;
}

class FakeSyncLogRepository implements SyncLogRepository {
  final logs = <_Log>[];
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
    logs.add(_Log(success: success));
    return _nextId++;
  }

  @override
  Stream<List<SyncLogEntry>> observeSyncLogs(String accountId) =>
      Stream.value([]);

  @override
  Stream<String?> observeLastError(String accountId) => Stream.value(null);
}

class FakeMailboxRepositoryWithInbox implements MailboxRepository {
  @override
  Stream<List<Mailbox>> observeMailboxes(String? accountId) => Stream.value([
        const Mailbox(
          id: '1:INBOX',
          accountId: '1',
          path: 'INBOX',
          name: 'INBOX',
          unreadCount: 0,
          totalCount: 0,
          role: 'inbox',
        ),
      ]);
  @override
  Future<int> syncMailboxes(String id) async => 1;
  @override
  Future<Mailbox?> findMailboxByRole(String id, String role) async => null;
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

class _AccountRepositoryWithMissingPlugin implements AccountRepository {
  static const _account = Account(
    id: '1',
    displayName: 'Test',
    email: 'test@example.com',
  );

  @override
  Stream<List<Account>> observeAccounts() => Stream.value([_account]);

  @override
  Future<Account?> getAccount(String id) async => _account;

  @override
  Future<String> getPassword(String accountId) => Future.error(
        MissingPluginException(
          'No implementation found for method read on channel '
          'plugins.it.nomads.com/flutter_secure_storage',
        ),
      );

  @override
  Future<void> addAccount(Account account, String password) async {}

  @override
  Future<void> updateAccount(Account account, {String? password}) async {}

  @override
  Future<void> removeAccount(String id) async {}
}
