import 'dart:async';
import 'dart:io' show HandshakeException, HttpException, SocketException;

import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart' show SyncEmailsResult;
import 'package:sharedinbox/core/models/mailbox.dart'
    show Mailbox, isDuplicateOfOtherFolders;
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/repositories/draft_repository.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';
import 'package:sharedinbox/core/repositories/note_repository.dart';
import 'package:sharedinbox/core/repositories/sync_log_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/core/utils/logger.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart'
    show ImapConnectFn, connectImap, verboseLogKey;
import 'package:sharedinbox/data/imap/tls_error.dart' show isTlsConfigError;

/// True when [e] means the server never answered in time, as opposed to never
/// being reached at all. Kept separate from [_isUnreachableError] because the
/// two have different causes and different fixes — see [syncErrorMessage].
bool _isTimeoutError(Object e) => e is TimeoutException;

/// True when [e] is a routine "device is offline / cannot reach the host"
/// failure: DNS, connect, TLS.
bool _isUnreachableError(Object e) =>
    e is SocketException || e is HttpException || e is HandshakeException;

/// True when [e] is a routine "device is offline / network hiccup" failure.
/// Sync failures of this shape are expected on mobile and must not be logged
/// at `error` level (which would flood the app log with red entries and
/// suggest a bug where there is none — regression #355).
bool _isTransientNetworkError(Object e) =>
    _isUnreachableError(e) || _isTimeoutError(e);

/// Message shown in the Sync Entry's error field. For a transient network
/// failure the raw exception (e.g. "SocketException: Failed host lookup:
/// 'imap.gmail.com' ... errno = 7", #609) reads like a bug to users whose
/// connection is fine, so we show a friendly hint instead. The raw exception
/// and stack trace are still recorded in the app log for debugging.
///
/// A timeout gets its own wording. It used to share the "could not reach the
/// mail server — temporary network or DNS problem" text, which is actively
/// misleading: the server had been reached, it just had not finished the
/// request. That message sent a real investigation at DNS while the actual
/// cause was a request the client had made too large to answer in time
/// (issue #967). Report what happened — that the server was slow — so the
/// next report points at the request, not at the network.
///
/// Deliberately short and free of the words "network" and "DNS": it is
/// rendered in a two-line banner (`EmailListScreen`) that ellipses anything
/// longer, and the half that would be cut is the actionable half.
@visibleForTesting
String syncErrorMessage(Object e) {
  if (_isTimeoutError(e)) {
    return 'The mail server was reached but did not answer in time — the '
        'request took too long. Will retry automatically.';
  }
  if (_isUnreachableError(e)) {
    return 'Could not reach the mail server — temporary network or DNS '
        'problem. Will retry automatically.';
  }
  return e.toString();
}

/// Invoked once per completed sync cycle with the account id, after new mail
/// has been stored locally. Wired to the notification dispatcher, which decides
/// whether any of the account's rules should pop up.
typedef OnNewMailCallback = Future<void> Function(String accountId);

/// Coarse-grained phase of a [AccountSyncManager.forceResync] run. The UI
/// uses this to pick the right message/spinner while the operation runs.
enum ForceResyncPhase {
  /// Deleting cached email/mailbox rows and resetting sync checkpoints.
  clearing,

  /// Re-syncing the mailbox list from the server.
  syncingMailboxes,

  /// Iterating mailboxes and re-syncing their emails.
  syncingEmails,

  /// All mailboxes finished without error.
  complete,

  /// Terminal state — some part of the resync failed. Cached bodies remain
  /// intact so nothing has to be re-downloaded on the next attempt.
  failed,
}

/// A single progress snapshot emitted by [AccountSyncManager.forceResync].
///
/// Snapshots are cumulative: [mailboxStats], [totalFetched] and [totalSkipped]
/// grow as mailboxes finish. A UI can safely render just the latest snapshot
/// without remembering earlier ones.
class ForceResyncProgress {
  const ForceResyncProgress({
    required this.phase,
    this.currentMailboxIndex = 0,
    this.totalMailboxes = 0,
    this.currentMailboxName,
    this.mailboxStats = const [],
    this.totalFetched = 0,
    this.totalSkipped = 0,
    this.error,
  });

  final ForceResyncPhase phase;

  /// Zero-based index of the mailbox currently being processed. Equals
  /// [totalMailboxes] once every mailbox has finished.
  final int currentMailboxIndex;
  final int totalMailboxes;
  final String? currentMailboxName;

  /// Per-mailbox results collected so far.
  final List<MailboxSyncStats> mailboxStats;

  final int totalFetched;
  final int totalSkipped;

  /// Combined error text, one line per failing mailbox. Non-null when
  /// [phase] is [ForceResyncPhase.failed]; may still be non-null on
  /// [ForceResyncPhase.complete] never — completion implies no errors.
  final String? error;

  bool get isTerminal =>
      phase == ForceResyncPhase.complete || phase == ForceResyncPhase.failed;
}

/// Manages background sync for all accounts.
///
/// IMAP accounts get an IDLE-based sync loop (_AccountSync).
/// JMAP accounts get a polling-based sync loop (_JmapAccountSync).
class AccountSyncManager {
  AccountSyncManager(
    this._accounts,
    this._mailboxes,
    this._emails, {
    ImapConnectFn imapConnect = connectImap,
    SyncLogRepository syncLog = const NoOpSyncLogRepository(),
    AppLogger? appLogger,
    DraftRepository? drafts,
    NoteRepository? notes,
    OnNewMailCallback? onNewMail,
  })  : _imapConnect = imapConnect,
        _syncLog = syncLog,
        _appLogger = appLogger ?? AppLogger(const NoOpAppLogRepository()),
        _drafts = drafts,
        _notes = notes,
        _onNewMail = onNewMail;

  final AccountRepository _accounts;
  final MailboxRepository _mailboxes;
  final EmailRepository _emails;
  final ImapConnectFn _imapConnect;
  final SyncLogRepository _syncLog;
  final AppLogger _appLogger;
  final DraftRepository? _drafts;
  final NoteRepository? _notes;
  final OnNewMailCallback? _onNewMail;

  final Map<String, _SyncLoop> _active = {};
  StreamSubscription<List<Account>>? _accountsSub;
  StreamSubscription<String>? _onChangesSub;

  final _syncPhaseCtrl = StreamController<(String, bool)>.broadcast();

  /// Emits `true` when [accountId] starts syncing, `false` when it stops.
  Stream<bool> watchSyncing(String accountId) =>
      _syncPhaseCtrl.stream.where((e) => e.$1 == accountId).map((e) => e.$2);

  void _emitSyncing(String accountId, {required bool syncing}) {
    if (!_syncPhaseCtrl.isClosed) _syncPhaseCtrl.add((accountId, syncing));
  }

