import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';
import 'package:sharedinbox/core/utils/logger.dart';
import 'package:sharedinbox/data/db/database.dart';

/// Periodically verifies local state against the server's "ground truth".
/// Results are stored in the [SyncHealth] table.
class ReliabilityRunner {
  ReliabilityRunner(this._db, this._accounts, this._mailboxes, this._emails);

  final AppDatabase _db;
  final AccountRepository _accounts;
  final MailboxRepository _mailboxes;
  final EmailRepository _emails;

  Timer? _timer;
  bool _running = false;

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
  }

  Future<void> _runAll() async {
    final accounts = await _accounts.observeAccounts().first;
    for (final account in accounts) {
      if (!_running) break;
      await _runForAccount(account.id);
    }
  }

  Future<void> _runForAccount(String accountId, {bool force = false}) async {
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
            ),
          );

      if (!isHealthy) {
        log(
          'Sync reliability discrepancies found for $accountId: '
          'missingLocally=$totalMissingLocally, '
          'missingOnServer=$totalMissingOnServer, '
          'flagMismatches=$totalFlagMismatches',
        );
      }
    } catch (e) {
      log('ReliabilityRunner failed for $accountId: $e');
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
      await _runForAccount(account.id, force: true);
    }
  }
}
