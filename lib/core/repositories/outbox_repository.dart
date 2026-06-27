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
  Future<int> flush(
    String accountId,
    Future<void> Function(OutboxJob job) sender, {
    DateTime? now,
  });

  /// Emits the current list of queued messages for [accountId], live.
  Stream<List<OutboxMessage>> observeOutbox(String accountId);

  /// Resets the attempt counter / backoff on a single row so it is eligible
  /// the next flush. No-op if the row no longer exists.
  Future<void> retry(int id);

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