  void start() {
    _onChangesSub = _emails.onChangesQueued.listen((accountId) {
      _active[accountId]?.kick();
    });

    _accountsSub = _accounts.observeAccounts().listen((accounts) {
      final currentIds = accounts.map((a) => a.id).toSet();

      for (final account in accounts) {
        if (_active.containsKey(account.id)) continue;
        final id = account.id;
        final loop = switch (account.type) {
          AccountType.imap => _AccountSync(
              account,
              _accounts,
              _mailboxes,
              _emails,
              _imapConnect,
              _syncLog,
              _appLogger,
              _drafts,
              _notes,
              _onNewMail,
              onSyncStart: () => _emitSyncing(id, syncing: true),
              onSyncEnd: () => _emitSyncing(id, syncing: false),
            ),
          AccountType.jmap => _JmapAccountSync(
              account,
              _mailboxes,
              _emails,
              _accounts,
              _syncLog,
              _appLogger,
              _drafts,
              _notes,
              _onNewMail,
              onSyncStart: () => _emitSyncing(id, syncing: true),
              onSyncEnd: () => _emitSyncing(id, syncing: false),
            ),
        };
        _active[account.id] = loop;
        loop.start();
      }

      for (final id in _active.keys.toList()) {
        if (!currentIds.contains(id)) {
          _active.remove(id)?.stop();
        }
      }
    });
  }

  void dispose() {
    unawaited(_accountsSub?.cancel());
    unawaited(_onChangesSub?.cancel());
    for (final s in _active.values) {
      s.stop();
    }
    _active.clear();
    unawaited(_syncPhaseCtrl.close());
  }

  /// Wakes the given account's sync loop so a new sync cycle (which drains the
  /// send queue) starts immediately. Returns `true` only if a live loop was
  /// actually woken; `false` if the account has no loop or its loop has
  /// stopped. Used by the Retry button on the sent queue so we can tell the
  /// user what actually happened instead of silently faking success.
  ///
  /// A loop that stopped on a permanent error (bad credentials, TLS, or a
  /// missing platform channel — see #200) stays registered in [_active] but is
  /// no longer running; kicking it does nothing, which is exactly why the
  /// Retry snackbar used to claim success while nothing ran and no log entry
  /// appeared (#501). We now return `false` in that case (the UI reports that
  /// sync is stopped) and do *not* restart the loop — a permanently-stopped
  /// loop must stay stopped rather than retry indefinitely. Every outcome is
  /// written to the application log so pressing Retry always leaves a trace.
  bool syncNow(String accountId) {
    final loop = _active[accountId];
    if (loop == null) {
      unawaited(
        _appLogger.warn(
          'sync.now.no_loop',
          'Cannot sync now: no sync loop is registered for this account.',
          accountId: accountId,
        ),
      );
      return false;
    }
    if (!loop.isRunning) {
      unawaited(
        _appLogger.warn(
          'sync.now.stopped',
          'Cannot sync now: this account\'s sync loop has stopped '
              '(check the account credentials).',
          accountId: accountId,
        ),
      );
      return false;
    }
    unawaited(
      _appLogger.info(
        'sync.now.kick',
        'Waking sync loop to send queued messages (manual retry).',
        accountId: accountId,
      ),
    );
    loop.kick();
    return true;
  }

  /// Wakes the idle/wait phase of every active account loop. Used by the
  /// UnifiedPush handler to trigger an immediate fetch on all accounts in
  /// response to an opaque push wake-up.
  void syncAll() {
    for (final loop in _active.values) {
      loop.kick();
    }
  }

  /// Clears all locally-cached emails and mailboxes for [accountId], then
  /// re-syncs mailboxes and every mailbox's emails from the server. Cached
  /// email bodies and attachments are preserved (see `clearForResync` on the
  /// email repository) so already-downloaded content is not fetched again.
  ///
  /// Returns a single-subscription [Stream] that emits [ForceResyncProgress]
  /// snapshots as the work advances (one per phase change, plus one per
  /// mailbox). The stream closes right after the final snapshot whose
  /// [ForceResyncProgress.isTerminal] is `true`. The regular background sync
  /// loop for [accountId] is stopped for the duration of the resync and
  /// restarted once the stream closes.
  Stream<ForceResyncProgress> forceResync(String accountId) {
    final ctrl = StreamController<ForceResyncProgress>();
    ctrl.onListen = () => unawaited(_runForceResync(accountId, ctrl));
    return ctrl.stream;
  }

  /// Flushes queued local mutations to the server before a force re-sync wipes
  /// the local cache. Best-effort: a failure (typically offline) leaves the
  /// changes queued — `clearForResync` preserves them — so they retry on the
  /// next successful sync instead of being lost (#558).
  Future<void> _flushBeforeResync(String accountId) async {
    try {
      final password = await _accounts.getPassword(accountId);
      await _emails.flushPendingChanges(accountId, password);
    } catch (e, st) {
      log('forceResync: flushPendingChanges failed', error: e, stackTrace: st);
    }
  }

  Future<void> _runForceResync(
    String accountId,
    StreamController<ForceResyncProgress> ctrl,
  ) async {
    final stats = <MailboxSyncStats>[];
    final errors = <String>[];
    var totalFetched = 0;
    var totalSkipped = 0;

    void emit(ForceResyncProgress p) {
      if (!ctrl.isClosed) ctrl.add(p);
    }

    Account? account;
    try {
      _active.remove(accountId)?.stop();
      _emitSyncing(accountId, syncing: true);

      emit(const ForceResyncProgress(phase: ForceResyncPhase.clearing));

      // Push any un-pushed local mutations (e.g. a just-starred mail) to the
      // server before wiping the cache — otherwise the re-fetch below would
      // overwrite the optimistic local state with stale server truth and the
      // change would be lost (#558).
      await _flushBeforeResync(accountId);
      await _emails.clearForResync(accountId);
      await _mailboxes.clearForResync(accountId);

      final accounts = await _accounts.observeAccounts().first;
      account = accounts.cast<Account?>().firstWhere(
            (a) => a?.id == accountId,
            orElse: () => null,
          );
      if (account == null) {
        emit(
          const ForceResyncProgress(
            phase: ForceResyncPhase.failed,
            error: 'Account not found',
          ),
        );
        return;
      }

      emit(
        const ForceResyncProgress(phase: ForceResyncPhase.syncingMailboxes),
      );
      await _mailboxes.syncMailboxes(accountId);

      final mailboxes = await _mailboxes.observeMailboxes(accountId).first;
      final total = mailboxes.length;

      for (var i = 0; i < mailboxes.length; i++) {
        final mailbox = mailboxes[i];
        // Skip folders that just duplicate other folders (Gmail's "All Mail"),
        // otherwise every message is downloaded twice (#691).
        if (isDuplicateOfOtherFolders(mailbox)) continue;
        emit(
          ForceResyncProgress(
            phase: ForceResyncPhase.syncingEmails,
            currentMailboxIndex: i,
            totalMailboxes: total,
            currentMailboxName: mailbox.name,
            mailboxStats: List.of(stats),
            totalFetched: totalFetched,
            totalSkipped: totalSkipped,
          ),
        );
        final start = DateTime.now();
        try {
          final r = await _emails.syncEmails(accountId, mailbox.path);
          stats.add(
            MailboxSyncStats(
              mailboxPath: mailbox.path,
              mailboxName: mailbox.name,
              fetched: r.fetched,
              skipped: r.skipped,
              bytesTransferred: r.bytesTransferred,
              duration: DateTime.now().difference(start),
            ),
          );
          totalFetched += r.fetched;
          totalSkipped += r.skipped;
        } catch (e, st) {
          log(
            'forceResync: syncEmails failed for ${mailbox.path}',
            error: e,
            stackTrace: st,
          );
          errors.add('${mailbox.name}: $e');
          stats.add(
            MailboxSyncStats(
              mailboxPath: mailbox.path,
              mailboxName: mailbox.name,
              fetched: 0,
              skipped: 0,
              bytesTransferred: 0,
              duration: DateTime.now().difference(start),
            ),
          );
        }
      }

      emit(
        ForceResyncProgress(
          phase: errors.isEmpty
              ? ForceResyncPhase.complete
              : ForceResyncPhase.failed,
          currentMailboxIndex: total,
          totalMailboxes: total,
          mailboxStats: List.of(stats),
          totalFetched: totalFetched,
          totalSkipped: totalSkipped,
          error: errors.isEmpty ? null : errors.join('\n'),
        ),
      );
    } catch (e, st) {
      log('forceResync failed', error: e, stackTrace: st);
      emit(
        ForceResyncProgress(
          phase: ForceResyncPhase.failed,
          mailboxStats: List.of(stats),
          totalFetched: totalFetched,
          totalSkipped: totalSkipped,
          error: e.toString(),
        ),
      );
    } finally {
      _emitSyncing(accountId, syncing: false);
      // Bring the account's background loop back so IDLE/push resumes even
      // when the resync itself failed. Skip only if the account vanished
      // mid-resync.
      if (account != null) _restartLoop(account);
      await ctrl.close();
    }
  }

