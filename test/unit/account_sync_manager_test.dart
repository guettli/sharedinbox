import 'dart:async';

import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:mockito/annotations.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart'
    show ImapMailboxState, SyncEmailsResult;
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';
import 'package:sharedinbox/core/repositories/sync_log_repository.dart';
import 'package:sharedinbox/core/sync/account_sync_manager.dart';
import 'package:test/test.dart';

@GenerateMocks([AccountRepository, MailboxRepository, EmailRepository])
import 'account_sync_manager_test.mocks.dart';
import 'fake_imap.dart';
import 'helpers/fake_email_repository.dart';
import 'helpers/fake_mailbox_repository.dart';
import 'helpers/fake_sync_log_repository.dart';

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
      expect(syncLog.logs.first, isFalse);

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

  // A flag changed on another device (`UID STORE 2 +FLAGS (\\Seen)`) is
  // reported during IDLE as an untagged FETCH. The IDLE wait used to react
  // only to EXISTS and EXPUNGE, so such changes reached the app only with the
  // next full sync, up to 25 minutes later. It must now wake the loop for one
  // sync cycle, after which it goes back to IDLE (no echo loop). VANISHED is
  // only sent after ENABLE QRESYNC, which the IDLE connection does not send
  // today; the loop listens for it defensively, covered here too. EXISTS is
  // the control case that already worked.
  final idleEvents = <String, imap.ImapEvent Function(imap.ImapClient)>{
    'FETCH (flag change)': (c) => imap.ImapFetchEvent(imap.MimeMessage(), c),
    'VANISHED (defensive, QRESYNC only)': (c) => imap.ImapVanishedEvent(
          imap.MessageSequence.fromId(2, isUid: true),
          c,
          isEarlier: false,
        ),
    'EXISTS': (c) => imap.ImapMessagesExistEvent(3, 2, c),
  };
  for (final MapEntry(key: name, value: makeEvent) in idleEvents.entries) {
    test('an IMAP IDLE $name event wakes the loop for one sync cycle',
        () async {
      // Only the first IDLE session sees a change from another device; the
      // loop syncs, then idles again in a second session.
      final (:mailboxes, :clients) = await _runImapLoopUntilIdling(
        FakeEmailRepository(),
        (n) => _FakeIdleClient(fireOnIdle: n == 0 ? makeEvent : null),
        sessions: 2,
      );

      expect(mailboxes.calls, 2, reason: 'the $name event triggered a sync');
      expect(clients, hasLength(2), reason: 'the loop went back to IDLE');
      expect(clients.first.idleDoneCalled, isTrue);
      expect(clients.last.idleDoneCalled, isFalse, reason: 'still idling');
    });
  }

  // Mail delivered while a cycle runs, after it fetched INBOX, is already in
  // the mailbox when the IDLE connection selects INBOX, so IDLE never reports
  // it. Seen with 300 APPENDs: the app stopped at 296 of 331 until a manual
  // sync. The IDLE SELECT now shows a higher UIDNEXT than the last sync saw,
  // and the loop must sync again instead of idling — then idle once settled.
  test('IMAP mail delivered during a cycle is synced before IDLE', () async {
    final emails = _UidNextEmailRepository(serverUidNext: 297);
    // A delivery right after the first cycle synced INBOX.
    emails.afterSync = () => emails.serverUidNext = 332;
    final (:mailboxes, :clients) = await _runImapLoopUntilIdling(
      emails,
      (_) => _FakeIdleClient(inboxUidNext: emails.serverUidNext),
    );

    expect(mailboxes.calls, 2, reason: 'the late delivery was synced');
    expect(clients, hasLength(2));
    expect(clients.first.idleStarted, isFalse, reason: 'IDLE was skipped');
    expect(clients.last.idleStarted, isTrue, reason: 'idles once caught up');
    expect(emails.syncedUidNext, 332);
  });

  // A sync state that never matches the IDLE SELECT (stale state, or a server
  // reporting UIDNEXT inconsistently) must not make the loop spin: after a
  // bounded number of catch-up cycles it idles anyway.
  test('IMAP IDLE catch-up cycles are bounded', () async {
    final (:mailboxes, :clients) = await _runImapLoopUntilIdling(
      _UidNextEmailRepository(serverUidNext: 5, frozen: true),
      (_) => _FakeIdleClient(inboxUidNext: 9),
    );

    expect(mailboxes.calls, 4, reason: 'first cycle + 3 catch-up cycles');
    expect(clients, hasLength(4));
    expect(clients.last.idleStarted, isTrue);
  });

  // Found with the explore fault proxy (#1197): with the app resting in IDLE,
  // the proxy going `down` or `reset` closes the socket. enough_mail then
  // fires ImapConnectionLostEvent but never answers the pending IDLE, so a
  // DONE or LOGOUT on that connection never completes. The IDLE wait ignored
  // the event and sat on the dead socket — no reconnect, no new mail — and a
  // kick ("Sync all") then hung for good in LOGOUT. The loss must end IDLE as
  // a logged transient failure, after which the loop reconnects.
  test('a lost IMAP IDLE connection ends IDLE and the loop reconnects',
      () async {
    final syncLog = FakeSyncLogRepository();
    final (:manager, :clients, mailboxes: _) = _startImapLoop(
      FakeEmailRepository(),
      (n) => n == 0 ? _BreakingIdleClient(reportLoss: true) : _FakeIdleClient(),
      syncLog: syncLog,
    );

    await _until(() => syncLog.logs.contains(false), 'the loss was logged');
    manager.syncNow('1'); // "Sync all" cuts the backoff short.
    await _untilIdling(clients, sessions: 2);

    expect(syncLog.logs, [true, false, true]);
    expect(
      clients.first.logoutCalled,
      isFalse,
      reason: 'no LOGOUT on a dead connection: it would never be answered',
    );
  });

  // Fault proxy `blackhole`: the connection stays open but nothing is ever
  // answered again, and no loss is reported. A kick then sends DONE, which
  // used to wait forever.
  test('a kick on a blackholed IMAP IDLE connection cannot hang the loop',
      () async {
    final syncLog = FakeSyncLogRepository();
    final (:manager, :clients, mailboxes: _) = _startImapLoop(
      FakeEmailRepository(),
      (n) =>
          n == 0 ? _BreakingIdleClient(reportLoss: false) : _FakeIdleClient(),
      syncLog: syncLog,
      timings: const ImapIdleTimings(commandTimeout: _shortTimeout),
    );

    await _untilIdling(clients);
    manager.syncNow('1');
    await _until(() => syncLog.logs.contains(false), 'the hung DONE failed');
    manager.syncNow('1');
    await _untilIdling(clients, sessions: 2);

    expect(syncLog.logs, [true, false, true]);
    expect(clients.first.idleDoneCalled, isTrue);
  });

  // Without a kick or new mail, a blackholed connection is only noticed by the
  // periodic IDLE refresh (DONE, NOOP, IDLE).
  test('the periodic IDLE refresh detects a blackholed connection', () async {
    final syncLog = FakeSyncLogRepository();
    final (:manager, :clients, mailboxes: _) = _startImapLoop(
      FakeEmailRepository(),
      (n) =>
          n == 0 ? _BreakingIdleClient(reportLoss: false) : _FakeIdleClient(),
      syncLog: syncLog,
      timings: const ImapIdleTimings(
        commandTimeout: _shortTimeout,
        refreshInterval: _shortTimeout,
      ),
    );

    await _until(() => syncLog.logs.contains(false), 'the refresh failed');
    manager.syncNow('1');
    await _untilIdling(clients, sessions: 2);

    expect(syncLog.logs, [true, false, true]);
  });

  // On a healthy connection the refresh re-issues IDLE in place: no new
  // connection and no extra sync cycle.
  test('the periodic IDLE refresh keeps a healthy connection', () async {
    final syncLog = FakeSyncLogRepository();
    final (manager: _, :mailboxes, :clients) = _startImapLoop(
      FakeEmailRepository(),
      (_) => _FakeIdleClient(),
      syncLog: syncLog,
      timings: const ImapIdleTimings(refreshInterval: _shortTimeout),
    );

    await _until(
      () => clients.isNotEmpty && clients.first.idleStarts >= 3,
      'IDLE was refreshed twice',
    );

    expect(clients, hasLength(1));
    expect(clients.first.noops, greaterThanOrEqualTo(2));
    expect(mailboxes.calls, 1);
    expect(syncLog.logs, [true]);
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

class FakeMailboxRepositoryWithInbox extends FakeMailboxRepositoryBase {
  FakeMailboxRepositoryWithInbox()
      : super(const [
          Mailbox(
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

/// Short enough for a test, long enough not to fire before a fake answers.
const _shortTimeout = Duration(milliseconds: 50);

/// Starts an IMAP sync loop over [emails] whose n-th IDLE connection (from
/// 0) is [newClient]`(n)`, returning the manager, the mailbox-sync counter
/// and the list every IDLE client is added to.
({
  AccountSyncManager manager,
  _CountingMailboxRepository mailboxes,
  List<_FakeIdleClient> clients,
}) _startImapLoop(
  EmailRepository emails,
  _FakeIdleClient Function(int n) newClient, {
  SyncLogRepository? syncLog,
  ImapIdleTimings timings = const ImapIdleTimings(),
}) {
  final mailboxes = _CountingMailboxRepository();
  final clients = <_FakeIdleClient>[];
  final m = AccountSyncManager(
    _OkAccountRepository(),
    mailboxes,
    emails,
    syncLog: syncLog ?? FakeSyncLogRepository(),
    imapConnect: (_, __, ___) async {
      final client = newClient(clients.length);
      clients.add(client);
      return client;
    },
    imapIdleTimings: timings,
  );
  addTearDown(m.dispose);
  m.start();
  return (manager: m, mailboxes: mailboxes, clients: clients);
}

/// [_startImapLoop], returning once the loop rests in IDLE (see
/// [_untilIdling]).
Future<
    ({
      _CountingMailboxRepository mailboxes,
      List<_FakeIdleClient> clients,
    })> _runImapLoopUntilIdling(
  EmailRepository emails,
  _FakeIdleClient Function(int n) newClient, {
  int sessions = 1,
}) async {
  final (manager: _, :mailboxes, :clients) = _startImapLoop(emails, newClient);
  await _untilIdling(clients, sessions: sessions);
  return (mailboxes: mailboxes, clients: clients);
}

/// Waits until at least [sessions] IDLE connections were opened and the
/// latest one has started IDLE — the loop's resting state.
Future<void> _untilIdling(
  List<_FakeIdleClient> clients, {
  int sessions = 1,
}) =>
    _until(
      () => clients.length >= sessions && clients.last.idleStarted,
      'IDLE reached in session $sessions (have ${clients.length})',
    );

/// Polls [done] instead of a fixed sleep that flakes on a loaded machine.
/// Fails after [timeout], naming what was awaited.
Future<void> _until(
  bool Function() done,
  String what, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting: $what');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
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

/// Counts sync cycles (one [syncMailboxes] call each).
/// Reports, for INBOX, the UIDNEXT the last sync saw. Each sync records the
/// server's current [serverUidNext] unless [frozen] (a sync state that is
/// never updated), then runs [afterSync] — e.g. a delivery that lands after
/// the sync fetched INBOX.
class _UidNextEmailRepository extends FakeEmailRepositoryBase {
  _UidNextEmailRepository({required this.serverUidNext, this.frozen = false});

  int serverUidNext;
  final bool frozen;
  int? syncedUidNext;
  void Function()? afterSync;

  @override
  Future<SyncEmailsResult> syncEmails(String a, String m) async {
    if (!frozen || syncedUidNext == null) syncedUidNext = serverUidNext;
    afterSync?.call();
    afterSync = null;
    return SyncEmailsResult.zero;
  }

  @override
  Future<ImapMailboxState?> lastImapMailboxState(String a, String m) async =>
      ImapMailboxState(uidNext: syncedUidNext);
}

class _CountingMailboxRepository extends FakeMailboxRepositoryWithInbox {
  int calls = 0;

  @override
  Future<int> syncMailboxes(String id) async {
    calls++;
    return 1;
  }
}

/// An IMAP client that never touches the network. When [fireOnIdle] is set,
/// it reports that event on its event bus once IDLE has started, like a server
/// pushing an untagged response.
class _FakeIdleClient extends SelectingFakeImapClient {
  _FakeIdleClient({this.fireOnIdle, this.inboxUidNext});

  final imap.ImapEvent Function(imap.ImapClient)? fireOnIdle;

  /// UIDNEXT the SELECT of INBOX reports; null leaves it unreported.
  final int? inboxUidNext;
  bool idleStarted = false;
  bool idleDoneCalled = false;
  bool logoutCalled = false;
  int idleStarts = 0;
  int noops = 0;

  @override
  Future<imap.Mailbox> selectMailboxByPath(
    String path, {
    bool enableCondStore = false,
    imap.QResyncParameters? qresync,
  }) async =>
      fakeMailbox(path)..uidNext = inboxUidNext;

  @override
  Future<void> idleStart() async {
    idleStarted = true;
    idleStarts++;
    final make = fireOnIdle;
    if (make != null) {
      Timer(const Duration(milliseconds: 10), () => eventBus.fire(make(this)));
    }
  }

  @override
  Future<dynamic> idleDone() async => idleDoneCalled = true;

  @override
  Future<imap.Mailbox?> noop() async {
    noops++;
    return null;
  }

  @override
  Future<dynamic> logout() async => logoutCalled = true;
}

/// An IDLE client whose connection breaks once IDLE has started, like the
/// explore fault proxy (#1197): `down`/`reset` close the socket, so
/// enough_mail reports [imap.ImapConnectionLostEvent] ([reportLoss]);
/// `blackhole` keeps it open and silent, so nothing is reported. Either way,
/// as with the real client, nothing sent afterwards is ever answered: DONE,
/// NOOP and LOGOUT hang.
class _BreakingIdleClient extends _FakeIdleClient {
  _BreakingIdleClient({required this.reportLoss});

  final bool reportLoss;
  bool _broken = false;

  @override
  Future<void> idleStart() async {
    await super.idleStart();
    _broken = true;
    if (reportLoss) {
      Timer(
        const Duration(milliseconds: 10),
        () => eventBus.fire(imap.ImapConnectionLostEvent(this)),
      );
    }
  }

  @override
  Future<dynamic> idleDone() =>
      _broken ? _hang(() => idleDoneCalled = true) : super.idleDone();

  @override
  Future<imap.Mailbox?> noop() => _broken ? _hang(() => noops++) : super.noop();

  @override
  Future<dynamic> logout() =>
      _broken ? _hang(() => logoutCalled = true) : super.logout();

  Future<T> _hang<T>(void Function() record) {
    record();
    return Completer<T>().future;
  }
}
