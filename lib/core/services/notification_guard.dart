import 'dart:async';

import 'package:flutter/foundation.dart';

/// How long one OS notification may take before we give up on it. A healthy
/// notification daemon answers within milliseconds; this only bounds a D-Bus
/// call that never gets a reply.
const kNotificationShowTimeout = Duration(seconds: 5);

/// Runs [show] so that a failing or hanging notification backend can never
/// escape to the caller: an exception is caught and a call that does not
/// complete within [timeout] is abandoned. Returns whether the notification
/// was shown.
///
/// Every new-mail notification goes through here. The callers fire it from
/// the sync loop without awaiting the result (or right before
/// `markNotified`), so an escaping error used to become an uncaught zone
/// error. On Linux without a notification daemon that error
/// (`DBusServiceUnknownException`) reached `FlutterError.onError`, which
/// froze the app (#1107), and `markNotified` never ran, so the next start hit
/// the same mail again.
Future<bool> guardNotificationShow(
  Future<void> Function() show, {
  Duration timeout = kNotificationShowTimeout,
  void Function(String message)? onWarning,
}) async {
  final warn = onWarning ?? debugPrint;
  try {
    await show().timeout(timeout);
    return true;
  } on TimeoutException {
    warn('Notification not shown: no reply within ${timeout.inSeconds}s');
  } catch (e) {
    warn('Notification not shown: $e');
  }
  return false;
}
