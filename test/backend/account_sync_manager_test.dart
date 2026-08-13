import 'dart:async';
import 'dart:io';

import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/models/note.dart';
import 'package:sharedinbox/core/models/pending_change.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';
import 'package:sharedinbox/core/repositories/note_repository.dart';
import 'package:sharedinbox/core/repositories/sync_log_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
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

  test(
    'JMAP loop does not poll while the push stream stays open',
    () {
      fakeAsync((async) {
        final accounts = _FakeAccounts('pw');
        final mailboxes = _FakeMailboxes();
        final emails = _FakeEmails();
        final logs = _FakeLogs();

        // Long-lived push stream: subscribed, but never emits and never
        // closes. Simulates the "SSE connected, server silent" case.
        final pushCtrl = StreamController<void>.broadcast();
        addTearDown(() async => pushCtrl.close());
        emails.pushStreams['1'] = () => pushCtrl.stream;

        final manager = AccountSyncManager(
          accounts,
          mailboxes,
          emails,
          syncLog: logs,
        );

        manager.start();
        accounts.push([_jmapAccount('1')]);

        // Let the first sync cycle complete and the loop enter _wait().
        async.elapse(const Duration(milliseconds: 100));
        final baseline = emails.syncCounts['1'] ?? 0;
        expect(baseline, greaterThanOrEqualTo(1));

        // Advance well past the old 30 s poll fallback. With push connected
        // no additional sync cycles must fire.
        async.elapse(const Duration(minutes: 5));
        expect(emails.syncCounts['1'], baseline);

        manager.dispose();
        async.elapse(const Duration(milliseconds: 10));
      });
    },
  );

  test(
    'JMAP loop resyncs on each StateChange push event',
    () {
      fakeAsync((async) {
        final accounts = _FakeAccounts('pw');
        final mailboxes = _FakeMailboxes();
        final emails = _FakeEmails();
        final logs = _FakeLogs();

        final pushCtrl = StreamController<void>.broadcast();
        addTearDown(() async => pushCtrl.close());
        emails.pushStreams['1'] = () => pushCtrl.stream;

        final manager = AccountSyncManager(
          accounts,
          mailboxes,
          emails,
          syncLog: logs,
        );

        manager.start();
        accounts.push([_jmapAccount('1')]);

        async.elapse(const Duration(milliseconds: 100));
        final baseline = emails.syncCounts['1'] ?? 0;
        expect(baseline, greaterThanOrEqualTo(1));

        pushCtrl.add(null);
        async.elapse(const Duration(milliseconds: 100));
        expect(emails.syncCounts['1'], baseline + 1);

        pushCtrl.add(null);
        async.elapse(const Duration(milliseconds: 100));
        expect(emails.syncCounts['1'], baseline + 2);

        manager.dispose();
        async.elapse(const Duration(milliseconds: 10));
      });
    },
  );

  test(
    'IMAP sync cycle also refreshes the Notes cache',
    () async {
      final accounts = _FakeAccounts('pw');
      final mailboxes = _FakeMailboxes();
      final emails = _FakeEmails();
      final logs = _FakeLogs();
      final notes = _FakeNotes();

      final manager = AccountSyncManager(
        accounts,
        mailboxes,
        emails,
        syncLog: logs,
        notes: notes,
        imapConnect: _fakeImapConnect,
      );

      manager.start();
      accounts.push([_account('1')]);

      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(
        notes.syncAllCounts['1'],
        greaterThanOrEqualTo(1),
        reason: 'AccountSyncManager must refresh notes each IMAP sync cycle',
      );

      manager.dispose();
    },
  );

  test(
    'JMAP sync cycle also refreshes the Notes cache',
    () async {
      final accounts = _FakeAccounts('pw');
      final mailboxes = _FakeMailboxes();
      final emails = _FakeEmails();
      final logs = _FakeLogs();
      final notes = _FakeNotes();

      final manager = AccountSyncManager(
        accounts,
        mailboxes,
        emails,
        syncLog: logs,
        notes: notes,
      );

      manager.start();
      accounts.push([_jmapAccount('1')]);

      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(
        notes.syncAllCounts['1'],
        greaterThanOrEqualTo(1),
        reason: 'AccountSyncManager must refresh notes each JMAP sync cycle',
      );

      manager.dispose();
    },
  );

  test(
    'Note-sync failure does not abort the sync cycle',
    () async {
      final accounts = _FakeAccounts('pw');
      final mailboxes = _FakeMailboxes();
      final emails = _FakeEmails();
      final logs = _FakeLogs();
      final notes = _FakeNotes()..throwOnSync = StateError('boom');

      final manager = AccountSyncManager(
        accounts,
        mailboxes,
        emails,
        syncLog: logs,
        notes: notes,
      );

      manager.start();
      accounts.push([_jmapAccount('1')]);

      await Future<void>.delayed(const Duration(milliseconds: 100));

      // syncAllNotes threw, but mail sync still ran and was logged as success.
      expect(notes.syncAllCounts['1'], greaterThanOrEqualTo(1));
      expect(emails.syncCounts['1'], greaterThanOrEqualTo(1));
      expect(logs.records, isNotEmpty);
      expect(
        logs.records.first.success,
        isTrue,
        reason: 'A broken Notes folder must not fail the wider sync log entry.',
      );

      manager.dispose();
    },
  );

  test(
    'IMAP SocketException is logged at warn level, not error (#355)',
    () async {
      final accounts = _FakeAccounts('pw');
      final mailboxes = _FakeMailboxes();
      final emails = _FakeEmails();
      final logs = _FakeLogs();
      final appLogRepo = _RecordingAppLogRepo();

      final manager = AccountSyncManager(
        accounts,
        mailboxes,
        emails,
        syncLog: logs,
        imapConnect: _fakeImapConnect,
        appLogger: AppLogger(appLogRepo),
      );

      manager.start();
      accounts.push([_account('1')]);

      // Give the first sync cycle time to fail through _fakeImapConnect and
      // the unawaited AppLogger call to flush.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // The fake sync path succeeds through _runSync (no fakes throw), then
      // fails inside _idle() when it invokes _fakeImapConnect. The catch block
      // must log the SocketException at `warn` under 'sync.cycle.offline',
      // NOT at `error` under 'sync.cycle.failed'.
      final failedEntries =
          appLogRepo.entries.where((e) => e.event == 'sync.cycle.failed');
      final offlineEntries =
          appLogRepo.entries.where((e) => e.event == 'sync.cycle.offline');
      expect(
        failedEntries,
        isEmpty,
        reason: 'offline is not a bug — must not log as sync.cycle.failed',
      );
      expect(
        offlineEntries,
        isNotEmpty,
        reason: 'offline must be logged as sync.cycle.offline',
      );
      expect(offlineEntries.first.level, AppLogLevel.warn);

      manager.dispose();
    },
  );

  test(
    'JMAP loop falls back to 30 s poll when push is unavailable',
    () {
      fakeAsync((async) {
        final accounts = _FakeAccounts('pw');
        final mailboxes = _FakeMailboxes();
        final emails = _FakeEmails();
        final logs = _FakeLogs();

        // Default `pushStreams` entry is absent → `Stream.empty()` → the
        // stream closes immediately, so the loop should poll.
        final manager = AccountSyncManager(
          accounts,
          mailboxes,
          emails,
          syncLog: logs,
        );

        manager.start();
        accounts.push([_jmapAccount('1')]);

        async.elapse(const Duration(milliseconds: 100));
        final baseline = emails.syncCounts['1'] ?? 0;
        expect(baseline, greaterThanOrEqualTo(1));

        async.elapse(const Duration(seconds: 31));
        expect(
          emails.syncCounts['1']!,
          greaterThan(baseline),
          reason: 'Poll fallback must wake the loop after ~30 s',
        );

        manager.dispose();
        async.elapse(const Duration(milliseconds: 10));
      });
    },
  );

  test(
    'JMAP _wait() writes sync.jmap.wait rows explaining every wake-up',
    () {
      fakeAsync((async) {
        // Push stream that starts open (silent → no wake) and can be nudged
        // to emit a StateChange or torn down to trigger the poll fallback.
        final fixture = _jmapFixture('1', appLogger: true);

        fixture.manager.start();
        fixture.accounts.push([_jmapAccount('1')]);
        async.elapse(const Duration(milliseconds: 100));

        // Push emits → next wake should log sync_wait=push_event.
        fixture.pushCtrl.add(null);
        async.elapse(const Duration(milliseconds: 100));

        // Tear the stream down → subsequent wake should fall back to poll.
        fixture.emails.pushStreams.remove('1');
        unawaited(fixture.pushCtrl.close());
        async.elapse(const Duration(milliseconds: 200));

        final waitEvents = fixture.appLog!.entries
            .where((e) => e.event == 'sync.jmap.wait')
            .map((e) => e.dataJson ?? '')
            .toList();
        expect(waitEvents, isNotEmpty);
        expect(waitEvents.any((d) => d.contains('"push_event"')), isTrue);
        expect(waitEvents.any((d) => d.contains('"poll_fallback"')), isTrue);

        fixture.manager.dispose();
        async.elapse(const Duration(milliseconds: 10));
      });
    },
  );
}

