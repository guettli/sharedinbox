import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/outbox_message.dart';

/// Persistent send queue. Sits between the compose UI and the live SMTP / JMAP
/// network calls so that "Send" always returns immediately and the actual
/// transmission is retried on the next sync cycle once the device is online.
abstract class OutboxRepository {
  /// Persists [draft] for later sending and returns the new outbox row id.
  /// Always returns immediately — does not touch the network.
  Future<int> enqueue(String accountId, EmailDraft draft);

  /// Drains pending outbox rows for [accountId] by handing each one to the
  /// supplied [sender]. Rows whose sender call returns normally are deleted;
  /// rows that throw [PermanentSendException] are marked `failed`; any other
  /// exception is recorded with exponential backoff for the next attempt.
  /// Returns the number of rows successfully sent.
  ///
  /// When [observer] is supplied it is notified of each outcome so callers
  /// (e.g. the [EmailRepository] flush wrapper) can mirror the events into the
  /// application log without this repository having to depend on any logger.
  Future<int> flush(
    String accountId,
    Future<void> Function(OutboxJob job) sender, {
    DateTime? now,
    OutboxFlushObserver? observer,
  });

  /// Emits the current list of queued messages for [accountId], live.
  Stream<List<OutboxMessage>> observeOutbox(String accountId);

  /// Emits every queued message across all accounts, live. Powers the global
  /// "Sent Queue" view where the user wants a single list of everything
  /// waiting to leave the device.
  Stream<List<OutboxMessage>> observeAllOutbox();

  /// Resets the attempt counter / backoff on a single row so it is eligible
  /// the next flush. No-op if the row no longer exists.
  Future<void> retry(int id);

  /// Clears `nextAttemptAt` on every `pending` row across every account so
  /// the next [flush] call picks them up immediately. Used by the reconnect
  /// handler in `di.dart` — when the device comes back online, waiting for
  /// the current per-row backoff (up to an hour) to elapse would defeat the
  /// point of "send as soon as we're back online" (#353). The attempt counter
  /// is kept so the next backoff still ramps if the send fails again.
  /// Returns the number of rows whose backoff was cleared.
  Future<int> resetPendingBackoff();

  /// Permanently removes a queued message.
  Future<void> discard(int id);
}

/// Thrown by a sender to indicate the row should be marked `failed` and not
/// retried automatically. Use for 5xx SMTP rejections, missing-attachment
/// errors, invalid recipient — anything where the next retry will fail the
/// same way.
class PermanentSendException implements Exception {
  PermanentSendException(this.message);
  final String message;

  @override
  String toString() => 'PermanentSendException: $message';
}

/// Callback hooks invoked by [OutboxRepository.flush] for each row so the
/// caller can mirror send outcomes into the application log. Every hook is
/// best-effort — thrown exceptions are swallowed so a broken logger cannot
/// break the flush.
class OutboxFlushObserver {
  const OutboxFlushObserver({
    this.onAttempt,
    this.onOk,
    this.onTransient,
    this.onPermanent,
  });

  /// Fires once per row just before [OutboxRepository.flush] calls the
  /// sender. [attempts] is the pre-attempt counter (0 on the first try).
  final void Function(OutboxJob job)? onAttempt;

  /// Fires once per row when the sender returned normally and the row has
  /// been deleted from the queue.
  final void Function(OutboxJob job)? onOk;

  /// Fires when the sender threw a non-[PermanentSendException] and the row
  /// was rescheduled with backoff. [nextAttemptAt] is the wall-clock time the
  /// next attempt is eligible.
  final void Function(
    OutboxJob job,
    Object error,
    StackTrace stack,
    DateTime nextAttemptAt,
  )? onTransient;

  /// Fires when the sender threw [PermanentSendException] and the row was
  /// marked `failed`.
  final void Function(OutboxJob job, PermanentSendException error)? onPermanent;
}

/// Decoded payload of a single outbox row — what a sender receives.
class OutboxJob {
  const OutboxJob({
    required this.id,
    required this.accountId,
    required this.draft,
    required this.mimeBytes,
    required this.attempts,
  });

  final int id;
  final String accountId;
  final EmailDraft draft;
  final List<int> mimeBytes;
  final int attempts;
}
