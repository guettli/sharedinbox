import 'dart:async';

import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';

/// Application-wide logger for the *global* error handlers that run outside any
/// widget or `ProviderScope`: `FlutterError.onError`, the `runZonedGuarded`
/// zone handler (both in `main.dart`) and [ErrorBoundary]'s async capture path.
///
/// Those handlers cannot `ref.read(appLoggerProvider)`, so — mirroring the
/// `appLogNavigatorObserver.logger` pattern — this holder is populated once the
/// app is up (see `_SharedInboxAppState.initState`). Until then (e.g. a crash
/// during early startup, before the first frame) [logUncaught] is a no-op; the
/// crash UI still shows the error text in that window.
AppLogger? crashLogger;

/// Records an uncaught error in the App Log, best-effort, so it is discoverable
/// on the App Log screen and in bug reports (issue #534).
///
/// Safe to call from any error handler: it never throws and never blocks (the
/// insert is fire-and-forget), so it can never re-enter the handler that
/// invoked it — guarding against `FlutterError.onError` loops.
void logUncaught(
  String event,
  String message,
  Object error,
  StackTrace? stack, {
  AppLogLevel level = AppLogLevel.error,
  String? screen,
  String? accountId,
  String? emailId,
}) {
  final logger = crashLogger;
  if (logger == null) return;
  try {
    unawaited(
      logger.log(
        level: level,
        event: event,
        message: message,
        error: error,
        stack: stack,
        screen: screen,
        accountId: accountId,
        emailId: emailId,
      ),
    );
  } catch (_) {
    // Logging is strictly best-effort; a failure while handling an error must
    // never propagate back into the error handler.
  }
}

/// Installs the full-screen crash UI from `FlutterError.onError`, safely.
///
/// Async errors reach `onError` from the `runZonedGuarded` handler, which runs
/// in the *parent* zone. Calling `runApp` there trips Flutter's debug "Zone
/// mismatch" check, which reports a `FlutterError` synchronously back into
/// `onError` — and `onError` used to call `runApp` again, a loop that never
/// yielded and froze the app (#1107). So [install] runs the callback in the
/// zone the binding was initialized in, and ignores calls made while it is
/// already installing.
class CrashScreenInstaller {
  CrashScreenInstaller(this._zone);

  final Zone _zone;
  bool _installing = false;

  void install(void Function() runCrashApp) {
    if (_installing) return;
    _installing = true;
    try {
      _zone.run(runCrashApp);
    } finally {
      _installing = false;
    }
  }
}
