import 'dart:async';

import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart' show SyncEmailsResult;
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/repositories/draft_repository.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';
import 'package:sharedinbox/core/repositories/sync_log_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/core/utils/logger.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart'
    show ImapConnectFn, connectImap, verboseLogKey;
import 'package:sharedinbox/data/imap/tls_error.dart' show isTlsConfigError;

typedef OnNewMailCallback = Future<void> Function(String accountEmail);

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
    OnNewMailCallback? onNewMail,
  })  : _imapConnect = imapConnect,
        _syncLog = syncLog,
        _appLogger = appLogger ?? AppLogger(const NoOpAppLogRepository()),
        _drafts = drafts,
        _onNewMail = onNewMail;

  final AccountRepository _accounts;
  final MailboxRepository _mailboxes;
  final EmailRepository _emails;
  final ImapConnectFn _imapConnect;
  final SyncLogRepository _syncLog;
  final AppLogger _appLogger;
  final DraftRepository? _drafts;
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

  /// Wakes the idle/wait phase of the given account's sync loop so a new
  /// sync cycle starts immediately. No-op if the account is unknown.
  void syncNow(String accountId) {
    _active[accountId]?.kick();
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
  /// immediately starts a fresh sync cycle. Use this as an escape hatch when
  /// the local DB is believed to be out of sync with the server.
  Future<void> forceResync(String accountId) async {
    _active.remove(accountId)?.stop();

    await _emails.clearForResync(accountId);
    await _mailboxes.clearForResync(accountId);

    final accounts = await _accounts.observeAccounts().first;
    final account = accounts.cast<Account?>().firstWhere(
          (a) => a?.id == accountId,
          orElse: () => null,
        );
    if (account == null) return;

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
  final OnNewMailCallback? _onNewMail;
  final void Function()? _onSyncStart;
  final void Function()? _onSyncEnd;

  imap.ImapClient? _idleClient;
  bool _running = false;
  int _backoffSeconds = 5;
  Completer<void>? _stopSignal;
  Timer? _waitTimer;

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
        unawaited(
          _appLogger.info(
            'sync.cycle.complete',
            'IMAP sync ok: ${stats.emailsFetched} new, '
                '${stats.mailboxesSynced} mailboxes',
            accountId: account.id,
            syncLogId: syncLogId == 0 ? null : syncLogId,
            data: {
              'protocol': 'imap',
              'emailsFetched': stats.emailsFetched,
              'emailsSkipped': stats.emailsSkipped,
              'mailboxesSynced': stats.mailboxesSynced,
              'pendingFlushed': stats.pendingFlushed,
              'bytesTransferred': stats.bytesTransferred,
            },
          ),
        );
        _backoffSeconds = 5;
        _onSyncEnd?.call();
        await _idle();
      } catch (e, st) {
        _onSyncEnd?.call();
        final isPermanent = _isPermanentError(e);
        var syncLogId = 0;
        try {
          syncLogId = await _syncLog.log(
            accountId: account.id,
            success: false,
            errorMessage: e.toString(),
            stackTrace: st.toString(),
            isPermanent: isPermanent,
            protocol: 'imap',
            emailsFetched: 0,
            emailsSkipped: 0,
            mailboxesSynced: 0,
            pendingFlushed: 0,
            bytesTransferred: 0,
            startedAt: startedAt,
            finishedAt: DateTime.now(),
          );
        } catch (logErr) {
          log('Failed to write IMAP sync log entry: $logErr');
        }
        unawaited(
          _appLogger.error(
            'sync.cycle.failed',
            'IMAP sync failed: $e',
            accountId: account.id,
            syncLogId: syncLogId == 0 ? null : syncLogId,
            data: {'protocol': 'imap', 'permanent': isPermanent},
            error: e,
            stack: st,
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
    if (!verbose) return (await _sync(), null);
    final buffer = StringBuffer();
    final stats = await runZoned(
      _sync,
      zoneValues: {verboseLogKey: buffer},
      zoneSpecification: ZoneSpecification(
        print: (_, __, ___, line) => buffer.writeln(line),
      ),
    );
    return (stats, _redactCredentials(buffer.toString()));
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
    var emailResult = SyncEmailsResult.zero;
    final mailboxStats = <MailboxSyncStats>[];
    for (final mailbox in mailboxes) {
      if (!_running) break;
      final mailboxStart = DateTime.now();
      final r = await _emails.syncEmails(account.id, mailbox.path);
      emailResult += r;
      mailboxStats.add(
        MailboxSyncStats(
          mailboxPath: mailbox.path,
          mailboxName: mailbox.name,
          fetched: r.fetched,
          skipped: r.skipped,
          bytesTransferred: r.bytesTransferred,
          duration: DateTime.now().difference(mailboxStart),
        ),
      );
    }
    await _emails.applySieveRules(account.id);
    return _SyncStats(
      emailsFetched: emailResult.fetched,
      emailsSkipped: emailResult.skipped,
      mailboxesSynced: mailboxesSynced,
      pendingFlushed: pendingFlushed,
      bytesTransferred: emailResult.bytesTransferred,
      mailboxStats: mailboxStats,
    );
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
      var hasNewMail = false;

      final sub = client.eventBus
          .on<imap.ImapEvent>()
          .where(
            (e) =>
                e is imap.ImapMessagesExistEvent || e is imap.ImapExpungeEvent,
          )
          .listen((e) {
        if (e is imap.ImapMessagesExistEvent &&
            e.newMessagesExists > e.oldMessagesExists) {
          hasNewMail = true;
        }
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

      if (hasNewMail) {
        unawaited(_onNewMail?.call(account.email));
      }
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
    this._drafts, {
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
        unawaited(
          _appLogger.info(
            'sync.cycle.complete',
            'JMAP sync ok: ${stats.emailsFetched} new, '
                '${stats.mailboxesSynced} mailboxes',
            accountId: account.id,
            syncLogId: syncLogId == 0 ? null : syncLogId,
            data: {
              'protocol': 'jmap',
              'emailsFetched': stats.emailsFetched,
              'emailsSkipped': stats.emailsSkipped,
              'mailboxesSynced': stats.mailboxesSynced,
              'pendingFlushed': stats.pendingFlushed,
              'bytesTransferred': stats.bytesTransferred,
            },
          ),
        );
        _backoffSeconds = 5;
        _onSyncEnd?.call();
        await _wait();
      } catch (e, st) {
        _onSyncEnd?.call();
        final isPermanent = _isPermanentError(e);
        var syncLogId = 0;
        try {
          syncLogId = await _syncLog.log(
            accountId: account.id,
            success: false,
            errorMessage: e.toString(),
            stackTrace: st.toString(),
            isPermanent: isPermanent,
            protocol: 'jmap',
            emailsFetched: 0,
            emailsSkipped: 0,
            mailboxesSynced: 0,
            pendingFlushed: 0,
            bytesTransferred: 0,
            startedAt: startedAt,
            finishedAt: DateTime.now(),
          );
        } catch (logErr) {
          log('Failed to write JMAP sync log entry: $logErr');
        }
        unawaited(
          _appLogger.error(
            'sync.cycle.failed',
            'JMAP sync failed: $e',
            accountId: account.id,
            syncLogId: syncLogId == 0 ? null : syncLogId,
            data: {'protocol': 'jmap', 'permanent': isPermanent},
            error: e,
            stack: st,
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
    var emailResult = SyncEmailsResult.zero;
    final mailboxStats = <MailboxSyncStats>[];
    for (final mailbox in mailboxes) {
      if (!_running) break;
      final mailboxStart = DateTime.now();
      final r = await _emails.syncEmails(account.id, mailbox.path);
      emailResult += r;
      mailboxStats.add(
        MailboxSyncStats(
          mailboxPath: mailbox.path,
          mailboxName: mailbox.name,
          fetched: r.fetched,
          skipped: r.skipped,
          bytesTransferred: r.bytesTransferred,
          duration: DateTime.now().difference(mailboxStart),
        ),
      );
    }
    await _emails.applySieveRules(account.id);
    return _SyncStats(
      emailsFetched: emailResult.fetched,
      emailsSkipped: emailResult.skipped,
      mailboxesSynced: mailboxesSynced,
      pendingFlushed: pendingFlushed,
      bytesTransferred: emailResult.bytesTransferred,
      mailboxStats: mailboxStats,
    );
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