  /// Clears one mailbox's local cache and re-syncs only that mailbox from the
  /// server, leaving every other folder untouched. Cached email bodies and
  /// attachments are preserved (see `clearMailboxForResync` on the email
  /// repository) so already-downloaded content is not fetched again.
  ///
  /// Returns a single-subscription [Stream] emitting [ForceResyncProgress]
  /// snapshots, closing right after the final terminal snapshot. As with
  /// [forceResync], the account's background sync loop is stopped for the
  /// duration and restarted once the stream closes.
  Stream<ForceResyncProgress> forceResyncMailbox(
    String accountId,
    String mailboxPath,
  ) {
    final ctrl = StreamController<ForceResyncProgress>();
    ctrl.onListen =
        () => unawaited(_runForceResyncMailbox(accountId, mailboxPath, ctrl));
    return ctrl.stream;
  }

  Future<void> _runForceResyncMailbox(
    String accountId,
    String mailboxPath,
    StreamController<ForceResyncProgress> ctrl,
  ) async {
    void emit(ForceResyncProgress p) {
      if (!ctrl.isClosed) ctrl.add(p);
    }

    Account? account;
    try {
      _active.remove(accountId)?.stop();
      _emitSyncing(accountId, syncing: true);

      final accounts = await _accounts.observeAccounts().first;
      account = accounts.cast<Account?>().firstWhere(
            (a) => a?.id == accountId,
            orElse: () => null,
          );
      if (account == null) {
        emit(
          const ForceResyncProgress(
            phase: ForceResyncPhase.failed,
            error: 'Account not found',
          ),
        );
        return;
      }

      final mailboxes = await _mailboxes.observeMailboxes(accountId).first;
      final matches = mailboxes.where((m) => m.path == mailboxPath);
      if (matches.isEmpty) {
        emit(
          const ForceResyncProgress(
            phase: ForceResyncPhase.failed,
            error: 'Folder not found',
          ),
        );
        return;
      }
      final mailbox = matches.first;

      emit(const ForceResyncProgress(phase: ForceResyncPhase.clearing));
      // Push un-pushed local mutations before wiping the cache (see #558).
      await _flushBeforeResync(accountId);
      await _emails.clearMailboxForResync(accountId, mailboxPath);

      emit(
        ForceResyncProgress(
          phase: ForceResyncPhase.syncingEmails,
          totalMailboxes: 1,
          currentMailboxName: mailbox.name,
        ),
      );

      final start = DateTime.now();
      try {
        final r = await _emails.syncEmails(accountId, mailboxPath);
        emit(
          ForceResyncProgress(
            phase: ForceResyncPhase.complete,
            currentMailboxIndex: 1,
            totalMailboxes: 1,
            mailboxStats: [
              MailboxSyncStats(
                mailboxPath: mailboxPath,
                mailboxName: mailbox.name,
                fetched: r.fetched,
                skipped: r.skipped,
                bytesTransferred: r.bytesTransferred,
                duration: DateTime.now().difference(start),
              ),
            ],
            totalFetched: r.fetched,
            totalSkipped: r.skipped,
          ),
        );
      } catch (e, st) {
        log(
          'forceResyncMailbox: syncEmails failed for $mailboxPath',
          error: e,
          stackTrace: st,
        );
        emit(
          ForceResyncProgress(
            phase: ForceResyncPhase.failed,
            currentMailboxIndex: 1,
            totalMailboxes: 1,
            mailboxStats: [
              MailboxSyncStats(
                mailboxPath: mailboxPath,
                mailboxName: mailbox.name,
                fetched: 0,
                skipped: 0,
                bytesTransferred: 0,
                duration: DateTime.now().difference(start),
              ),
            ],
            error: '${mailbox.name}: $e',
          ),
        );
      }
    } catch (e, st) {
      log('forceResyncMailbox failed', error: e, stackTrace: st);
      emit(
        ForceResyncProgress(
          phase: ForceResyncPhase.failed,
          error: e.toString(),
        ),
      );
    } finally {
      _emitSyncing(accountId, syncing: false);
      if (account != null) _restartLoop(account);
      await ctrl.close();
    }
  }

  /// Rebuilds and starts the background sync loop for [account], registering it
  /// in [_active]. Used after a force-resync run releases the account.
  void _restartLoop(Account account) {
    final accountId = account.id;
    final loop = switch (account.type) {
      AccountType.imap => _AccountSync(
          account,
          _accounts,
          _mailboxes,
          _emails,
          _imapConnect,
          _syncLog,
          _appLogger,
          _drafts,
          _notes,
          _onNewMail,
          onSyncStart: () => _emitSyncing(accountId, syncing: true),
          onSyncEnd: () => _emitSyncing(accountId, syncing: false),
        ),
      AccountType.jmap => _JmapAccountSync(
          account,
          _mailboxes,
          _emails,
          _accounts,
          _syncLog,
          _appLogger,
          _drafts,
          _notes,
          _onNewMail,
          onSyncStart: () => _emitSyncing(accountId, syncing: true),
          onSyncEnd: () => _emitSyncing(accountId, syncing: false),
        ),
    };
    _active[accountId] = loop;
    loop.start();
  }
}

// ── Shared interface ──────────────────────────────────────────────────────────

abstract class _SyncLoop {
  void start();
  void stop();
  void kick();

  /// Whether the loop is currently running. A loop that stopped on a permanent
  /// error stays registered but reports `false` here so [AccountSyncManager.
  /// syncNow] can restart it instead of kicking a dead loop.
  bool get isRunning;
}

// ── IMAP ──────────────────────────────────────────────────────────────────────

class _AccountSync implements _SyncLoop {
  _AccountSync(
    this.account,
    this._accounts,
    this._mailboxes,
    this._emails,
    this._imapConnect,
    this._syncLog,
    this._appLogger,
    this._drafts,
    this._notes,
    this._onNewMail, {
    void Function()? onSyncStart,
    void Function()? onSyncEnd,
  })  : _onSyncStart = onSyncStart,
        _onSyncEnd = onSyncEnd;

  final Account account;
  final AccountRepository _accounts;
  final MailboxRepository _mailboxes;
  final EmailRepository _emails;
  final ImapConnectFn _imapConnect;
  final SyncLogRepository _syncLog;
  final AppLogger _appLogger;
  final DraftRepository? _drafts;
  final NoteRepository? _notes;
  final OnNewMailCallback? _onNewMail;
  final void Function()? _onSyncStart;
  final void Function()? _onSyncEnd;

