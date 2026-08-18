import 'dart:async';

import 'package:flutter/services.dart' show MissingPluginException;
import 'package:mockito/annotations.dart';
import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/models/pending_change.dart';
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

  // Regression test for issue #501: pressing Retry on a queued message used to
  // pop a "Retrying send…" snackbar even when the account's sync loop had
  // already stopped on a permanent error — so nothing ran and no log entry
  // appeared. syncNow must now report the truth (return false so the UI shows
  // the "stopped" message) instead of faking success against a dead loop.
  test('syncNow returns false for a stopped or absent loop', () async {
    final m = AccountSyncManager(
      _AccountRepositoryWithMissingPlugin(),
      FakeMailboxRepositoryWithInbox(),
      FakeEmailRepository(),
      syncLog: FakeSyncLogRepository(),
    );

    m.start();

    // Let the first (and only) sync cycle run and stop the loop permanently.
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Loop registered but no longer running, and account with no loop at all:
    // both must report false rather than faking a successful kick.
    expect(m.syncNow('1'), isFalse);
    expect(m.syncNow('unknown'), isFalse);

    m.dispose();
  });

  // Regression test for issue #608: a first-time Gmail account failed with
  // "BAD Could not parse command" but the sync entry showed no protocol trace,
  // so the user could not tell which command the server rejected. A failed
  // sync must now attach the (credential-redacted) protocol log to its entry
  // even when the account never enabled verbose logging.
  test('failed IMAP sync records the protocol log so the command is visible',
      () async {
    final syncLog = FakeSyncLogRepository();

    final m = AccountSyncManager(
      _OkAccountRepository(),
      _FailingMailboxRepository(),
      FakeEmailRepository(),
      syncLog: syncLog,
    );

    m.start();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final entry = syncLog.logs.firstWhere((l) => !l.success);
    expect(entry.errorMessage, contains('BAD Could not parse command'));
    expect(entry.protocolLog, isNotNull);
    // The failing command and its rejection are both present.
    expect(entry.protocolLog, contains('SOMEBROKENCOMMAND'));
    expect(entry.protocolLog, contains('BAD Could not parse command'));
    // Credentials are redacted, not leaked verbatim.
    expect(entry.protocolLog, contains('[REDACTED]'));
    expect(entry.protocolLog, isNot(contains('secret123')));

    m.dispose();
  });

  // The captured trace is bounded: a large sync must not retain an unbounded
  // amount of (potentially sensitive) message content, yet the tail — which
  // holds the failing command — is always kept.
  test('captured protocol log on failure is bounded but keeps the failure',
      () async {
    final syncLog = FakeSyncLogRepository();

    final m = AccountSyncManager(
      _OkAccountRepository(),
      _FailingMailboxRepository(emittedLines: 5000),
      FakeEmailRepository(),
      syncLog: syncLog,
    );

    m.start();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final entry = syncLog.logs.firstWhere((l) => !l.success);
    expect(entry.protocolLog, isNotNull);
    // Bounded well below the ~5000 filler lines that were emitted.
    expect(entry.protocolLog!.length, lessThan(64 * 1024));
    // The most recent lines (the failing command) survive the trimming.
    expect(entry.protocolLog, contains('BAD Could not parse command'));

    m.dispose();
  });
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
  Future<int> enqueueSend(String a, EmailDraft d) async => 0;
  @override
  Future<int> flushOutbox(String a, String p) async => 0;
  @override
  Future<String> downloadAttachment(String id, EmailAttachment a) async => '';
  @override
  Future<String> fetchRawRfc822(String emailId) async => '';
  @override
  Future<List<Email>> searchEmails(String a, String m, String q) async => [];
  @override
  Future<List<Email>> searchEmailsGlobal(String? a, String q) async => [];
  @override
  Future<List<Email>> searchEmailsStructured(String? a, FilterGroup f) async =>
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
  Stream<List<PendingChange>> observePendingChanges(String a) =>
      Stream.value([]);
  @override
  Stream<List<PendingChange>> observeAllPendingChanges() => Stream.value([]);
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
  Future<MailboxDiagnostics> diagnoseMailbox(String a, String m) async =>
      MailboxDiagnostics.empty(accountId: a, mailboxPath: m);

  @override
  Future<int> sweepOrphanThreads(String a, String m) async => 0;

  @override
  Future<void> clearForResync(String accountId) async {}

  @override
  Future<void> clearMailboxForResync(
    String accountId,
    String mailboxPath,
  ) async {}

  @override
  Future<int> applySieveRules(String accountId) async => 0;

  @override
  Future<int> previewSieveRuleMatches(
    String accountId,
    String scriptContent,
  ) async =>
      0;

  @override
  Future<int> applySieveScriptToInbox(
    String accountId,
    String scriptContent,
  ) async =>
      0;
}

