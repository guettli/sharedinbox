import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:sharedinbox/core/models/outbox_message.dart';
import 'package:sharedinbox/core/services/app_logger.dart';

/// Drains the outbox when a queued message's retry time comes (#1331).
///
/// A failed send gets a `nextAttemptAt` (30 s, 2 min, 10 min, 1 h). The sync
/// loops drain the outbox only at the start of a cycle, and an IMAP loop can
/// sit in IDLE for 25 minutes, so a message whose link came back stayed
/// queued that long. This scheduler watches the outbox and arms one timer for
/// the earliest retry time of a pending row; when it fires it drains the
/// accounts whose rows are due. It does not touch the sync loops, so IDLE
/// keeps running.
///
/// [drain] goes through the regular outbox flush, which serialises flushes
/// per account and claims each row while it is sent, so a row the foreground
/// Send is sending is never sent again by this drain.
///
/// Rows without a retry time (just queued, or reset by "Retry now" or a
/// reconnect) are left to whoever queued or reset them and to the sync cycle.
class OutboxRetryScheduler {
  OutboxRetryScheduler({
    required Stream<List<OutboxMessage>> outbox,
    required Future<void> Function(String accountId) drain,
    AppLogger? logger,
    DateTime Function() clock = DateTime.now,
    this.minGap = const Duration(seconds: 30),
  })  : _outbox = outbox,
        _drain = drain,
        _logger = logger,
        _clock = clock;

  final Stream<List<OutboxMessage>> _outbox;
  final Future<void> Function(String accountId) _drain;
  final AppLogger? _logger;
  final DateTime Function() _clock;

  /// Least time between two drains of one account. A drain that left a due
  /// row due (no password stored, the row was being edited) would otherwise
  /// re-arm a zero timer and spin.
  final Duration minGap;

  StreamSubscription<List<OutboxMessage>>? _sub;
  List<OutboxMessage> _rows = const [];
  Timer? _timer;
  final Set<String> _draining = {};
  final Map<String, DateTime> _lastDrain = {};

  /// When the armed timer fires, or null when no retry is waiting.
  @visibleForTesting
  DateTime? get nextWakeAt => _nextWakeAt;
  DateTime? _nextWakeAt;

  /// Starts watching the outbox. Calling it again is a no-op.
  void start() {
    if (_sub != null) return;
    _sub = _outbox.listen(
      (rows) {
        _rows = rows;
        _arm();
      },
      onError: (Object e, StackTrace st) => unawaited(
        _logger?.warn(
          'outbox.retry.watch_failed',
          'Watching the outbox for due retries failed: $e',
          error: e,
          stack: st,
        ),
      ),
    );
  }

  /// When [row] may be retried next, or null when it is not waiting.
  DateTime? _dueAt(OutboxMessage row) {
    if (row.status != 'pending') return null;
    final at = row.nextAttemptAt;
    if (at == null) return null;
    final floor = _lastDrain[row.accountId]?.add(minGap);
    if (floor != null && floor.isAfter(at)) return floor;
    return at;
  }

  void _arm() {
    _timer?.cancel();
    _timer = null;
    _nextWakeAt = null;
    DateTime? earliest;
    for (final row in _rows) {
      if (_draining.contains(row.accountId)) continue;
      final due = _dueAt(row);
      if (due == null) continue;
      if (earliest == null || due.isBefore(earliest)) earliest = due;
    }
    if (earliest == null) return;
    final delay = earliest.difference(_clock());
    _nextWakeAt = earliest;
    _timer = Timer(delay.isNegative ? Duration.zero : delay, _fire);
  }

  void _fire() {
    _timer = null;
    _nextWakeAt = null;
    final now = _clock();
    final due = <String, int>{};
    for (final row in _rows) {
      if (_draining.contains(row.accountId)) continue;
      final at = _dueAt(row);
      if (at == null || at.isAfter(now)) continue;
      due.update(row.accountId, (n) => n + 1, ifAbsent: () => 1);
    }
    for (final MapEntry(key: accountId, value: count) in due.entries) {
      unawaited(_drainAccount(accountId, count, now));
    }
    _arm();
  }

  Future<void> _drainAccount(String accountId, int count, DateTime now) async {
    _draining.add(accountId);
    _lastDrain[accountId] = now;
    unawaited(
      _logger?.info(
        'outbox.retry.due',
        'Retry time reached for $count queued message'
            '${count == 1 ? '' : 's'}; sending',
        accountId: accountId,
        data: {'due': count},
      ),
    );
    try {
      await _drain(accountId);
    } catch (e, st) {
      // The rows stay queued; the next retry or sync cycle tries again.
      unawaited(
        _logger?.warn(
          'outbox.retry.failed',
          'Sending the queued messages whose retry time came failed: $e',
          accountId: accountId,
          error: e,
          stack: st,
        ),
      );
    } finally {
      _draining.remove(accountId);
      if (_sub != null) _arm();
    }
  }

  void dispose() {
    unawaited(_sub?.cancel());
    _sub = null;
    _timer?.cancel();
    _timer = null;
    _nextWakeAt = null;
  }
}
