import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart';

/// Periodically verifies local state against the server's "ground truth".
/// Results are stored in the [SyncHealth] table.
class ReliabilityRunner {
  ReliabilityRunner(
    this._db,
    this._accounts,
    this._mailboxes,
    this._emails,
    this._appLogger,
  );

  final AppDatabase _db;
  final AccountRepository _accounts;
  final MailboxRepository _mailboxes;
  final EmailRepository _emails;
  final AppLogger _appLogger;

  Timer? _timer;
  bool _running = false;

  /// Account ids whose verification is currently in flight. Broadcast so the
  /// account list can show an in-progress indicator while a check runs, rather
  /// than leaving the row silently unchanged.
  final Set<String> _verifying = {};
  final StreamController<Set<String>> _verifyingController =
      StreamController<Set<String>>.broadcast();

  /// Emits the set of account ids currently being verified whenever it changes.
  Stream<Set<String>> get verifyingAccounts => _verifyingController.stream;

  static const _checkInterval = Duration(hours: 1);

  void start() {
    _running = true;
    _timer = Timer.periodic(_checkInterval, (_) {
      unawaited(_runAll());
    });
    // Also run once on startup (after a short delay to not compete with initial sync).
    Future.delayed(const Duration(minutes: 5), () {
      if (_running) {
        unawaited(_runAll());
      }
    });
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
    if (!_verifyingController.isClosed) {
      unawaited(_verifyingController.close());
    }
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

  Future<void> _runAll() async {
    final accounts = await _accounts.observeAccounts().first;
    for (final account in accounts) {
      if (!_running) break;
      await _runForAccount(account.id);
    }
  }

  Future<void> _runForAccount(String accountId, {bool force = false}) async {
    _setVerifying(accountId, active: true);
    try {
      final mailboxes = await _mailboxes.observeMailboxes(accountId).first;
      var totalMissingLocally = 0;
      var totalMissingOnServer = 0;
      var totalFlagMismatches = 0;
      final details = <String, dynamic>{};

      for (final mailbox in mailboxes) {
        if (!force && !_running) break;
        final result = await _emails.verifySyncReliability(
          accountId,
          mailbox.path,
        );
        if (!result.isHealthy) {
          totalMissingLocally += result.missingLocally.length;
          totalMissingOnServer += result.missingOnServer.length;
          totalFlagMismatches += result.flagMismatches.length;
          details[mailbox.path] = {
            'missingLocally': result.missingLocally.length,
            'missingOnServer': result.missingOnServer.length,
            'flagMismatches': result.flagMismatches.length,
          };
        }
      }

      final isHealthy = totalMissingLocally == 0 &&
          totalMissingOnServer == 0 &&
          totalFlagMismatches == 0;

      await _db.into(_db.syncHealth).insertOnConflictUpdate(
            SyncHealthCompanion.insert(
              accountId: accountId,
              lastVerifiedAt: DateTime.now(),
              isHealthy: isHealthy,
              discrepancySummary: Value(isHealthy ? null : jsonEncode(details)),
              // Clear any previous failure now that the check ran to completion.
              lastError: const Value(null),
            ),
          );

      if (isHealthy) {
        await _appLogger.info(
          'sync_health',
          'Sync health verified: healthy',
          accountId: accountId,
        );
      } else {
        await _appLogger.warn(
          'sync_health',
          'Sync health verified: discrepancies found',
          accountId: accountId,
          data: {
            'missingLocally': totalMissingLocally,
            'missingOnServer': totalMissingOnServer,
            'flagMismatches': totalFlagMismatches,
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
                lastVerifiedAt: DateTime.now(),
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
    await _appLogger.info(
      'sync_health',
      'Manual sync health verification started',
      data: {'accounts': accounts.length},
    );
    for (final account in accounts) {
      await _runForAccount(account.id, force: true);
    }
  }
}
