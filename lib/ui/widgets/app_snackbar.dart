import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/di.dart';

/// Type of the controller returned by [ScaffoldMessengerState.showSnackBar].
typedef SnackBarController
    = ScaffoldFeatureController<SnackBar, SnackBarClosedReason>;

/// Every SnackBar in the app is raised through this helper so the message is
/// *also* written to the App Log ([AppLogger]). This makes user-facing
/// feedback discoverable after the snack has faded — including in bug reports
/// — and, when the snack concerns one email, lets the App Log render a
/// hyperlink back to that message (see `app_log_screen.dart`).
///
/// Two entry points share the same behaviour:
///
///  * [AppSnackBar.showAppSnackBar] on [BuildContext] — the common case.
///  * [BuildContext.appMessenger], which captures the messenger + logger
///    *before* an `await` so callers can still surface (and log) feedback
///    once the originating `context` is no longer safe to touch.
///
/// Logging is best-effort: if no [ProviderScope] is in scope (e.g. the crash
/// boundary that renders before `runApp`), the snack is still shown and the
/// log write is silently skipped.
class AppMessenger {
  AppMessenger(this._messenger, this._logger, this._screen);

  final ScaffoldMessengerState _messenger;
  final AppLogger? _logger;
  final String? _screen;

  /// Shows [message] as a SnackBar and records it in the App Log at [level].
  ///
  /// Pass [emailId] (and [accountId]/[mailboxPath] when known) whenever the
  /// message concerns a single email, so the App Log entry can link to it.
  SnackBarController show(
    String message, {
    AppLogLevel level = AppLogLevel.info,
    String event = 'ui.snackbar',
    Map<String, Object?>? data,
    String? emailId,
    String? accountId,
    String? mailboxPath,
    SnackBarAction? action,
    Duration duration = const Duration(seconds: 4),
    bool? persist,
    Widget? content,
    Color? backgroundColor,
    Object? error,
    StackTrace? stack,
  }) {
    final logger = _logger;
    if (logger != null) {
      unawaited(
        logger.log(
          level: level,
          event: event,
          message: message,
          data: data,
          screen: _screen,
          emailId: emailId,
          accountId: accountId,
          mailboxPath: mailboxPath,
          error: error,
          stack: stack,
        ),
      );
    }
    return _messenger.showSnackBar(
      SnackBar(
        // [message] always drives the log entry; [content], when given, lets a
        // caller render richer UI (e.g. a progress row) than plain text.
        content: content ?? Text(message),
        action: action,
        duration: duration,
        persist: persist,
        backgroundColor: backgroundColor,
      ),
    );
  }
}

extension AppSnackBar on BuildContext {
  /// Captures the [ScaffoldMessengerState] and [AppLogger] for this context so
  /// feedback can be shown (and logged) after an `await`, when touching the
  /// originating `context` would be unsafe. Grab this *before* the async gap:
  ///
  /// ```dart
  /// final messenger = context.appMessenger();
  /// final result = await doWork();
  /// messenger.show('Done', level: AppLogLevel.info);
  /// ```
  AppMessenger appMessenger() {
    AppLogger? logger;
    try {
      logger = ProviderScope.containerOf(this, listen: false)
          .read(appLoggerProvider);
    } catch (_) {
      // No ProviderScope above this context (e.g. crash boundary) — the snack
      // still shows, we just cannot log it.
    }
    return AppMessenger(
      ScaffoldMessenger.of(this),
      logger,
      ModalRoute.of(this)?.settings.name,
    );
  }

  /// Shows [message] as a SnackBar and records it in the App Log at [level].
  ///
  /// Pass [emailId] (and [accountId]/[mailboxPath] when known) whenever the
  /// message concerns a single email, so the App Log entry can link to it.
  SnackBarController showAppSnackBar(
    String message, {
    AppLogLevel level = AppLogLevel.info,
    String event = 'ui.snackbar',
    Map<String, Object?>? data,
    String? emailId,
    String? accountId,
    String? mailboxPath,
    SnackBarAction? action,
    Duration duration = const Duration(seconds: 4),
    bool? persist,
    Widget? content,
    Color? backgroundColor,
    Object? error,
    StackTrace? stack,
  }) =>
      appMessenger().show(
        message,
        level: level,
        event: event,
        data: data,
        emailId: emailId,
        accountId: accountId,
        mailboxPath: mailboxPath,
        action: action,
        duration: duration,
        persist: persist,
        content: content,
        backgroundColor: backgroundColor,
        error: error,
        stack: stack,
      );
}
