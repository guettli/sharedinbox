import 'dart:async';
import 'dart:io';

import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';
import 'package:sharedinbox/core/repositories/sync_log_repository.dart';
import 'package:sharedinbox/core/sync/account_sync_manager.dart';

Future<imap.ImapClient> _fakeImapConnect(
  Account account,
  String username,
  String password,
) async =>
    throw const SocketException('fake — no real IMAP server in tests');

void main() {
  test(
    'AccountSyncManager schedules IMAP sync for multiple accounts',
    () async {
      final accounts = _FakeAccounts('pw');
      final mailboxes = _FakeMailboxes();
      final emails = _FakeEmails();
      final logs = _FakeLogs();

      final manager = AccountSyncManager(
        accounts,
        mailboxes,
        emails,
        syncLog: logs,
        imapConnect: _fakeImapConnect,
      );

      final a1 = _account('1');
      final a2 = _account('2');

      manager.start();
      accounts.push([a1, a2]);

      // Allow some time for listeners to fire.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(emails.syncCounts['1'], greaterThanOrEqualTo(1));
      expect(emails.syncCounts['2'], greaterThanOrEqualTo(1));

      manager.dispose();
    },
  );

  test(
    'AccountSyncManager schedules JMAP sync for multiple accounts',
    () async {
      final accounts = _FakeAccounts('pw');
      final mailboxes = _FakeMailboxes();
      final emails = _FakeEmails();
      final logs = _FakeLogs();

      final manager = AccountSyncManager(
        accounts,
        mailboxes,
        emails,
        syncLog: logs,
      );

      final a1 = _jmapAccount('1');
      final a2 = _jmapAccount('2');

      manager.start();
      accounts.push([a1, a2]);

      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(emails.syncCounts['1'], greaterThanOrEqualTo(1));
      expect(emails.syncCounts['2'], greaterThanOrEqualTo(1));

      manager.dispose();
    },
  );
}

Account _account(String id) => Account(
      id: id,
      displayName: 'Account $id',
      email: '$id@example.com',
      imapHost: 'localhost',
      imapPort: 143,
      imapSsl: false,
      smtpHost: 'localhost',
      smtpPort: 25,
      smtpSsl: false,
    );

Account _jmapAccount(String id) => Account(
      id: id,
      displayName: 'Account $id',
      email: '$id@example.com',
      type: AccountType.jmap,
      jmapUrl: 'http://localhost:8080/.well-known/jmap',
      smtpHost: 'localhost',
      smtpPort: 25,
      smtpSsl: false,
    );

class _FakeAccounts implements AccountRepository {
  _FakeAccounts(this.password);
  final String password;
  final _ctrl = StreamController<List<Account>>.broadcast();

  @override
  Stream<List<Account>> observeAccounts() => _ctrl.stream;

  @override
  Future<Account?> getAccount(String id) async => null;

  @override
  Future<String> getPassword(String accountId) async => password;

  @override
  Future<void> addAccount(Account a, String p) async {}
  @override
  Future<void> removeAccount(String id) async {}
  @override
  Future<void> updateAccount(Account a, {String? password}) async {}

  void push(List<Account> accounts) => _ctrl.add(accounts);
}

class _FakeMailboxes implements MailboxRepository {
  @override
  Stream<List<Mailbox>> observeMailboxes(String? accountId) => Stream.value([
        Mailbox(
          id: '$accountId:INBOX',
          accountId: accountId ?? '',
          path: 'INBOX',
          name: 'INBOX',
          unreadCount: 0,
          totalCount: 0,
          role: 'inbox',
        ),
      ]);

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
}

class _FakeEmails implements EmailRepository {
  final syncCounts = <String, int>{};

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
  Stream<List<Email>> observeEmailsInThread(String a, String m, String t) =>
      Stream.value([]);

  @override
  Future<Email?> getEmail(String id) async => null;

  @override
  Future<EmailBody> getEmailBody(String id) async =>
      const EmailBody(emailId: '', attachments: []);

  @override
  Future<SyncEmailsResult> syncEmails(String a, String m) async {
    syncCounts[a] = (syncCounts[a] ?? 0) + 1;
    return SyncEmailsResult.zero;
  }

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
  Future<String> fetchRawRfc822(String emailId) async => '';

  @override
  Future<List<Email>> searchEmails(String a, String m, String q) async => [];

  @override
  Future<List<Email>> searchEmailsGlobal(String? a, String q) async => [];

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
  Stream<void> watchJmapPush(String accountId, String password) =>
      const Stream.empty();

  @override
  Future<ReliabilityResult> verifySyncReliability(
    String accountId,
    String mailboxPath,
  ) async =>
      ReliabilityResult.healthy;

  @override
  Stream<List<FailedMutation>> observeFailedMutations(String accountId) =>
      Stream.value([]);

  @override
  Future<void> discardMutation(int id) async {}

  @override
  Future<void> retryMutation(int id) async {}

  @override
  Future<void> clearForResync(String accountId) async {}

  @override
  Future<int> applySieveRules(String accountId) async => 0;
}

class _FakeLogs implements SyncLogRepository {
  @override
  Future<void> log({
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
  }) async {}

  @override
  Stream<List<SyncLogEntry>> observeSyncLogs(String accountId) =>
      Stream.value([]);

  @override
  Stream<String?> observeLastError(String accountId) => Stream.value(null);
}
