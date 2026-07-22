import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:meta/meta.dart';

/// Watches device connectivity and emits a signal each time the device
/// transitions from offline to online.
///
/// The signal is consumed to kick the outbox flush (see [di.dart]) so that a
/// mail queued while the device was offline is delivered as soon as the
/// network comes back, rather than waiting for the next 15-minute background
/// sync tick or the current per-row backoff to elapse.
///
/// Safe to construct on platforms where the `connectivity_plus` platform
/// channel is missing (desktop, unit tests, older Android): [initialize] then
/// swallows the [MissingPluginException] and the reconnect kick becomes a
/// no-op — the rest of the app is unaffected.
class ConnectivityService {
  ConnectivityService({
    Duration debounce = const Duration(seconds: 2),
    bool initialOnline = true,
    DateTime Function() clock = _defaultClock,
  })  : _debounce = debounce,
        _wasOnline = initialOnline,
        _clock = clock;

  final Duration _debounce;
  final DateTime Function() _clock;

  StreamSubscription<List<ConnectivityResult>>? _sub;
  final _onlineCtrl = StreamController<void>.broadcast();

  bool _wasOnline;
  DateTime _lastEmit = DateTime.fromMillisecondsSinceEpoch(0);

  /// Fires each time the device transitions offline → online. Coalesces bursts
  /// (e.g. wifi ↔ mobile handoffs) to at most one event per debounce window so
  /// consumers don't see a storm of kicks during a flaky handover.
  Stream<void> get onOnline => _onlineCtrl.stream;

  /// Subscribes to the platform connectivity stream. Idempotent-ish: safe to
  /// call twice, but a second call replaces any prior subscription.
  Future<void> initialize() async {
    try {
      final connectivity = Connectivity();
      final initial = await connectivity.checkConnectivity();
      _wasOnline = _isOnline(initial);
      await _sub?.cancel();
      _sub = connectivity.onConnectivityChanged.listen((results) {
        notify(online: _isOnline(results));
      });
    } on MissingPluginException {
      // Plugin unavailable — unit tests, unsupported platform. Reconnect kick
      // silently disabled; queued mail still drains via the periodic sync
      // cycle and manual retry.
    } catch (_) {
      // Any other failure (e.g. permission denied on Linux) is treated the
      // same way.
    }
  }

  /// Test seam: drive the state machine directly without a platform channel.
  /// Production code calls this from the `connectivity_plus` listener.
  @visibleForTesting
  void notify({required bool online}) {
    if (online && !_wasOnline) {
      final now = _clock();
      if (now.difference(_lastEmit) >= _debounce) {
        _lastEmit = now;
        if (!_onlineCtrl.isClosed) _onlineCtrl.add(null);
      }
    }
    _wasOnline = online;
  }

  void dispose() {
    unawaited(_sub?.cancel());
    unawaited(_onlineCtrl.close());
  }

  static DateTime _defaultClock() => DateTime.now();

  static bool _isOnline(List<ConnectivityResult> results) {
    if (results.isEmpty) return false;
    return results.any((r) => r != ConnectivityResult.none);
  }
}
