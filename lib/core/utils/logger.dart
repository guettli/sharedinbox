import 'package:flutter/foundation.dart';

/// Thin wrapper around [debugPrint] so log calls are easy to find and
/// can be swapped for a structured logger later without touching callers.
void log(String message, {Object? error, StackTrace? stackTrace}) {
  if (error != null) {
    debugPrint('[SharedInbox] $message — $error');
    if (stackTrace != null) debugPrint(stackTrace.toString());
  } else {
    debugPrint('[SharedInbox] $message');
  }
}