  imap.ImapClient? _idleClient;
  bool _running = false;
  int _backoffSeconds = 5;
  Completer<void>? _stopSignal;
  Timer? _waitTimer;

  /// Credential-redacted protocol trace captured for the most recent failed
  /// sync attempt, so the error entry can surface which command failed even
  /// when the account did not have verbose logging enabled. Cleared at the
  /// start of every sync cycle and read by the error handler in [_loop].
  String? _lastFailureLog;

  @override
  bool get isRunning => _running;

  @override
  void start() {
    _running = true;
    unawaited(_loop());
  }

  @override
  void stop() {
    _running = false;
    if (_stopSignal != null && !_stopSignal!.isCompleted) {
      _stopSignal!.complete();
    }
    _idleClient?.logout().ignore();
    _idleClient = null;
  }

  @override
  void kick() {
    if (_stopSignal != null && !_stopSignal!.isCompleted) {
      _stopSignal!.complete();
    }
  }

  Future<void> _loop() async {
    while (_running) {
      final startedAt = DateTime.now();
      _onSyncStart?.call();
      _lastFailureLog = null;
      try {
        final (_SyncStats stats, String? capturedLog) = await _runSync(
          account.verbose,
        );
        final syncLogId = await _syncLog.log(
          accountId: account.id,
          success: true,
          protocol: 'imap',
          emailsFetched: stats.emailsFetched,
          emailsSkipped: stats.emailsSkipped,
          mailboxesSynced: stats.mailboxesSynced,
          pendingFlushed: stats.pendingFlushed,
          bytesTransferred: stats.bytesTransferred,
          startedAt: startedAt,
          finishedAt: DateTime.now(),
          mailboxStats: stats.mailboxStats,
          protocolLog: capturedLog,
        );
        final fetchedFolders = _fetchedFoldersLabel(stats.mailboxStats);
        unawaited(
          _appLogger.info(
            'sync.cycle.complete',
            'IMAP sync ok: ${stats.emailsFetched} new, '
                '${stats.mailboxesSynced} mailboxes'
                '${fetchedFolders != null ? ' — new mail in $fetchedFolders' : ''}',
            accountId: account.id,
            syncLogId: syncLogId == 0 ? null : syncLogId,
            data: {
              'protocol': 'imap',
              'account': account.email,
              'host': account.imapHost,
              'durationMs': DateTime.now().difference(startedAt).inMilliseconds,
              'emailsFetched': stats.emailsFetched,
              'emailsSkipped': stats.emailsSkipped,
              'mailboxesSynced': stats.mailboxesSynced,
              'pendingFlushed': stats.pendingFlushed,
              'bytesTransferred': stats.bytesTransferred,
              'folders': _folderSyncData(stats.mailboxStats),
            },
          ),
        );
        _backoffSeconds = 5;
        _onSyncEnd?.call();
        await _idle();
      } catch (e, st) {
        _onSyncEnd?.call();
        // A cycle that finished most of its folders still did real work. Log
        // what landed rather than the hardcoded zeros that made the Sync Entry
        // read as "nothing happened" (#967), and classify the cycle by the
        // underlying failure rather than by the wrapper.
        final failure = _classifyCycleFailure(
          e,
          st,
          isPermanent: _isPermanentError,
          protocolLabel: 'IMAP',
        );
        final stats = failure.stats;
        final isPermanent = failure.isPermanent;
        var syncLogId = 0;
        try {
          syncLogId = await _syncLog.log(
            accountId: account.id,
            success: false,
            errorMessage: failure.errorMessage,
            stackTrace: failure.stackTrace.toString(),
            isPermanent: isPermanent,
            protocol: 'imap',
            emailsFetched: stats?.emailsFetched ?? 0,
            emailsSkipped: stats?.emailsSkipped ?? 0,
            mailboxesSynced: stats?.mailboxesSynced ?? 0,
            pendingFlushed: stats?.pendingFlushed ?? 0,
            bytesTransferred: stats?.bytesTransferred ?? 0,
            startedAt: startedAt,
            finishedAt: DateTime.now(),
            mailboxStats: stats?.mailboxStats ?? const [],
            protocolLog: _lastFailureLog,
          );
        } catch (logErr) {
          log('Failed to write IMAP sync log entry: $logErr');
        }
        unawaited(
          failure.logAtWarn
              ? _appLogger.warn(
                  failure.event,
                  failure.summary,
                  accountId: account.id,
                  syncLogId: syncLogId == 0 ? null : syncLogId,
                  data: {'protocol': 'imap', 'permanent': isPermanent},
                  error: failure.cause,
                  stack: failure.stackTrace,
                )
              : _appLogger.error(
                  failure.event,
                  failure.summary,
                  accountId: account.id,
                  syncLogId: syncLogId == 0 ? null : syncLogId,
                  data: {'protocol': 'imap', 'permanent': isPermanent},
                  error: failure.cause,
                  stack: failure.stackTrace,
                ),
        );

        if (isPermanent) {
          log(
            'Permanent error for ${account.email}, stopping sync loop.',
            error: e,
            stackTrace: st,
          );
          _running = false;
          break;
        }

        log(
          'Sync failed for ${account.email}, retrying in ${_backoffSeconds}s',
          error: e,
        );
        await _waitSeconds(_backoffSeconds);
        _backoffSeconds = (_backoffSeconds * 2).clamp(5, 900); // max 15m
      }
    }
  }

  bool _isPermanentError(Object e) {
    if (isTlsConfigError(e)) return true;
    if (e is MissingPluginException) return true;
    final s = e.toString().toLowerCase();
    // enough_mail doesn't always have typed exceptions for auth, so we check strings.
    return s.contains('invalid credentials') ||
        s.contains('authentication failed') ||
        s.contains('login failed');
  }

  Future<void> _waitSeconds(int seconds) async {
    if (!_running) return;
    _stopSignal = Completer<void>();
    _waitTimer = Timer(Duration(seconds: seconds), () {
      if (!_stopSignal!.isCompleted) _stopSignal!.complete();
    });
    try {
      await _stopSignal!.future;
    } finally {
      _waitTimer?.cancel();
      _waitTimer = null;
      _stopSignal = null;
    }
  }

  Future<(_SyncStats, String?)> _runSync(bool verbose) async {
    // Always capture the IMAP protocol trace so a failing sync can surface
    // which command the server rejected — even for accounts that never
    // enabled verbose logging (issue #608). The buffer is bounded to keep
    // memory (and any captured message content) small; on success it is
    // discarded unless the account opted into verbose logging.
    final buffer = _BoundedProtocolLog();
    try {
      final stats = await runZoned(
        _sync,
        zoneValues: {verboseLogKey: buffer},
        zoneSpecification: ZoneSpecification(
          print: (_, __, ___, line) => buffer.writeln(line),
        ),
      );
      return (stats, verbose ? _redactCredentials(buffer.toString()) : null);
    } catch (_) {
      _lastFailureLog =
          buffer.isEmpty ? null : _redactCredentials(buffer.toString());
      rethrow;
    }
  }

