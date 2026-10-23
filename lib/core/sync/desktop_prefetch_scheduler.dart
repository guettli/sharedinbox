import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:sharedinbox/core/models/user_preferences.dart';
import 'package:sharedinbox/core/utils/logger.dart';

/// True on platforms where the body-prefetch WorkManager task is never
/// registered, so the running app has to prefetch in-process instead.
///
/// WorkManager only exists on Android/iOS; on Linux/macOS/Windows the
/// registration throws `MissingPluginException` (swallowed), and without this
/// scheduler no body would ever be prefetched on desktop.
bool get needsInProcessBodyPrefetch =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows);

/// Runs the body prefetch ([runPrefetch], i.e. `BodyCacheService.run`, the
/// same work the WorkManager task does on Android) in-process while the app is
/// running, on platforms without WorkManager.
///
/// * Follows the stored [PrefetchMode]: `disabled` cancels the schedule, any
///   other mode (re)starts it.
/// * `wifiOnly` and `always` behave the same: desktop connections (wired or
///   Wi-Fi) are treated as unmetered. `connectivity_plus` is a dependency, but
///   it is deliberately not used on desktop (see `ConnectivityService`): it
///   crashes on headless Linux and cannot tell metered from unmetered there.
/// * The first run happens [initialDelay] after prefetch is enabled (so the
///   startup sync gets the network first and headers exist), then every
///   [interval] — the same hourly cadence as the WorkManager task.
/// * Runs never overlap: a tick that fires while a run is still in progress is
///   skipped.
class DesktopPrefetchScheduler {
  DesktopPrefetchScheduler({
    required Stream<PrefetchMode> modes,
    required Future<void> Function() runPrefetch,
    this.interval = const Duration(hours: 1),
    this.initialDelay = const Duration(minutes: 1),
  })  : _modes = modes,
        _runPrefetch = runPrefetch;

  final Stream<PrefetchMode> _modes;
  final Future<void> Function() _runPrefetch;
  final Duration interval;
  final Duration initialDelay;

  StreamSubscription<PrefetchMode>? _sub;
  Timer? _timer;
  bool _running = false;

  /// Whether a prefetch run is currently scheduled.
  @visibleForTesting
  bool get isScheduled => _timer != null;

  /// Starts following the prefetch preference. Calling it again is a no-op.
  void start() {
    _sub ??= _modes.distinct().listen(_onMode);
  }

  void _onMode(PrefetchMode mode) {
    if (mode == PrefetchMode.disabled) {
      _cancelTimer();
      return;
    }
    // wifiOnly <-> always: same behaviour on desktop, keep the schedule.
    if (_timer != null) return;
    _timer = Timer(initialDelay, () {
      _timer = Timer.periodic(interval, (_) => unawaited(_tick()));
      unawaited(_tick());
    });
  }

  Future<void> _tick() async {
    if (_running) return;
    _running = true;
    try {
      await _runPrefetch();
    } catch (e, st) {
      log('in-process body prefetch failed', error: e, stackTrace: st);
    } finally {
      _running = false;
    }
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    _cancelTimer();
    unawaited(_sub?.cancel());
    _sub = null;
  }
}
