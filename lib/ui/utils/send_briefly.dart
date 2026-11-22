import 'dart:async';

import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';

/// How long a send started from the UI waits for its first delivery attempt
/// before the screen moves on and the attempt finishes in the background
/// (#1331, #1351). Long enough for a healthy server to accept the message or
/// reject a recipient, short enough that a dead link does not hold the UI.
const sendResultWait = Duration(seconds: 2);

/// Runs the first delivery attempt of the already queued outbox row
/// [outboxRowId] and waits at most [sendResultWait] for it.
///
/// Returns the result when it came in time; a send that throws in time
/// throws here. Otherwise returns null, and once the attempt ends calls
/// [onLate] with its result or [onLateError] with what it threw. Those run
/// after the calling screen may be gone, so they should only use the app's
/// messenger. Should that be gone too (the app is closing) and a callback
/// throw, this is logged as [unshownEvent], so the outcome still reaches the
/// App Log.
Future<SendNowResult?> sendNowBriefly(
  EmailRepository repo,
  AppLogger logger, {
  required String accountId,
  required int outboxRowId,
  required String unshownEvent,
  required void Function(SendNowResult result) onLate,
  required void Function(Object error, StackTrace stack) onLateError,
}) async {
  final sending = repo
      .sendNow(accountId, outboxRowId: outboxRowId)
      .then<SendNowResult?>((r) => r);
  final result = await sending.timeout(
    sendResultWait,
    onTimeout: () => null,
  );
  if (result != null) return result;

  void report(void Function() show) {
    try {
      show();
    } catch (e, stack) {
      unawaited(
        logger.warn(
          unshownEvent,
          'Could not show how a background send ended: $e',
          accountId: accountId,
          error: e,
          stack: stack,
        ),
      );
    }
  }

  unawaited(
    sending.then(
      (r) => report(() => onLate(r!)),
      onError: (Object e, StackTrace stack) =>
          report(() => onLateError(e, stack)),
    ),
  );
  return null;
}
