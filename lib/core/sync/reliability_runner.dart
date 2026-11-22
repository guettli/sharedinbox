import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:sharedinbox/core/models/mailbox.dart' show isAppDataFolder;
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart';

/// Joins affected folder display paths for a log message, capped at [max] with
/// an "and N more" suffix so the message names the folders rather than only
/// counting them.
String _foldersLabel(List<String> folders, {int max = 5}) {
  if (folders.isEmpty) return 'no folders';
  if (folders.length <= max) return folders.join(', ');
  return '${folders.take(max).join(', ')} and ${folders.length - max} more';
}

/// Periodically verifies local state against the server's "ground truth".
/// Results are stored in the [SyncHealth] table.
class ReliabilityRunner {
  ReliabilityRunner(
    this._db,
    this._accounts,
    this._mailboxes,
    this._emails,
    this._appLogger, {
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final AppDatabase _db;
  final AccountRepository _accounts;
  final MailboxRepository _mailboxes;
  final EmailRepository _emails;
  final AppLogger _appLogger;
  final DateTime Function() _now;

  Timer? _timer;
  Timer? _startupTimer;
  StreamSubscription<String>? _syncSucceededSub;

  /// Earliest time a successful sync may re-run a failed check, by account
  /// id. Keeps a flapping connection from running the check after every sync.
  final Map<String, DateTime> _nextRecheckAt = {};

  /// Wait before the next sync-triggered re-check, by account id. Doubles
  /// after each re-check (up to the hourly interval) until a check completes,
  /// so a check that keeps failing does not run every few minutes.
  final Map<String, Duration> _recheckDelay = {};

  /// Wait after the first sync-triggered re-check of a failure.
  static const recheckThrottle = Duration(minutes: 5);
  bool _running = false;

  /// Account ids whose verification is currently in flight. Broadcast so the
  /// account list can show an in-progress indicator while a check runs, rather
  /// than leaving the row silently unchanged.
  final Set<String> _verifying = {};
  final StreamController<Set<String>> _verifyingController =
      StreamController<Set<String>>.broadcast();

  /// Emits the set of account ids currently being verified whenever it changes.
  Stream<Set<String>> get verifyingAccounts => _verifyingController.stream;

  /// Checks currently running, by account id. A second request for the same
  /// account joins the running check instead of starting another one (which
  /// would also clear the "verifying" state while the first still runs).
  final Map<String, Future<void>> _inFlight = {};

  static const _checkInterval = Duration(hours: 1);

  /// Starts the hourly check. [syncSucceeded] emits the account id of every
  /// successful sync cycle: after a failed check, the next one re-runs the
  /// check so a stale "Sync check failed" clears once the server is reachable
  /// again instead of staying up to an hour (#1386).
  void start({Stream<String>? syncSucceeded}) {
    // A second start() replaces the first one's timers and subscription.
    _cancelSchedule();
    _running = true;
    _syncSucceededSub = syncSucceeded?.listen(
      (accountId) => unawaited(_recheckAfterSync(accountId)),
    );
    _timer = Timer.periodic(_checkInterval, (_) {
      unawaited(_runAll());
    });
    // Also run once on startup (after a short delay to not compete with initial sync).
    _startupTimer = Timer(const Duration(minutes: 5), () {
      if (_running) {
        unawaited(_runAll());
      }
    });
  }

  void stop() {
    _running = false;
    _cancelSchedule();
    if (!_verifyingController.isClosed) {
      unawaited(_verifyingController.close());
    }
  }

  void _cancelSchedule() {
    _timer?.cancel();
    _timer = null;
    _startupTimer?.cancel();
    _startupTimer = null;
    unawaited(_syncSucceededSub?.cancel());
    _syncSucceededSub = null;
  }

  void _setVerifying(String accountId, {required bool active}) {
    if (active) {
      _verifying.add(accountId);
    } else {
      _verifying.remove(accountId);
    }
    if (!_verifyingController.isClosed) {
      _verifyingController.add(Set.unmodifiable(_verifying));
    }
  }

  /// Re-runs the check of [accountId] after a successful sync when the stored
  /// result is a failure. Skipped while a check of the account runs and until
  /// the account's re-check delay (see [_recheckDelay]) has passed.
  Future<void> _recheckAfterSync(String accountId) async {
    if (!_running || !_mayRecheck(accountId)) return;
    final SyncHealthRow? row;
    try {
      row = await (_db.select(_db.syncHealth)
            ..where((t) => t.accountId.equals(accountId)))
          .getSingleOrNull();
    } catch (e) {
      // Best-effort: the hourly check still runs.
      await _appLogger.debug(
        'sync_health',
        'Could not read the sync health result after a successful sync',
        accountId: accountId,
        data: {'error': e.toString()},
      );
      return;
    }
    if (row == null) {
      // No result (or the account was removed): nothing to re-check.
      _forgetRechecks(accountId);
      return;
    }
    if (row.lastError == null) return;
    // Checked again: another sync may have started a re-check while the row
    // was being read.
    if (!_running || !_mayRecheck(accountId)) return;
    final delay = _recheckDelay[accountId] ?? recheckThrottle;
    _nextRecheckAt[accountId] = _now().add(delay);
    final doubled = delay * 2;
    _recheckDelay[accountId] =
        doubled > _checkInterval ? _checkInterval : doubled;
    await _appLogger.info(
      'sync_health',
      'Sync succeeded after a failed sync health check; checking again',
      accountId: accountId,
    );
    // stop() may have run while the log line was written.
    if (!_running) return;
    await _verifyOnce(accountId);
  }

  bool _mayRecheck(String accountId) {
    if (_inFlight.containsKey(accountId)) return false;
    final next = _nextRecheckAt[accountId];
    return next == null || !_now().isBefore(next);
  }

  void _forgetRechecks(String accountId) {
    _nextRecheckAt.remove(accountId);
    _recheckDelay.remove(accountId);
  }

  Future<void> _runAll() async {
    final accounts = await _accounts.observeAccounts().first;
    final ids = accounts.map((a) => a.id).toSet();
    _nextRecheckAt.removeWhere((id, _) => !ids.contains(id));
    _recheckDelay.removeWhere((id, _) => !ids.contains(id));
    for (final account in accounts) {
      if (!_running) break;
      await _verifyOnce(account.id);
    }
  }

  /// Runs one check of [accountId] unless one is already running, in which
  /// case it returns that one. [force] marks a manual check: it is logged and
  /// runs even when the periodic runner is stopped.
  Future<void> _verifyOnce(String accountId, {bool force = false}) {
    final running = _inFlight[accountId];
    if (running != null) return running;
    final check = _logAndRun(accountId, force: force);
    _inFlight[accountId] = check;
    // unawaited, not returned: remove() yields this same future, and
    // whenComplete would then wait on itself forever.
    return check.whenComplete(() {
      unawaited(_inFlight.remove(accountId));
    });
  }

  Future<void> _logAndRun(String accountId, {required bool force}) async {
    if (force) {
      await _appLogger.info(
        'sync_health',
        'Manual sync health verification started',
        accountId: accountId,
      );
    }
    await _runForAccount(accountId, force: force);
  }

  Future<void> _runForAccount(String accountId, {bool force = false}) async {
    _setVerifying(accountId, active: true);
    try {
      final mailboxes = await _mailboxes.observeMailboxes(accountId).first;
      var totalMissingLocally = 0;
      var totalMissingOnServer = 0;
      var totalFlagMismatches = 0;
      final details = <String, dynamic>{};
      // Per-folder discrepancy detail keyed by the human-readable display path
      // (e.g. "Archive/2026") rather than the opaque JMAP id, for the app log.
      final folderDetails = <String, dynamic>{};
      final affectedFolders = <String>[];

      for (final mailbox in mailboxes) {
        if (!force && !_running) {
          // Stopped part-way: the folders not reached say nothing, so saving
          // zero counts would store a false "healthy" result.
          await _appLogger.debug(
            'sync_health',
            'Sync health verification stopped before it finished',
            accountId: accountId,
          );
          return;
        }
        // The app's own data folders are never mail-synced (#1364).
        if (isAppDataFolder(mailbox)) continue;
        final result = await _emails.verifySyncReliability(
          accountId,
          mailbox.path,
        );
        if (!result.isHealthy) {
          totalMissingLocally += result.missingLocally.length;
          totalMissingOnServer += result.missingOnServer.length;
          totalFlagMismatches += result.flagMismatches.length;
          final folderStat = {
            'missingLocally': result.missingLocally.length,
            'missingOnServer': result.missingOnServer.length,
            'flagMismatches': result.flagMismatches.length,
          };
          details[mailbox.path] = folderStat;
          folderDetails[mailbox.displayPath] = folderStat;
          affectedFolders.add(mailbox.displayPath);
        }
      }

      final isHealthy = totalMissingLocally == 0 &&
          totalMissingOnServer == 0 &&
          totalFlagMismatches == 0;

      await _db.into(_db.syncHealth).insertOnConflictUpdate(
            SyncHealthCompanion.insert(
              accountId: accountId,
              lastVerifiedAt: _now(),
              isHealthy: isHealthy,
              discrepancySummary: Value(isHealthy ? null : jsonEncode(details)),
              // Clear any previous failure now that the check ran to completion.
              lastError: const Value(null),
            ),
          );
      // The server answered: a later failure starts a fresh re-check delay.
      _forgetRechecks(accountId);

      if (isHealthy) {
        await _appLogger.info(
          'sync_health',
          'Sync health verified: healthy',
          accountId: accountId,
        );
      } else {
        final folderLabel = _foldersLabel(affectedFolders);
        await _appLogger.warn(
          'sync_health',
          'Sync health verified: discrepancies found in $folderLabel',
          accountId: accountId,
          data: {
            'missingLocally': totalMissingLocally,
            'missingOnServer': totalMissingOnServer,
            'flagMismatches': totalFlagMismatches,
            'folders': folderDetails,
          },
        );
      }
    } catch (e, s) {
      // Persist the failure so the account row can explain why the check did
      // not complete instead of remaining "not verified yet" forever.
      try {
        await _db.into(_db.syncHealth).insertOnConflictUpdate(
              SyncHealthCompanion.insert(
                accountId: accountId,
                lastVerifiedAt: _now(),
                isHealthy: false,
                discrepancySummary: const Value(null),
                lastError: Value(e.toString()),
              ),
            );
      } catch (_) {
        // Best-effort: never let persisting the failure mask the original one.
      }
      await _appLogger.error(
        'sync_health',
        'Sync health verification failed',
        accountId: accountId,
        error: e,
        stack: s,
      );
    } finally {
      _setVerifying(accountId, active: false);
    }
  }

  /// Forces a reliability check for all accounts immediately.
  ///
  /// Works regardless of whether [start] has been called, so the UI can
  /// trigger a manual check at any time without depending on the periodic
  /// runner being active.
  Future<void> checkNow() async {
    final accounts = await _accounts.observeAccounts().first;
    for (final account in accounts) {
      await checkAccountNow(account.id);
    }
  }

  /// Verifies only [accountId] right now and returns the stored result, so a
  /// manual "Verify sync health" on one account can report its outcome.
  Future<SyncHealthRow?> checkAccountNow(String accountId) async {
    await _verifyOnce(accountId, force: true);
    return (_db.select(_db.syncHealth)
          ..where((t) => t.accountId.equals(accountId)))
        .getSingleOrNull();
  }
}
