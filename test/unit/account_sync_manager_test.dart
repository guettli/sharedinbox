import 'dart:async';

import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:mockito/annotations.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart' show SyncEmailsResult;
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';
import 'package:sharedinbox/core/repositories/sync_log_repository.dart';
import 'package:sharedinbox/core/sync/account_sync_manager.dart';
import 'package:test/test.dart';

@GenerateMocks([AccountRepository, MailboxRepository, EmailRepository])
import 'account_sync_manager_test.mocks.dart';
import 'helpers/fake_email_repository.dart';

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

  // A kick (a local change was queued, or Retry was pressed) that lands while
  // a sync cycle is running used to be dropped: kick() only completed an
  // active wait, and the loop then idled — IMAP IDLE for up to 25 minutes —
  // with the change still queued. Seen on a device as an Undo that never
  // reached the server, because the archive before it had just started a
  // cycle. The kick must instead cut the following wait short.
  test('a kick during a running sync cycle starts the next cycle at once',
      () async {
    final release = Completer<void>();
    final mailboxes = _BlockingMailboxRepository(release.future, fail: true);
    final m = AccountSyncManager(
      _OkAccountRepository(),
      mailboxes,
      FakeEmailRepository(),
      syncLog: FakeSyncLogRepository(),
    );
    addTearDown(m.dispose);

    // The cycle fails, so without the kick the loop would sit out a 5 s
    // backoff before cycle two.
    await _kickMidFirstCycle(m, mailboxes, release);

    expect(mailboxes.calls, 2);
  });

  // Same, but the cycle succeeds: the loop must not go into IMAP IDLE (where
  // the queued change would sit for up to 25 minutes) before cycle two.
  test('a kick during a successful IMAP cycle skips IDLE and syncs again',
      () async {
    final release = Completer<void>();
    var connects = 0;
    int? connectsBeforeSecondCycle;
    final mailboxes = _BlockingMailboxRepository(
      release.future,
      onCall: (n) {
        if (n == 2) connectsBeforeSecondCycle = connects;
      },
    );
    final m = AccountSyncManager(
      _OkAccountRepository(),
      mailboxes,
      FakeEmailRepository(),
      syncLog: FakeSyncLogRepository(),
      imapConnect: (_, __, ___) {
        connects++;
        // Never connects: the loop would hang here in place of a real IDLE.
        return Completer<imap.ImapClient>().future;
      },
    );
    addTearDown(m.dispose);

    await _kickMidFirstCycle(m, mailboxes, release);

    expect(mailboxes.calls, 2);
    expect(connectsBeforeSecondCycle, 0, reason: 'IDLE was not entered');
  });

  // The JMAP loop waits on push (EventSource) instead of IDLE; a mid-cycle
  // kick must skip that wait the same way.
  test('a kick during a successful JMAP cycle skips the push wait', () async {
    final release = Completer<void>();
    final emails = _PushCountingEmailRepository();
    int? pushWaitsBeforeSecondCycle;
    final mailboxes = _BlockingMailboxRepository(
      release.future,
      onCall: (n) {
        if (n == 2) pushWaitsBeforeSecondCycle = emails.pushWatches;
      },
    );
    final m = AccountSyncManager(
      _OkAccountRepository(type: AccountType.jmap),
      mailboxes,
      emails,
      syncLog: FakeSyncLogRepository(),
    );
    addTearDown(m.dispose);

    await _kickMidFirstCycle(m, mailboxes, release);

    expect(mailboxes.calls, 2);
    expect(pushWaitsBeforeSecondCycle, 0, reason: 'push wait was not entered');
  });

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
    final syncLog = _RecordingSyncLog();

    final m = AccountSyncManager(
      _OkAccountRepository(),
      _FailingMailboxRepository(),
      FakeEmailRepository(),
      syncLog: syncLog,
    );

    m.start();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final failure = syncLog.firstFailure;
    final protocolLog = failure[#protocolLog] as String?;
    expect(failure[#errorMessage], contains('BAD Could not parse command'));
    expect(protocolLog, isNotNull);
    // The failing command and its rejection are both present.
    expect(protocolLog, contains('SOMEBROKENCOMMAND'));
    expect(protocolLog, contains('BAD Could not parse command'));
    // Credentials are redacted, not leaked verbatim.
    expect(protocolLog, contains('[REDACTED]'));
    expect(protocolLog, isNot(contains('secret123')));

    m.dispose();
  });

  // The captured trace is bounded: a large sync must not retain an unbounded
  // amount of (potentially sensitive) message content, yet the tail — which
  // holds the failing command — is always kept.
  test('captured protocol log on failure is bounded but keeps the failure',
      () async {
    final syncLog = _RecordingSyncLog();

    final m = AccountSyncManager(
      _OkAccountRepository(),
      _FailingMailboxRepository(emittedLines: 5000),
      FakeEmailRepository(),
      syncLog: syncLog,
    );

    m.start();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final protocolLog = syncLog.firstFailure[#protocolLog] as String?;
    expect(protocolLog, isNotNull);
    // Bounded well below the ~5000 filler lines that were emitted.
    expect(protocolLog!.length, lessThan(64 * 1024));
    // The most recent lines (the failing command) survive the trimming.
    expect(protocolLog, contains('BAD Could not parse command'));

    m.dispose();
  });

  // Regression test for issue #967: the mailbox loop had no per-mailbox error
  // handling, so the first folder that failed threw out of the whole cycle.
  // Every folder behind it was never tried, and the failure log hardcoded
  // zeros — so a cycle that had already synced two folders was reported as
  // "Emails fetched 0 / Mailboxes synced 0", which is what made the original
  // bug report look like nothing had happened at all.
  group('one failing mailbox', () {
    test('does not stop the folders behind it', () async {
      final emails = _OneFolderFailsEmailRepository(failingPath: 'Archive');
      final m = AccountSyncManager(
        _OkAccountRepository(),
        _ThreeFolderMailboxRepository(),
        emails,
        syncLog: _RecordingSyncLog(),
      );
      m.start();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      m.dispose();

      expect(
        emails.attempted,
        ['INBOX', 'Archive', 'Sent'],
        reason: 'the folder after the failing one must still be tried',
      );
    });

    test('reports the work that landed instead of zeros', () async {
      final syncLog = _RecordingSyncLog();
      final m = AccountSyncManager(
        _OkAccountRepository(),
        _ThreeFolderMailboxRepository(),
        _OneFolderFailsEmailRepository(failingPath: 'Archive'),
        syncLog: syncLog,
      );
      m.start();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      m.dispose();

      final failure = syncLog.firstFailure;
      expect(
        failure[#emailsFetched],
        4,
        reason: 'INBOX fetched 3 and Sent fetched 1 before the cycle ended',
      );
      expect(
        (failure[#mailboxStats] as List).length,
        2,
        reason: 'per-folder stats must survive the failure',
      );
    });

    test('names the folder that failed and why', () async {
      final syncLog = _RecordingSyncLog();
      final m = AccountSyncManager(
        _OkAccountRepository(),
        _ThreeFolderMailboxRepository(),
        _OneFolderFailsEmailRepository(
          failingPath: 'Archive',
          error: TimeoutException('server too slow'),
        ),
        syncLog: syncLog,
      );
      m.start();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      m.dispose();

      final message = syncLog.firstFailure[#errorMessage] as String;
      expect(message, contains('1 of 3 folders failed'));
      expect(message, contains('Archive'));
    });

    test('a cycle where every folder fails still reports what landed',
        () async {
      final syncLog = _RecordingSyncLog();
      final m = AccountSyncManager(
        _OkAccountRepository(),
        _ThreeFolderMailboxRepository(),
        _OneFolderFailsEmailRepository(failingPath: null),
        syncLog: syncLog,
      );
      m.start();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      m.dispose();

      final failure = syncLog.firstFailure;
      // A total outage is not a partial cycle — the ordinary offline case must
      // not read as "3 of 3 folders failed" — so the raw cause is reported.
      final message = failure[#errorMessage] as String;
      expect(message, isNot(contains('folders failed')));
      expect(message, contains('folder INBOX is broken'));
      // …but `syncMailboxes` ran and succeeded before the folders did, so its
      // counter is real and must survive. Hardcoding zeros here is what made
      // the #967 report read as "nothing happened".
      expect(
        failure[#mailboxesSynced],
        3,
        reason: 'mailbox sync succeeded before the folders failed',
      );
    });

    test('a folder failing permanently stops the account even if later',
        () async {
      final syncLog = _RecordingSyncLog();
      final m = AccountSyncManager(
        _OkAccountRepository(),
        _ThreeFolderMailboxRepository(),
        _OneFolderFailsEmailRepository(
          failingPath: 'INBOX',
          error: TimeoutException('slow'),
          alsoFailingPath: 'Sent',
          alsoError: Exception('authentication failed'),
        ),
        syncLog: syncLog,
      );
      m.start();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      m.dispose();

      // The transient first failure must not mask the permanent later one —
      // otherwise the account retries forever and never learns.
      expect(syncLog.firstFailure[#isPermanent], isTrue);
    });
  });
}

/// A pure no-op [EmailRepository]; AccountSyncManager only drives sync, so no
/// method needs bespoke behaviour here.
class FakeEmailRepository extends FakeEmailRepositoryBase {}

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
/// sync fails. Implemented via [noSuchMethod] so it carries no repository
/// boilerplate to duplicate.
class _OkAccountRepository implements AccountRepository {
  _OkAccountRepository({AccountType type = AccountType.imap})
      : _account = Account(
          id: '1',
          displayName: 'Test',
          email: 'test@example.com',
          imapHost: 'imap.example.com',
          type: type,
        );

  final Account _account;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #observeAccounts:
        return Stream.value([_account]);
      case #getAccount:
        return Future.value(_account);
      case #getPassword:
        return Future.value('secret123');
      default:
        return Future<void>.value();
    }
  }
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

/// A mailbox repository whose [syncMailboxes] waits for [release], so a test
/// can act while a sync cycle is in flight, then succeeds — or throws when
/// [fail] is set. [onCall] sees the 1-based call number, one per sync cycle.
class _BlockingMailboxRepository extends FakeMailboxRepositoryWithInbox {
  _BlockingMailboxRepository(this.release, {this.onCall, this.fail = false});

  final Future<void> release;
  final void Function(int call)? onCall;
  final bool fail;
  int calls = 0;

  @override
  Future<int> syncMailboxes(String id) async {
    calls++;
    onCall?.call(calls);
    await release;
    if (fail) throw Exception('server unavailable');
    return 1;
  }
}

/// Starts [m], kicks account '1' while its first sync cycle is held in
/// [mailboxes], then lets that cycle finish and gives the loop time to act.
Future<void> _kickMidFirstCycle(
  AccountSyncManager m,
  _BlockingMailboxRepository mailboxes,
  Completer<void> release,
) async {
  m.start();
  await Future<void>.delayed(const Duration(milliseconds: 50));
  expect(mailboxes.calls, 1, reason: 'first cycle is in flight');

  expect(m.syncNow('1'), isTrue);
  release.complete();
  await Future<void>.delayed(const Duration(milliseconds: 200));
}

/// Counts JMAP push waits; the push stream never fires nor closes, like a
/// connected but silent EventSource.
class _PushCountingEmailRepository extends FakeEmailRepositoryBase {
  int pushWatches = 0;

  @override
  Stream<void> watchJmapPush(String a, String password) {
    pushWatches++;
    return StreamController<void>().stream;
  }
}

/// Captures the named arguments of every `log(...)` call so a test can assert
/// on `errorMessage`/`protocolLog`. Implemented via [noSuchMethod] so it needs
/// no copy of the long [SyncLogRepository.log] signature (which would clone
/// the other sync-log fakes).
class _RecordingSyncLog implements SyncLogRepository {
  final calls = <Map<Symbol, dynamic>>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #log:
        calls.add(invocation.namedArguments);
        return Future<int>.value(calls.length);
      case #observeSyncLogs:
        return const Stream<List<SyncLogEntry>>.empty();
      case #observeLastError:
        return const Stream<String?>.empty();
      default:
        return null;
    }
  }

  /// The named arguments of the first failed (`success: false`) log call.
  Map<Symbol, dynamic> get firstFailure =>
      calls.firstWhere((c) => c[#success] == false);
}

/// Three folders, so a cycle can fail on the middle one and still have a
/// folder behind it that must be tried.
class _ThreeFolderMailboxRepository extends FakeMailboxRepositoryWithInbox {
  static const _paths = ['INBOX', 'Archive', 'Sent'];

  @override
  Stream<List<Mailbox>> observeMailboxes(String? accountId) => Stream.value([
        for (final path in _paths)
          Mailbox(
            id: '1:$path',
            accountId: '1',
            path: path,
            name: path,
            unreadCount: 0,
            totalCount: 0,
            role: path == 'INBOX' ? 'inbox' : null,
          ),
      ]);

  @override
  Future<int> syncMailboxes(String id) async => _paths.length;
}

/// Fails [failingPath] and succeeds elsewhere, recording the order in which
/// folders were attempted. A null [failingPath] fails every folder, which is
/// the account-level-outage case rather than a partial cycle.
class _OneFolderFailsEmailRepository extends FakeEmailRepositoryBase {
  _OneFolderFailsEmailRepository({
    required this.failingPath,
    this.error,
    this.alsoFailingPath,
    this.alsoError,
  });

  final String? failingPath;
  final Object? error;

  /// A second folder that fails with a different error, so a cycle can hold
  /// one transient and one permanent failure at once.
  final String? alsoFailingPath;
  final Object? alsoError;

  final attempted = <String>[];

  static const _fetchCounts = {'INBOX': 3, 'Sent': 1};

  @override
  Future<SyncEmailsResult> syncEmails(String accountId, String mailbox) async {
    attempted.add(mailbox);
    if (mailbox == alsoFailingPath) {
      throw alsoError ?? Exception('folder $mailbox is broken');
    }
    if (failingPath == null || mailbox == failingPath) {
      throw error ?? Exception('folder $mailbox is broken');
    }
    return SyncEmailsResult(
      fetched: _fetchCounts[mailbox] ?? 0,
      skipped: 0,
      bytesTransferred: 0,
    );
  }
}