  Future<_SyncStats> _sync() async {
    final password = await _accounts.getPassword(account.id);

    await _drafts?.syncDrafts(account.id);

    // Check for expired snoozes and move them back to Inbox before syncing.
    await _emails.wakeUpEmails(account.id);

    final pendingFlushed = await _emails.flushPendingChanges(
      account.id,
      password,
    );
    // Drain any messages that were queued offline. Failures stay in the queue
    // and will be retried on the next sync (transient) or surfaced to the user
    // as failed-state rows (permanent — see PermanentSendException).
    await _emails.flushOutbox(account.id, password);
    final mailboxesSynced = await _mailboxes.syncMailboxes(account.id);
    final mailboxes = await _mailboxes.observeMailboxes(account.id).first;
    final folders = await _syncFolders(
      mailboxes: mailboxes,
      accountId: account.id,
      syncEmails: _emails.syncEmails,
      isRunning: () => _running,
    );
    // The loop now reaches this even after a folder failed, so a Sieve failure
    // must not be the exception that propagates — it would discard every
    // per-folder failure the loop just collected (#967). Hold it until the
    // folder failures have had their say.
    Object? sieveError;
    StackTrace? sieveStack;
    try {
      await _emails.applySieveRules(account.id);
    } catch (e, st) {
      sieveError = e;
      sieveStack = st;
    }
    // Fire notifications for any newly stored mail that matches the account's
    // rules. Runs unawaited so a notification failure never aborts the cycle.
    unawaited(_onNewMail?.call(account.id));
    await _syncNotesQuietly();
    final stats = _SyncStats(
      emailsFetched: folders.emailResult.fetched,
      emailsSkipped: folders.emailResult.skipped,
      mailboxesSynced: mailboxesSynced,
      pendingFlushed: pendingFlushed,
      bytesTransferred: folders.emailResult.bytesTransferred,
      mailboxStats: folders.mailboxStats,
    );
    if (folders.failures.isEmpty) {
      if (sieveError != null) {
        Error.throwWithStackTrace(sieveError, sieveStack!);
      }
      return stats;
    }
    throw _PartialSyncException(stats: stats, folders: folders);
  }

  /// Refreshes the per-account Notes cache. A broken Notes folder must not
  /// stop mail sync, so failures are logged and swallowed.
  Future<void> _syncNotesQuietly() async {
    final notes = _notes;
    if (notes == null) return;
    try {
      await notes.syncAllNotes(account.id);
    } catch (e, st) {
      unawaited(
        _appLogger.warn(
          'sync.notes.failed',
          'Note sync failed: $e',
          accountId: account.id,
          error: e,
          stack: st,
        ),
      );
    }
  }

  Future<void> _idle() async {
    if (!_running) return;
    _stopSignal = Completer<void>();
    final password = await _accounts.getPassword(account.id);
    final username =
        account.username.isNotEmpty ? account.username : account.email;
    final client = await _imapConnect(account, username, password);
    _idleClient = client;
    try {
      await client.selectMailboxByPath('INBOX');

      final newMessageCompleter = Completer<void>();

      final sub = client.eventBus
          .on<imap.ImapEvent>()
          .where(
            (e) =>
                e is imap.ImapMessagesExistEvent || e is imap.ImapExpungeEvent,
          )
          .listen((e) {
        if (!newMessageCompleter.isCompleted) newMessageCompleter.complete();
      });

      await client.idleStart();

      // Cap IDLE at 25 minutes (RFC 2177). Also wakes up when stop() is
      // called or a new message / expunge event arrives.
      final idleTimer = Timer(const Duration(minutes: 25), () {
        if (_stopSignal != null && !_stopSignal!.isCompleted) {
          _stopSignal!.complete();
        }
      });
      try {
        await Future.any([newMessageCompleter.future, _stopSignal!.future]);
      } finally {
        idleTimer.cancel();
      }

      await client.idleDone();
      await sub.cancel();

      // New mail detected during IDLE wakes the loop, which runs a full sync
      // (storing the messages) and then fires notifications from _sync(). We do
      // not notify here because the envelopes are not fetched yet.
    } finally {
      await client.logout();
      _idleClient = null;
      _stopSignal = null;
    }
  }
}

// ── JMAP ──────────────────────────────────────────────────────────────────────

class _JmapAccountSync implements _SyncLoop {
  _JmapAccountSync(
    this.account,
    this._mailboxes,
    this._emails,
    this._accounts,
    this._syncLog,
    this._appLogger,
    this._drafts,
    this._notes,
    this._onNewMail, {
    void Function()? onSyncStart,
    void Function()? onSyncEnd,
  })  : _onSyncStart = onSyncStart,
        _onSyncEnd = onSyncEnd;

  final Account account;
  final MailboxRepository _mailboxes;
  final EmailRepository _emails;
  final AccountRepository _accounts;
  final SyncLogRepository _syncLog;
  final AppLogger _appLogger;
  final DraftRepository? _drafts;
  final NoteRepository? _notes;
  final OnNewMailCallback? _onNewMail;
  final void Function()? _onSyncStart;
  final void Function()? _onSyncEnd;

  bool _running = false;
  int _backoffSeconds = 5;
  Completer<void>? _stopSignal;
  Timer? _waitTimer;

  /// Poll interval used only when JMAP push (SSE) is unavailable — e.g. the
  /// server doesn't advertise an `eventSourceUrl`, the SSE connect fails, or
  /// the underlying stream ends. When push is connected the loop waits on
  /// real `StateChange` events instead, mirroring IMAP IDLE.
  static const _pollFallbackInterval = Duration(seconds: 30);

  @override
  bool get isRunning => _running;

  @override
  void start() {
    _running = true;
    unawaited(_loop());
  }

  @override
  void stop() {
    _running = false;
    if (_stopSignal != null && !_stopSignal!.isCompleted) {
      _stopSignal!.complete();
    }
  }

  @override
  void kick() {
    if (_stopSignal != null && !_stopSignal!.isCompleted) {
      _stopSignal!.complete();
    }
  }

