import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';
import 'package:sharedinbox/core/repositories/sync_log_repository.dart';
import 'package:sharedinbox/core/sync/account_sync_manager.dart';

void main() {
  late FakeAccountRepository accounts;
  late FakeMailboxRepository mailboxes;
  late FakeEmailRepository emails;
  late FakeSyncLogRepository logs;
  late AccountSyncManager manager;

  setUp(() {
    accounts = FakeAccountRepository();
    mailboxes = FakeMailboxRepository();
    emails = FakeEmailRepository();
    logs = FakeSyncLogRepository();
    manager = AccountSyncManager(
      accounts,
      mailboxes,
      emails,
      syncLog: logs,
    );
  });

  test('Sync starts when account is added', () async {
    final a = _account('1');
    manager.start();
    accounts.push([a]);
    await _pump();
    expect(mailboxes.syncCounts['1'], 1);
    manager.dispose();
  });

  test('Sync failure adds log entry', () async {
    final a = _account('1');
    manager = AccountSyncManager(
      accounts,
      FailingMailboxRepository(),
      emails,
      syncLog: logs,
    );
    manager.start();
    accounts.push([a]);
    await _pump();
    expect(logs.logs.length, 1);
    expect(logs.logs.first.success, false);
    manager.dispose();
  });
}

Account _account(String id) => Account(
      id: id,
      displayName: 'A$id',
      email: 'a$id@example.com',
      imapHost: 'localhost',
      imapPort: 143,
      imapSsl: false,
      smtpHost: 'localhost',
      smtpPort: 25,
      smtpSsl: false,
    );

Future<void> _pump() => Future.delayed(const Duration(milliseconds: 100));

class FakeAccountRepository implements AccountRepository {
  final _ctrl = StreamController<List<Account>>.broadcast();
  @override
  Stream<List<Account>> observeAccounts() => _ctrl.stream;
  @override
  Future<Account?> getAccount(String id) async => null;
  @override
  Future<String> getPassword(String id) async => 'pw';
  @override
  Future<void> addAccount(Account a, String p) async {}
  @override
  Future<void> removeAccount(String id) async {}
  @override
  Future<void> updateAccount(Account a, {String? password}) async {}
  void push(List<Account> list) => _ctrl.add(list);
}

class FakeMailboxRepository implements MailboxRepository {
  final syncCounts = <String, int>{};
  @override
  Stream<List<Mailbox>> observeMailboxes(String? accountId) => Stream.value([]);
  @override
  Future<int> syncMailboxes(String id) async {
    syncCounts[id] = (syncCounts[id] ?? 0) + 1;
    return 1;
  }

  @override
  Future<Mailbox?> findMailboxByRole(String id, String role) async => null;
}

class FailingMailboxRepository extends FakeMailboxRepository {
  @override
  Future<int> syncMailboxes(String id) async => throw Exception('fail');
}

class FakeEmailRepository implements EmailRepository {
  @override
  Stream<List<Email>> observeEmails(String a, String m) => Stream.value([]);
  @override
  Stream<List<EmailThread>> observeThreads(String a, String m) =>
      Stream.value([]);
  @override
  Stream<List<Email>> observeEmailsInThread(String a, String m, String t) =>
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
  Future<bool> cancelPendingChange(String id, String type) async => false;

  @override
  Future<void> deleteEmail(String id) async {}
  @override
  Stream<String> get onChangesQueued => const Stream.empty();
  @override
  Future<int> flushPendingChanges(String a, String p) async => 0;
  @override
  Future<void> sendEmail(String a, EmailDraft d) async {}
  @override
  Future<String> downloadAttachment(String id, EmailAttachment a) async => '';
  @override
  Future<List<Email>> searchEmails(String a, String m, String q) async => [];
  @override
  Future<List<Email>> searchEmailsGlobal(String? a, String q) async => [];
  @override
  Future<List<Email>> getEmailsByAddress(String? a, String address) async => [];
  @override
  Stream<void> watchJmapPush(String a, String p) => const Stream.empty();
  @override
  Stream<List<FailedMutation>> observeFailedMutations(String a) =>
      Stream.value([]);
  @override
  Future<void> discardMutation(int id) async {}
  @override
  Future<void> retryMutation(int id) async {}
}

class _Log {
  _Log({required this.success});
  final bool success;
}

class FakeSyncLogRepository implements SyncLogRepository {
  final logs = <_Log>[];
  @override
  Future<void> log({
    required String accountId,
    required bool success,
    String? errorMessage,
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
  }

  @override
  Stream<List<SyncLogEntry>> observeSyncLogs(String accountId) =>
      Stream.value([]);
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
}
