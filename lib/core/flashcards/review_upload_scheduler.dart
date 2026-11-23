import 'dart:async';

import 'package:sharedinbox/core/services/app_logger.dart';

/// Decides when the pending own reviews are uploaded (ENCRYPTED-OBJECTS.md
/// §7, #1380). A rating never touches the network; the triggers below
/// request a [flush], which writes the pending reviews as segments that the
/// store's sync uploads:
///
/// - the app goes to the background ([appPaused]),
/// - a study session ends ([endSession]),
/// - [idle] (5 min) after the last rating ([rated]),
/// - [maxPending] (300) or more pending reviews (at once),
/// - a regular sync cycle ([synced]).
///
/// Requests are debounced ([debounce]) and coalesced: one flush per account
/// at a time, and one more after it when requested meanwhile.
class ReviewUploadScheduler {
  ReviewUploadScheduler({
    required this.flush,
    required this.pendingAccounts,
    this.debounce = const Duration(seconds: 2),
    this.idle = const Duration(minutes: 5),
    this.maxPending = 300,
    this.appLogger,
  });

  /// Writes the pending reviews of an account as segments.
  final Future<void> Function(String accountId) flush;

  /// The accounts with pending reviews.
  final Future<Iterable<String>> Function() pendingAccounts;

  final Duration debounce;
  final Duration idle;
  final int maxPending;
  final AppLogger? appLogger;

  final Map<String, Timer> _idle = {};
  final Set<String> _due = {};
  Timer? _debounce;
  final Map<String, Future<void>> _running = {};
  final Set<String> _again = {};
  bool _disposed = false;

  /// A rating was stored; [pending] reviews of [accountId] wait for upload.
  void rated(String accountId, int pending) {
    if (_disposed) return;
    _idle.remove(accountId)?.cancel();
    if (pending >= maxPending) {
      unawaited(_flushNow(accountId));
      return;
    }
    _idle[accountId] = Timer(idle, () {
      _idle.remove(accountId);
      request(accountId);
    });
  }

  /// A study session of [accountId] ended.
  void endSession(String accountId) => request(accountId);

  /// A regular sync cycle of [accountId] finished.
  void synced(String accountId) => request(accountId);

  /// The app went to the background: every account with pending reviews.
  Future<void> appPaused() async {
    if (_disposed) return;
    for (final accountId in await pendingAccounts()) {
      request(accountId);
    }
  }

  /// Flushes [accountId] [debounce] after the last request.
  void request(String accountId) {
    if (_disposed) return;
    _due.add(accountId);
    _debounce?.cancel();
    _debounce = Timer(debounce, () {
      final due = {..._due};
      _due.clear();
      for (final id in due) {
        unawaited(_flushNow(id));
      }
    });
  }

  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    for (final t in _idle.values) {
      t.cancel();
    }
    _idle.clear();
    _due.clear();
  }

  Future<void> _flushNow(String accountId) {
    _idle.remove(accountId)?.cancel();
    _due.remove(accountId);
    final running = _running[accountId];
    if (running != null) {
      _again.add(accountId);
      return running;
    }
    return _running[accountId] = _run(accountId);
  }

  Future<void> _run(String accountId) async {
    try {
      do {
        _again.remove(accountId);
        try {
          await flush(accountId);
        } catch (e) {
          unawaited(
            appLogger?.warn(
              'review.upload_failed',
              'Could not write the pending reviews for upload; retrying on '
                  'the next trigger',
              accountId: accountId,
              data: {'error': e.toString()},
            ),
          );
        }
      } while (_again.contains(accountId) && !_disposed);
    } finally {
      _running.removeWhere((id, _) => id == accountId);
    }
  }
}
