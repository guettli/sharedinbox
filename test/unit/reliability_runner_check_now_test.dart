// Tests for ReliabilityRunner.checkNow() — the manual "Verify sync health"
// trigger.  Specifically guards against regression of issue #95 where
// checkNow() silently did nothing because it delegated to _runAll(), which
// checked the _running flag (only true after start() is called).

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/core/sync/reliability_runner.dart';
import 'package:sharedinbox/data/db/database.dart'
    hide Account, Email, EmailBody;
import 'package:sharedinbox/data/repositories/app_log_repository_impl.dart';

import 'db_test_helper.dart';
import 'helpers/fake_email_repository.dart';

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

class _FakeEmails extends FakeEmailRepositoryBase {
  int verifyCallCount = 0;

  // All other methods keep the no-op base behaviour; ReliabilityRunner only
  // calls verifySyncReliability (counted here) and diagnoseMailbox.
  @override
  Future<ReliabilityResult> verifySyncReliability(
    String accountId,
    String mailboxPath,
  ) async {
    verifyCallCount++;
    return ReliabilityResult.healthy;
  }
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