  Future<void> _loop() async {
    while (_running) {
      final startedAt = DateTime.now();
      _onSyncStart?.call();
      try {
        final (_SyncStats stats, String? capturedLog) = await _runSync(
          account.verbose,
        );
        final syncLogId = await _syncLog.log(
          accountId: account.id,
          success: true,
          protocol: 'jmap',
          emailsFetched: stats.emailsFetched,
          emailsSkipped: stats.emailsSkipped,
          mailboxesSynced: stats.mailboxesSynced,
          pendingFlushed: stats.pendingFlushed,
          bytesTransferred: stats.bytesTransferred,
          startedAt: startedAt,
          finishedAt: DateTime.now(),
          mailboxStats: stats.mailboxStats,
          protocolLog: capturedLog,
        );
        final fetchedFolders = _fetchedFoldersLabel(stats.mailboxStats);
        unawaited(
          _appLogger.info(
            'sync.cycle.complete',
            'JMAP sync ok: ${stats.emailsFetched} new, '
                '${stats.mailboxesSynced} mailboxes'
                '${fetchedFolders != null ? ' — new mail in $fetchedFolders' : ''}',
            accountId: account.id,
            syncLogId: syncLogId == 0 ? null : syncLogId,
            data: {
              'protocol': 'jmap',
              'account': account.email,
              'host': account.jmapUrl,
              'durationMs': DateTime.now().difference(startedAt).inMilliseconds,
              'emailsFetched': stats.emailsFetched,
              'emailsSkipped': stats.emailsSkipped,
              'mailboxesSynced': stats.mailboxesSynced,
              'pendingFlushed': stats.pendingFlushed,
              'bytesTransferred': stats.bytesTransferred,
              'folders': _folderSyncData(stats.mailboxStats),
            },
          ),
        );
        _backoffSeconds = 5;
        _onSyncEnd?.call();
        await _wait();
      } catch (e, st) {
        _onSyncEnd?.call();
        // A cycle that finished most of its folders still did real work. Log
        // what landed rather than the hardcoded zeros that made the Sync Entry
        // read as "nothing happened" (#967), and classify the cycle by the
        // underlying failure rather than by the wrapper.
        final failure = _classifyCycleFailure(
          e,
          st,
          isPermanent: _isPermanentError,
          protocolLabel: 'JMAP',
        );
        final stats = failure.stats;
        final isPermanent = failure.isPermanent;
        var syncLogId = 0;
        try {
          syncLogId = await _syncLog.log(
            accountId: account.id,
            success: false,
            errorMessage: failure.errorMessage,
            stackTrace: failure.stackTrace.toString(),
            isPermanent: isPermanent,
            protocol: 'jmap',
            emailsFetched: stats?.emailsFetched ?? 0,
            emailsSkipped: stats?.emailsSkipped ?? 0,
            mailboxesSynced: stats?.mailboxesSynced ?? 0,
            pendingFlushed: stats?.pendingFlushed ?? 0,
            bytesTransferred: stats?.bytesTransferred ?? 0,
            startedAt: startedAt,
            finishedAt: DateTime.now(),
            mailboxStats: stats?.mailboxStats ?? const [],
          );
        } catch (logErr) {
          log('Failed to write JMAP sync log entry: $logErr');
        }
        unawaited(
          failure.logAtWarn
              ? _appLogger.warn(
                  failure.event,
                  failure.summary,
                  accountId: account.id,
                  syncLogId: syncLogId == 0 ? null : syncLogId,
                  data: {'protocol': 'jmap', 'permanent': isPermanent},
                  error: failure.cause,
                  stack: failure.stackTrace,
                )
              : _appLogger.error(
                  failure.event,
                  failure.summary,
                  accountId: account.id,
                  syncLogId: syncLogId == 0 ? null : syncLogId,
                  data: {'protocol': 'jmap', 'permanent': isPermanent},
                  error: failure.cause,
                  stack: failure.stackTrace,
                ),
        );

        if (isPermanent) {
          log(
            'Permanent JMAP error for ${account.email}, stopping sync loop.',
            error: e,
            stackTrace: st,
          );
          _running = false;
          break;
        }

        log(
          'JMAP sync failed for ${account.email}, retrying in ${_backoffSeconds}s',
          error: e,
        );
        await _waitSeconds(_backoffSeconds);
        _backoffSeconds = (_backoffSeconds * 2).clamp(5, 900); // max 15m
      }
    }
  }

  bool _isPermanentError(Object e) {
    if (isTlsConfigError(e)) return true;
    if (e is MissingPluginException) return true;
    final s = e.toString().toLowerCase();
    return s.contains('invalid credentials') ||
        s.contains('authentication failed') ||
        s.contains('login failed') ||
        s.contains('401') ||
        s.contains('403');
  }

  Future<void> _waitSeconds(int seconds) async {
    if (!_running) return;
    _stopSignal = Completer<void>();
    _waitTimer = Timer(Duration(seconds: seconds), () {
      if (!_stopSignal!.isCompleted) _stopSignal!.complete();
    });
    try {
      await _stopSignal!.future;
    } finally {
      _waitTimer?.cancel();
      _waitTimer = null;
      _stopSignal = null;
    }
  }

  Future<(_SyncStats, String?)> _runSync(bool verbose) async {
    if (!verbose) return (await _sync(), null);
    final buffer = StringBuffer();
    final stats = await runZoned(
      _sync,
      zoneValues: {verboseLogKey: buffer},
      zoneSpecification: ZoneSpecification(
        print: (_, __, ___, line) => buffer.writeln(line),
      ),
    );
    return (stats, buffer.toString());
  }

  Future<_SyncStats> _sync() async {
    final password = await _accounts.getPassword(account.id);

    await _drafts?.syncDrafts(account.id);

    // Check for expired snoozes and move them back to Inbox before syncing.
    await _emails.wakeUpEmails(account.id);

    // Drain outbound queue before pulling from server.
    final pendingFlushed = await _emails.flushPendingChanges(
      account.id,
      password,
    );
    // Drain the offline send queue. See _sync() above for rationale.
    await _emails.flushOutbox(account.id, password);

    final mailboxesSynced = await _mailboxes.syncMailboxes(account.id);

    final mailboxes = await _mailboxes.observeMailboxes(account.id).first;
    final folders = await _syncFolders(
      mailboxes: mailboxes,
      accountId: account.id,
      syncEmails: _emails.syncEmails,
      isRunning: () => _running,
    );
    // The loop now reaches this even after a folder failed, so a Sieve failure
    // must not be the exception that propagates — it would discard every
    // per-folder failure the loop just collected (#967). Hold it until the
    // folder failures have had their say.
    Object? sieveError;
    StackTrace? sieveStack;
    try {
      await _emails.applySieveRules(account.id);
    } catch (e, st) {
      sieveError = e;
      sieveStack = st;
    }
    // Fire notifications for any newly stored mail that matches the account's
    // rules. Runs unawaited so a notification failure never aborts the cycle.
    unawaited(_onNewMail?.call(account.id));
    await _syncNotesQuietly();
    final stats = _SyncStats(
      emailsFetched: folders.emailResult.fetched,
      emailsSkipped: folders.emailResult.skipped,
      mailboxesSynced: mailboxesSynced,
      pendingFlushed: pendingFlushed,
      bytesTransferred: folders.emailResult.bytesTransferred,
      mailboxStats: folders.mailboxStats,
    );
    if (folders.failures.isEmpty) {
      if (sieveError != null) {
        Error.throwWithStackTrace(sieveError, sieveStack!);
      }
      return stats;
    }
    throw _PartialSyncException(stats: stats, folders: folders);
  }

  /// Refreshes the per-account Notes cache. A broken Notes folder must not
  /// stop mail sync, so failures are logged and swallowed.
  Future<void> _syncNotesQuietly() async {
    final notes = _notes;
    if (notes == null) return;
    try {
      await notes.syncAllNotes(account.id);
    } catch (e, st) {
      unawaited(
        _appLogger.warn(
          'sync.notes.failed',
          'Note sync failed: $e',
          accountId: account.id,
          error: e,
          stack: st,
        ),
      );
    }
  }

