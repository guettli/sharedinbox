import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/services/crash_logger.dart';

/// How long one OS notification may take before we give up on it. A healthy
/// notification daemon answers within milliseconds; this only bounds a D-Bus
/// call that never gets a reply.
const kNotificationShowTimeout = Duration(seconds: 5);

/// Receives a notification failure: a readable [message] plus the [error]
/// (a [TimeoutException] for a show that never answered) and its [stack].
typedef NotificationFailureHandler = void Function(
  String message,
  Object error,
  StackTrace? stack,
);

/// Default [NotificationFailureHandler]: prints the failure and records it in
/// the App Log as a warning, so bug reports show why no notification popped up.
void logNotificationFailure(String message, Object error, StackTrace? stack) {
  debugPrint(message);
  logUncaught(
    'notification.show_failed',
    message,
    error,
    stack,
    level: AppLogLevel.warn,
  );
}

/// Runs [show] so that a failing or hanging notification backend can never
/// escape to the caller: an exception is caught and a call that does not
/// complete within [timeout] is abandoned. Returns whether the notification
/// was shown.
///
/// On Linux without a notification daemon the plugin throws
/// `DBusServiceUnknownException`. Uncaught, it reached `FlutterError.onError`
/// from the unawaited dispatcher, which froze the app (#1107).
Future<bool> guardNotificationShow(
  Future<void> Function() show, {
  Duration timeout = kNotificationShowTimeout,
  NotificationFailureHandler onFailure = logNotificationFailure,
}) async {
  try {
    await show().timeout(timeout);
    return true;
  } on TimeoutException catch (e, st) {
    onFailure(
      'Notification not shown: no reply within ${timeout.inMilliseconds} ms',
      e,
      st,
    );
  } catch (e, st) {
    onFailure('Notification not shown: $e', e, st);
  }
  return false;
}