class _Log {
  _Log({
    required this.success,
    this.errorMessage,
    this.protocolLog,
  });
  final bool success;
  final String? errorMessage;
  final String? protocolLog;
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
    logs.add(
      _Log(
        success: success,
        errorMessage: errorMessage,
        protocolLog: protocolLog,
      ),
    );
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
    String role, {
    String? parentDisplayPath,
  }) async =>
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
  Future<Mailbox> createMailbox(
    String accountId,
    String name, {
    String? parentDisplayPath,
  }) async =>
      Mailbox(
        id: '$accountId:$name',
        accountId: accountId,
        path: name,
        name: name,
        unreadCount: 0,
        totalCount: 0,
      );

  @override
  Future<Mailbox> renameMailbox(
    String accountId,
    String mailboxPath,
    String newName,
  ) async =>
      Mailbox(
        id: '$accountId:$mailboxPath',
        accountId: accountId,
        path: mailboxPath,
        name: newName,
        unreadCount: 0,
        totalCount: 0,
      );

  @override
  Future<void> deleteMailbox(String accountId, String mailboxPath) async {}

  @override
  Future<Mailbox> moveMailbox(
    String accountId,
    String mailboxPath, {
    required String? newParentDisplayPath,
  }) async =>
      Mailbox(
        id: '$accountId:$mailboxPath',
        accountId: accountId,
        path: mailboxPath,
        name: mailboxPath,
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

/// A well-behaved account repository whose single IMAP account authenticates
/// successfully — used to exercise the sync path up to the point a mailbox
/// sync fails.
class _OkAccountRepository implements AccountRepository {
  static const _account = Account(
    id: '1',
    displayName: 'Test',
    email: 'test@example.com',
    imapHost: 'imap.example.com',
  );

  @override
  Stream<List<Account>> observeAccounts() => Stream.value([_account]);

  @override
  Future<Account?> getAccount(String id) async => _account;

  @override
  Future<String> getPassword(String accountId) async => 'secret123';

  @override
  Future<void> addAccount(Account account, String password) async {}

  @override
  Future<void> updateAccount(Account account, {String? password}) async {}

  @override
  Future<void> removeAccount(String id) async {}
}

/// A mailbox repository whose [syncMailboxes] emits a fake IMAP protocol trace
/// (via `print`, exactly as `enough_mail` does when logging is enabled) and
/// then throws the server's parse error — mirroring the Gmail failure in
/// issue #608. [emittedLines] controls how much trace is produced so the
/// bounding behaviour can be exercised.
class _FailingMailboxRepository extends FakeMailboxRepositoryWithInbox {
  _FailingMailboxRepository({this.emittedLines = 1});

  final int emittedLines;

  @override
  Future<int> syncMailboxes(String id) async {
    // Emit trace lines the way `enough_mail` does — through the current
    // zone's print handler, which the sync loop overrides to capture them.
    // The password reaches the trace via the LOGIN command; it must be
    // redacted before the log is stored.
    final zone = Zone.current;
    zone.print('C: 1 LOGIN test@example.com secret123');
    zone.print('S: 1 OK LOGIN completed');
    for (var i = 0; i < emittedLines; i++) {
      zone.print('C: ${i + 2} FETCH $i (BODY[]) <filler line $i>');
    }
    zone.print('C: 99 SOMEBROKENCOMMAND');
    zone.print('S: 99 BAD Could not parse command');
    throw Exception('BAD Could not parse command');
  }
}