  Future<void> _wait() async {
    if (!_running) return;
    _stopSignal = Completer<void>();
    final password = await _accounts.getPassword(account.id);

    // Try JMAP push (RFC 8887 EventSource). When the stream stays open the
    // loop waits for real StateChange events — just like IMAP IDLE waits for
    // EXISTS/EXPUNGE — with no periodic timer in between. The 25-min cap on
    // the underlying SSE connection ([email_repository_impl] `watchJmapPush`)
    // is what bounds the wait when the server is silent. Only when the push
    // stream ends (no eventSourceUrl, connect failure, IMAP-only account,
    // or the SSE stream itself timed out) do we fall back to a 30 s poll.
    final pushEvent = Completer<void>();
    final pushClosed = Completer<void>();
    final pushSub = _emails.watchJmapPush(account.id, password).listen(
      (_) {
        if (!pushEvent.isCompleted) pushEvent.complete();
      },
      onDone: () {
        if (!pushClosed.isCompleted) pushClosed.complete();
      },
      onError: (_) {
        if (!pushClosed.isCompleted) pushClosed.complete();
      },
    );

    try {
      await Future.any([
        pushEvent.future,
        pushClosed.future,
        _stopSignal!.future,
      ]);

      // Push isn't (or is no longer) available and nothing else woke us —
      // fall back to a 30 s poll so we still make forward progress.
      if (pushClosed.isCompleted &&
          !pushEvent.isCompleted &&
          !_stopSignal!.isCompleted) {
        unawaited(
          _appLogger.debug(
            'sync.jmap.wait',
            'JMAP wait: push unavailable — polling in '
                '${_pollFallbackInterval.inSeconds}s',
            accountId: account.id,
            data: {'sync_wait': 'poll_fallback'},
          ),
        );
        _waitTimer = Timer(_pollFallbackInterval, () {
          if (_stopSignal != null && !_stopSignal!.isCompleted) {
            _stopSignal!.complete();
          }
        });
        try {
          await _stopSignal!.future;
        } finally {
          _waitTimer?.cancel();
          _waitTimer = null;
        }
      } else if (pushEvent.isCompleted) {
        unawaited(
          _appLogger.debug(
            'sync.jmap.wait',
            'JMAP wait: woken by server StateChange',
            accountId: account.id,
            data: {'sync_wait': 'push_event'},
          ),
        );
      } else if (_stopSignal!.isCompleted) {
        unawaited(
          _appLogger.debug(
            'sync.jmap.wait',
            'JMAP wait: woken by kick()/stop()',
            accountId: account.id,
            data: {'sync_wait': 'stop'},
          ),
        );
      }
    } finally {
      // Fire-and-forget the cancel: awaiting it can deadlock under
      // fake-async tests (broadcast subscription cancel schedules cleanup
      // via a Timer that fake-async doesn't always drain), and in
      // production the next cycle immediately opens a fresh SSE stream
      // so there's no benefit to waiting.
      unawaited(pushSub.cancel());
      _stopSignal = null;
    }
  }
}

/// One mailbox that failed during a cycle, kept so the cycle can finish the
/// rest and still report what broke.
class _MailboxFailure {
  _MailboxFailure(this.mailboxLabel, this.error, this.stackTrace);

  final String mailboxLabel;
  final Object error;
  final StackTrace stackTrace;
}

/// Outcome of running one account's folders through [_syncFolders].
class _FolderSyncOutcome {
  _FolderSyncOutcome({
    required this.emailResult,
    required this.mailboxStats,
    required this.failures,
    required this.attempted,
    required this.cancelled,
  });

  final SyncEmailsResult emailResult;
  final List<MailboxSyncStats> mailboxStats;
  final List<_MailboxFailure> failures;

  /// Folders actually entered — excludes the ones skipped as duplicates, and
  /// the ones never reached because the loop was cancelled.
  final int attempted;

  /// Whether the loop stopped early because the account's sync loop was told
  /// to stop (app backgrounded, [AccountSyncManager.dispose]).
  final bool cancelled;

  /// True when no folder the cycle actually tried succeeded. That is an
  /// account-level outage rather than a partial cycle, so it is reported as
  /// the underlying error — the ordinary offline case must not read as
  /// "3 of 3 folders failed".
  ///
  /// A cancelled loop is never a total outage: the folders it never reached
  /// might well have succeeded.
  bool get isTotalOutage =>
      !cancelled && failures.isNotEmpty && failures.length == attempted;
}

/// Runs [mailboxes] through [syncEmails], carrying on past a folder that
/// fails.
///
/// Before #967 a failing folder threw straight out of the cycle, so every
/// folder behind it was never tried and the counters for the folders that had
/// already succeeded were discarded. Shared by both sync loops because the
/// IMAP and JMAP mailbox loops are identical.
Future<_FolderSyncOutcome> _syncFolders({
  required List<Mailbox> mailboxes,
  required String accountId,
  required Future<SyncEmailsResult> Function(String, String) syncEmails,
  required bool Function() isRunning,
}) async {
  var emailResult = SyncEmailsResult.zero;
  final mailboxStats = <MailboxSyncStats>[];
  final failures = <_MailboxFailure>[];
  var attempted = 0;
  var cancelled = false;

  for (final mailbox in mailboxes) {
    if (!isRunning()) {
      cancelled = true;
      break;
    }
    // Skip folders that just duplicate other folders (Gmail's "All Mail"),
    // otherwise every message is downloaded twice (#691).
    if (isDuplicateOfOtherFolders(mailbox)) continue;
    attempted++;
    final mailboxStart = DateTime.now();
    try {
      final r = await syncEmails(accountId, mailbox.path);
      emailResult += r;
      mailboxStats.add(
        MailboxSyncStats(
          mailboxPath: mailbox.path,
          mailboxName: mailbox.name,
          mailboxDisplayPath: mailbox.displayPath,
          fetched: r.fetched,
          skipped: r.skipped,
          bytesTransferred: r.bytesTransferred,
          duration: DateTime.now().difference(mailboxStart),
        ),
      );
    } catch (e, st) {
      // One folder must not stop the folders behind it from being tried, nor
      // discard what earlier folders already synced (#967).
      failures.add(_MailboxFailure(mailbox.displayPath, e, st));
    }
  }

  return _FolderSyncOutcome(
    emailResult: emailResult,
    mailboxStats: mailboxStats,
    failures: failures,
    attempted: attempted,
    cancelled: cancelled,
  );
}

/// Raised when a sync cycle ran every folder it could but at least one failed.
///
/// A plain throw out of the mailbox loop discarded the entire cycle: the Sync
/// Entry recorded 0 fetched / 0 mailboxes even though earlier folders had
/// synced fine, and every folder behind the failing one was never tried at all
/// (#967). The loop now carries on and reports the work that landed alongside
/// the folders that did not.
class _PartialSyncException implements Exception {
  _PartialSyncException({required this.stats, required this.folders});

  /// The work the cycle did manage to do. Carried even for a total outage:
  /// `syncMailboxes` and `flushPendingChanges` ran before the folders did and
  /// their counters are real.
  final _SyncStats stats;

  final _FolderSyncOutcome folders;

  List<_MailboxFailure> get failures => folders.failures;

  bool get isTotalOutage => folders.isTotalOutage;

  /// "2 of 7 folders failed (Archive, Sent)" — named so the user can act on
  /// them, capped so the message stays readable.
  String get foldersLabel {
    final labels = [for (final f in failures) f.mailboxLabel];
    final shown = labels.take(3).join(', ');
    final more = labels.length > 3 ? ' and ${labels.length - 3} more' : '';
    return '${failures.length} of ${folders.attempted} folders failed '
        '($shown$more)';
  }

  @override
  String toString() {
    if (isTotalOutage) return 'every folder failed: ${failures.first.error}';
    return '$foldersLabel: ${failures.first.error}';
  }
}

/// How one failed cycle should be reported: which error represents it, what
/// the user is told, and how loudly it is logged.
class _CycleFailure {
  _CycleFailure({
    required this.cause,
    required this.stackTrace,
    required this.stats,
    required this.errorMessage,
    required this.event,
    required this.summary,
    required this.isPermanent,
    required this.logAtWarn,
  });

