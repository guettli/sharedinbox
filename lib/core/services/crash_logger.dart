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
      ),
    );
  } catch (_) {
    // Logging is strictly best-effort; a failure while handling an error must
    // never propagate back into the error handler.
  }
}
