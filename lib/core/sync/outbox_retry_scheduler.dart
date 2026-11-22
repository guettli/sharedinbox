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
    this.failureBackoff = const [
      Duration(seconds: 30),
      Duration(minutes: 2),
      Duration(minutes: 10),
      Duration(hours: 1),
    ],
  })  : _outbox = outbox,
        _drain = drain,
        _logger = logger,
        _clock = clock;

  final Stream<List<OutboxMessage>> _outbox;
  final Future<void> Function(String accountId) _drain;
  final AppLogger? _logger;
  final DateTime Function() _clock;

  /// Least time between the end of one drain of an account and the next. A
  /// drain that left a due row due (the row was being edited) would
  /// otherwise re-arm a zero timer and spin.
  final Duration minGap;

  /// Wait after the n-th drain in a row that threw (no password readable
  /// from a locked keyring, …), capped at the last entry. A throwing drain
  /// never reaches the row, so its retry time does not move and [minGap]
  /// alone would retry and log every 30 s forever.
  final List<Duration> failureBackoff;

  StreamSubscription<List<OutboxMessage>>? _sub;
  List<OutboxMessage> _rows = const [];
  Timer? _timer;
  final Set<String> _draining = {};
  final Map<String, DateTime> _lastDrain = {};
  final Map<String, _Failures> _failures = {};

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
        _forgetFailuresOfChangedRows();
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

  /// Arms the timer again from the wall clock. A [Timer] runs on a monotonic
  /// clock, so a laptop suspend or Android doze delays it; call this when
  /// the app resumes.
  void rearm() {
    if (_sub == null) return;
    _arm();
  }

  /// The retry state of [accountId]'s waiting rows: when it changes, a drain
  /// reached them (or the user reset them), so an earlier failure is moot.
  String _signature(String accountId) => [
        for (final row in _rows)
          if (row.accountId == accountId && row.status == 'pending')
            '${row.id}:${row.attempts}:'
                '${row.nextAttemptAt?.millisecondsSinceEpoch}',
      ].join(',');

  void _forgetFailuresOfChangedRows() {
    _failures.removeWhere(
      (accountId, f) => f.signature != _signature(accountId),
    );
  }

  /// When [row] may be retried next, or null when it is not waiting.
  DateTime? _dueAt(OutboxMessage row) {
    if (row.status != 'pending') return null;
    final at = row.nextAttemptAt;
    if (at == null) return null;
    var due = at;
    final floor = _lastDrain[row.accountId]?.add(minGap);
    if (floor != null && floor.isAfter(due)) due = floor;
    final backoff = _failures[row.accountId]?.until;
    if (backoff != null && backoff.isAfter(due)) due = backoff;
    return due;
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
    final due = <String>{};
    for (final row in _rows) {
      if (_draining.contains(row.accountId)) continue;
      final at = _dueAt(row);
      if (at == null || at.isAfter(now)) continue;
      due.add(row.accountId);
    }
    for (final accountId in due) {
      unawaited(_drainAccount(accountId));
    }
    _arm();
  }

  Future<void> _drainAccount(String accountId) async {
    _draining.add(accountId);
    final signature = _signature(accountId);
    unawaited(
      _logger?.info(
        'outbox.retry.due',
        'Retry time reached for queued messages; sending',
        accountId: accountId,
      ),
    );
    try {
      await _drain(accountId);
      _failures.remove(accountId);
    } catch (e, st) {
      // The rows stay queued; the next retry or sync cycle tries again.
      final previous = _failures[accountId];
      final count = (previous?.count ?? 0) + 1;
      final wait =
          failureBackoff[(count - 1).clamp(0, failureBackoff.length - 1)];
      final error = e.toString();
      _failures[accountId] = _Failures(
        count: count,
        until: _clock().add(wait),
        signature: signature,
        error: error,
      );
      // Logged once per distinct error, not on every retry.
      if (previous?.error != error) {
        unawaited(
          _logger?.warn(
            'outbox.retry.failed',
            'Sending the queued messages whose retry time came failed: $e',
            accountId: accountId,
            data: {'nextTryInSeconds': wait.inSeconds},
            error: e,
            stack: st,
          ),
        );
      }
    } finally {
      _draining.remove(accountId);
      _lastDrain[accountId] = _clock();
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

/// Drains of one account that threw in a row.
class _Failures {
  const _Failures({
    required this.count,
    required this.until,
    required this.signature,
    required this.error,
  });

  final int count;

  /// No drain of the account before this time.
  final DateTime until;

  /// [OutboxRetryScheduler._signature] when the drain started.
  final String signature;
  final String error;
}