  final Object cause;
  final StackTrace stackTrace;

  /// What the cycle salvaged, or null when it failed before doing any work.
  final _SyncStats? stats;

  final String errorMessage;
  final String event;
  final String summary;
  final bool isPermanent;
  final bool logAtWarn;
}

String _cycleEvent({required bool isPartial, required bool isTransient}) {
  if (isPartial) return 'sync.cycle.partial';
  if (isTransient) return 'sync.cycle.offline';
  return 'sync.cycle.failed';
}

String _cycleOutcome({required bool isPartial, required bool isTransient}) {
  if (isPartial) return 'sync partial';
  if (isTransient) return 'sync skipped (offline)';
  return 'sync failed';
}

/// Classifies [error] for the Sync Entry and the app log.
///
/// Derived in one place because the two sync loops report failures
/// identically; only [isPermanent] differs, since JMAP additionally treats a
/// 401/403 in the message as permanent.
_CycleFailure _classifyCycleFailure(
  Object error,
  StackTrace stackTrace, {
  required bool Function(Object) isPermanent,
  required String protocolLabel,
}) {
  if (error is! _PartialSyncException) {
    return _cycleFailure(
      cause: error,
      stackTrace: stackTrace,
      stats: null,
      foldersLabel: null,
      summarySubject: error,
      isPermanent: isPermanent,
      protocolLabel: protocolLabel,
    );
  }

  // A permanent failure anywhere in the cycle decides the cycle. Taking the
  // first failure instead would let a folder that merely timed out mask a 403
  // on a later one — and before #967 the loop aborted on the first failure, so
  // a permanent error further down was never even observed.
  final failures = error.failures;
  final representative = failures.firstWhere(
    (f) => isPermanent(f.error),
    orElse: () => failures.first,
  );

  // A total outage reports the underlying error, with no "N of M folders"
  // wrapper: the ordinary offline case must not read as "3 of 3 folders
  // failed". Its salvaged counters are still worth keeping.
  final totalOutage = error.isTotalOutage;
  return _cycleFailure(
    cause: representative.error,
    stackTrace: representative.stackTrace,
    stats: error.stats,
    foldersLabel: totalOutage ? null : error.foldersLabel,
    summarySubject: totalOutage ? representative.error : error,
    isPermanent: isPermanent,
    protocolLabel: protocolLabel,
  );
}

/// Assembles a [_CycleFailure]. A non-null [foldersLabel] is what makes the
/// cycle a *partial* one, which changes both the event name and the log level.
_CycleFailure _cycleFailure({
  required Object cause,
  required StackTrace stackTrace,
  required _SyncStats? stats,
  required String? foldersLabel,
  required Object summarySubject,
  required bool Function(Object) isPermanent,
  required String protocolLabel,
}) {
  final isTransient = _isTransientNetworkError(cause);
  final isPartial = foldersLabel != null;
  return _CycleFailure(
    cause: cause,
    stackTrace: stackTrace,
    stats: stats,
    errorMessage: isPartial
        ? '$foldersLabel: ${syncErrorMessage(cause)}'
        : syncErrorMessage(cause),
    event: _cycleEvent(isPartial: isPartial, isTransient: isTransient),
    summary: '$protocolLabel '
        '${_cycleOutcome(isPartial: isPartial, isTransient: isTransient)}: '
        '$summarySubject',
    isPermanent: isPermanent(cause),
    logAtWarn: isPartial || isTransient,
  );
}

class _SyncStats {
  const _SyncStats({
    required this.emailsFetched,
    required this.emailsSkipped,
    required this.mailboxesSynced,
    required this.pendingFlushed,
    required this.bytesTransferred,
    required this.mailboxStats,
  });

  final int emailsFetched;
  final int emailsSkipped;
  final int mailboxesSynced;
  final int pendingFlushed;
  final int bytesTransferred;
  final List<MailboxSyncStats> mailboxStats;
}

/// Human-readable path for a per-folder stat, preferring the hierarchical
/// display path and falling back to the leaf name then the raw (possibly
/// opaque JMAP) path — so the app log never shows a bare "a"/"b"/"c" id.
String _folderLabel(MailboxSyncStats s) =>
    s.mailboxDisplayPath ?? s.mailboxName ?? s.mailboxPath;

/// Builds the structured `folders` payload for a `sync.cycle.complete` app-log
/// entry: one self-describing entry per synced mailbox with its long path and
/// per-folder counts, so the entry stays readable even if a folder is later
/// deleted from the local cache.
List<Map<String, Object?>> _folderSyncData(List<MailboxSyncStats> stats) {
  return [
    for (final s in stats)
      {
        'path': s.mailboxPath,
        'name': s.mailboxName,
        'displayPath': _folderLabel(s),
        'fetched': s.fetched,
        'skipped': s.skipped,
      },
  ];
}

/// Names the folders that fetched new mail during a cycle by their long path,
/// capped at [max] with an "and N more" suffix. Returns null when no folder
/// fetched anything new, so the caller can omit the fragment entirely.
String? _fetchedFoldersLabel(List<MailboxSyncStats> stats, {int max = 5}) {
  final names = [
    for (final s in stats)
      if (s.fetched > 0) _folderLabel(s),
  ];
  if (names.isEmpty) return null;
  if (names.length <= max) return names.join(', ');
  return '${names.take(max).join(', ')} and ${names.length - max} more';
}

/// A [StringSink] that captures IMAP protocol trace lines, retaining only the
/// most recent output so a failed sync can surface the failing command without
/// keeping an unbounded amount of message content in memory.
///
/// Overly long individual lines (e.g. a FETCH body logged as one line) are
/// truncated, and the oldest lines are dropped once the total exceeds the
/// char budget. The [verboseLogKey] zone value is a [StringSink] so both this
/// buffer and the ManageSieve client's writes flow into the same trace.
class _BoundedProtocolLog implements StringSink {
  static const _maxChars = 16384;
  static const _maxLineLength = 2048;

  final _lines = <String>[];
  int _chars = 0;

  bool get isEmpty => _lines.isEmpty;

  void _add(String line) {
    if (line.length > _maxLineLength) {
      line = '${line.substring(0, _maxLineLength)}…';
    }
    _lines.add(line);
    _chars += line.length + 1; // +1 accounts for the joining newline
    while (_chars > _maxChars && _lines.length > 1) {
      _chars -= _lines.removeAt(0).length + 1;
    }
  }

  @override
  void writeln([Object? object = '']) => _add(object.toString());

  @override
  void write(Object? object) => _add(object.toString());

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _add(objects.join(separator));

  @override
  void writeCharCode(int charCode) => _add(String.fromCharCode(charCode));

  @override
  String toString() => _lines.join('\n');
}

/// Replaces credentials in a captured IMAP protocol log.
///
/// Redacts the password argument from LOGIN commands and the base64 payload
/// from AUTHENTICATE commands. Other lines pass through unchanged.
String _redactCredentials(String log) {
  return log
      .replaceAllMapped(
        RegExp(r'(LOGIN\s+\S+\s+)\S+', caseSensitive: false),
        (m) => '${m.group(1)}[REDACTED]',
      )
      .replaceAllMapped(
        RegExp(r'(AUTHENTICATE\s+\w+\s+)\S+', caseSensitive: false),
        (m) => '${m.group(1)}[REDACTED]',
      );
}