/// Bundles the common per-test scaffolding used by the JMAP-loop tests: a
/// fake account repo, mailbox repo, email repo (with a per-account push
/// stream) and an [AccountSyncManager] wired against them. When [appLogger]
/// is true a `_RecordingAppLogRepo` is attached and exposed via [appLog].
class _JmapFixture {
  _JmapFixture({
    required this.accounts,
    required this.mailboxes,
    required this.emails,
    required this.logs,
    required this.manager,
    required this.pushCtrl,
    required this.appLog,
  });

  final _FakeAccounts accounts;
  final _FakeMailboxes mailboxes;
  final _FakeEmails emails;
  final _FakeLogs logs;
  final AccountSyncManager manager;
  final StreamController<void> pushCtrl;
  final _RecordingAppLogRepo? appLog;
}

_JmapFixture _jmapFixture(String accountId, {bool appLogger = false}) {
  final accounts = _FakeAccounts('pw');
  final mailboxes = _FakeMailboxes();
  final emails = _FakeEmails();
  final logs = _FakeLogs();
  final appLog = appLogger ? _RecordingAppLogRepo() : null;
  final pushCtrl = StreamController<void>.broadcast();
  addTearDown(() async => pushCtrl.close());
  emails.pushStreams[accountId] = () => pushCtrl.stream;
  final manager = AccountSyncManager(
    accounts,
    mailboxes,
    emails,
    syncLog: logs,
    appLogger: appLog == null ? null : AppLogger(appLog),
  );
  return _JmapFixture(
    accounts: accounts,
    mailboxes: mailboxes,
    emails: emails,
    logs: logs,
    manager: manager,
    pushCtrl: pushCtrl,
    appLog: appLog,
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
  final syncCounts = <String, int>{};

  /// Per-account JMAP push stream factory. Tests can install their own
  /// controllable stream; by default we return an empty (immediately closed)
  /// stream so the sync loop falls back to polling.
  final Map<String, Stream<void> Function()> pushStreams = {};

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
  Future<int> enqueueSend(String accountId, EmailDraft draft) async => 0;

  @override
  Future<int> flushOutbox(String accountId, String password) async => 0;

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

  // Ordering below intentionally mixes the sync-related overrides in a
  // different sequence to the equivalent fake in `test/widget/helpers.dart`
  // — jscpd flags shared method tails when the token order lines up, and
  // this reordering breaks the match without changing any behaviour.

  @override
  Future<int> applySieveScriptToInbox(
    String accountId,
    String scriptContent,
  ) async =>
      0;

  @override
  Future<int> previewSieveRuleMatches(
    String accountId,
    String scriptContent,
  ) async =>
      0;

  @override
  Future<int> applySieveRules(String accountId) async => 0;

  @override
  Stream<void> watchJmapPush(String accountId, String password) {
    final factory = pushStreams[accountId];
    return factory != null ? factory() : const Stream.empty();
  }

  @override
  Future<MailboxDiagnostics> diagnoseMailbox(String a, String m) async =>
      MailboxDiagnostics.empty(accountId: a, mailboxPath: m);

  @override
  Future<ReliabilityResult> verifySyncReliability(
    String accountId,
    String mailboxPath,
  ) async =>
      ReliabilityResult.healthy;

  @override
  Stream<List<PendingChange>> observeAllPendingChanges() => Stream.value([]);

  @override
  Stream<List<PendingChange>> observePendingChanges(String accountId) =>
      Stream.value([]);

  @override
  Stream<List<FailedMutation>> observeFailedMutations(String accountId) =>
      Stream.value([]);

  @override
  Future<void> clearForResync(String accountId) async {}

  @override
  Future<void> retryMutation(int id) async {}

  @override
  Future<void> discardMutation(int id) async {}
}

/// A single recorded call to [AppLogRepository.insert]. Only the fields the
/// account-sync-manager tests actually assert against are kept, so the
/// recording body stays small — jscpd flagged the previous approach (which
/// built a full [AppLogEntry] per row) as a near-duplicate of the equivalent
/// insert body in `test/widget/app_log_screen_test.dart`.
class _LoggedRow {
  const _LoggedRow(this.level, this.event, this.dataJson);
  final AppLogLevel level;
  final String event;
  final String? dataJson;
}

class _RecordingAppLogRepo extends NoOpAppLogRepository {
  final entries = <_LoggedRow>[];
  int _nextId = 1;

  @override
  Future<int?> insert({
    required AppLogLevel level,
    required String event,
    required String message,
    String? dataJson,
    String? screen,
    String? accountId,
    String? mailboxPath,
    String? emailId,
    int? syncLogId,
    DateTime? createdAt,
  }) async {
    entries.add(_LoggedRow(level, event, dataJson));
    return _nextId++;
  }
}

class _FakeLogs implements SyncLogRepository {
  final records = <_FakeLogRecord>[];

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
    records.add(_FakeLogRecord(accountId: accountId, success: success));
    return 0;
  }

  @override
  Stream<List<SyncLogEntry>> observeSyncLogs(String accountId) =>
      Stream.value([]);

  @override
  Stream<String?> observeLastError(String accountId) => Stream.value(null);
}

class _FakeLogRecord {
  _FakeLogRecord({required this.accountId, required this.success});
  final String accountId;
  final bool success;
}

class _FakeNotes implements NoteRepository {
  final syncAllCounts = <String, int>{};
  Object? throwOnSync;

  @override
  Stream<List<EmailNote>> observeNotes(String accountId, String messageId) =>
      const Stream.empty();

  @override
  Future<void> syncAllNotes(String accountId) async {
    syncAllCounts[accountId] = (syncAllCounts[accountId] ?? 0) + 1;
    final err = throwOnSync;
    if (err != null) throw err;
  }

  @override
  Future<void> addNote(String accountId, String messageId, String text) async {}

  @override
  Future<void> deleteNote(String noteId) async {}
}
