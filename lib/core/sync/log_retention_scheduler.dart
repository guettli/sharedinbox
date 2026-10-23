import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:sharedinbox/core/utils/logger.dart';

/// Trims the retained log tables (`app_logs`, `sync_logs`) at launch and then
/// every [interval] while the app runs.
///
/// A desktop app often runs for days, so trimming only at launch lets the logs
/// grow without bound until the next restart (#1135).
///
/// * Runs never overlap: a tick that fires while a trim is still running is
///   skipped.
/// * Failures (e.g. the database was already closed) are logged and ignored.
class LogRetentionScheduler {
  LogRetentionScheduler({
    required Future<void> Function() trim,
    this.interval = const Duration(hours: 6),
  }) : _trim = trim;

  final Future<void> Function() _trim;
  final Duration interval;

  Timer? _timer;
  bool _trimming = false;

  /// Whether the periodic trim is scheduled.
  @visibleForTesting
  bool get isScheduled => _timer != null;

  /// Trims once now and schedules the periodic trim. Calling it again is a
  /// no-op.
  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) => unawaited(_runTrim()));
    unawaited(_runTrim());
  }

  Future<void> _runTrim() async {
    if (_trimming) return;
    _trimming = true;
    try {
      await _trim();
    } catch (e, st) {
      log('log retention trim failed', error: e, stackTrace: st);
    } finally {
      _trimming = false;
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
