// Tests for ReliabilityRunner.checkNow() — the manual "Verify sync health"
// trigger.  Specifically guards against regression of issue #95 where
// checkNow() silently did nothing because it delegated to _runAll(), which
// checked the _running flag (only true after start() is called).

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/models/pending_change.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/core/sync/reliability_runner.dart';
import 'package:sharedinbox/data/db/database.dart'
    hide Account, Email, EmailBody;
import 'package:sharedinbox/data/repositories/app_log_repository_impl.dart';

import 'db_test_helper.dart';

// ---------------------------------------------------------------------------
// Minimal fakes
// ---------------------------------------------------------------------------

const _kAccount = Account(
  id: 'test-account',
  displayName: 'Test',
  email: 'test@example.com',
  imapHost: 'localhost',
);

const _kMailbox = Mailbox(
  id: 'test-account:INBOX',
  accountId: 'test-account',
  path: 'INBOX',
  name: 'INBOX',
  unreadCount: 0,
  totalCount: 0,
);

class _FakeAccounts implements AccountRepository {
  @override
  Stream<List<Account>> observeAccounts() => Stream.value([_kAccount]);
  @override
  Future<Account?> getAccount(String id) async => _kAccount;
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
  @override
  Stream<List<Mailbox>> observeMailboxes(String? accountId) =>
      Stream.value([_kMailbox]);
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

class _FakeEmails implements EmailRepository {
  int verifyCallCount = 0;

  @override
  Future<ReliabilityResult> verifySyncReliability(
    String accountId,
    String mailboxPath,
  ) async {
    verifyCallCount++;
    return ReliabilityResult.healthy;
  }

  @override
  Future<MailboxDiagnostics> diagnoseMailbox(
    String accountId,
    String mailboxPath,
  ) async {
    return MailboxDiagnostics(
      accountId: accountId,
      mailboxPath: mailboxPath,
      protocol: 'IMAP',
      cachedTotal: 0,
      cachedUnread: 0,
      localEmailRows: 0,
      localThreadRows: 0,
    );
  }

  // All remaining methods are unused by ReliabilityRunner.
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
  Future<void> markAllAsRead(String a, String m) async {}
  @override
  Future<void> moveEmail(String id, String dest) async {}
  @override
  Future<String?> deleteEmail(String id) async => null;
  @override
  Future<void> sendEmail(String a, EmailDraft d) async {}
  @override
  Future<int> enqueueSend(String a, EmailDraft d) async => 0;
  @override
  Future<int> flushOutbox(String a, String p) async => 0;
  @override
  Future<String> downloadAttachment(String id, EmailAttachment att) async => '';
  @override
  Future<String> fetchRawRfc822(String id) async => '';
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
  Stream<List<PendingChange>> observePendingChanges(String a) =>
      Stream.value([]);
  @override
  Stream<List<PendingChange>> observeAllPendingChanges() => Stream.value([]);
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
  Future<Email?> findEmailByMessageId(String a, String messageId) async => null;
  @override
  Stream<String> get onChangesQueued => const Stream.empty();
  @override
  Stream<void> watchJmapPush(String a, String password) => const Stream.empty();
  @override
  Future<int> flushPendingChanges(String a, String password) async => 0;
  @override
  Future<int> wakeUpEmails(String accountId) async => 0;
  @override
  Future<void> clearForResync(String accountId) async {}
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  configureSqliteForTests();

  group('ReliabilityRunner.checkNow()', () {
    late AppDatabase db;
    late _FakeEmails emails;
    late ReliabilityRunner runner;

    ReliabilityRunner buildRunner(_FakeEmails e) {
      return ReliabilityRunner(
        db,
        _FakeAccounts(),
        _FakeMailboxes(),
        e,
        AppLogger(AppLogRepositoryImpl(db)),
      );
    }

    setUp(() {
      db = openTestDatabase();
      emails = _FakeEmails();
      runner = buildRunner(emails);
    });

    tearDown(() => db.close());

    test('writes sync-health row even when start() was never called', () async {
      // Do NOT call runner.start() — this was the bug: checkNow() only ran
      // when _running was true, which required start() to have been called.
      await runner.checkNow();

      final rows = await db.select(db.syncHealth).get();
      expect(rows, hasLength(1), reason: 'checkNow() must write to the DB');
      expect(rows.first.accountId, 'test-account');
      expect(rows.first.isHealthy, isTrue);
    });

    test('calls verifySyncReliability for each mailbox', () async {
      await runner.checkNow();

      expect(
        emails.verifyCallCount,
        1,
        reason: 'one mailbox → one verifySyncReliability call',
      );
    });

    test('also works when start() was called beforehand', () async {
      runner.start();
      await runner.checkNow();

      final rows = await db.select(db.syncHealth).get();
      expect(rows, hasLength(1));
    });

    test('writes a sync_health entry to the app log on every run', () async {
      await runner.checkNow();

      final logs = await db.select(db.appLogs).get();
      expect(
        logs.any((l) => l.event == 'sync_health'),
        isTrue,
        reason: 'a manual check must be discoverable in the App Log',
      );
    });

    test('persists the error and logs it when verification throws', () async {
      runner = buildRunner(_ThrowingEmails(Exception('jmap connect failed')));

      await runner.checkNow();

      final rows = await db.select(db.syncHealth).get();
      expect(rows, hasLength(1), reason: 'a failure must still write a row');
      expect(rows.first.isHealthy, isFalse);
      expect(rows.first.lastError, contains('jmap connect failed'));

      final logs = await db.select(db.appLogs).get();
      expect(
        logs.any((l) => l.level == 'error' && l.event == 'sync_health'),
        isTrue,
        reason: 'a failure must be logged at error level',
      );
    });

    test('clears a previous error once the check succeeds', () async {
      // First run fails and records an error.
      await buildRunner(_ThrowingEmails(Exception('boom'))).checkNow();
      expect(
        (await db.select(db.syncHealth).get()).first.lastError,
        isNotNull,
      );

      // A subsequent healthy run must clear the stale error.
      await runner.checkNow();

      final rows = await db.select(db.syncHealth).get();
      expect(rows.first.lastError, isNull);
      expect(rows.first.isHealthy, isTrue);
    });
  });
}

/// A [_FakeEmails] whose reliability check always fails, exercising the
/// error-handling path (a JMAP/IMAP connection or auth failure).
class _ThrowingEmails extends _FakeEmails {
  _ThrowingEmails(this.error);

  final Object error;

  @override
  Future<ReliabilityResult> verifySyncReliability(String a, String m) async {
    throw error;
  }
}
