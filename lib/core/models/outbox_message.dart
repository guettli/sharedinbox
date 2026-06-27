/// A message queued for sending. One row per "Send" tap that hasn't reached
/// the server yet (because the device was offline, the server was down, or
/// the user explicitly asked to retry).
class OutboxMessage {
  const OutboxMessage({
    required this.id,
    required this.accountId,
    required this.subject,
    required this.to,
    required this.cc,
    required this.createdAt,
    required this.attempts,
    required this.status,
    this.lastError,
    this.nextAttemptAt,
  });

  final int id;
  final String accountId;
  final String subject;
  final List<String> to;
  final List<String> cc;
  final DateTime createdAt;
  final int attempts;
  final String? lastError;
  final DateTime? nextAttemptAt;

  /// 'pending' = automatically retried with backoff.
  /// 'failed'  = permanent error (5xx / invalid recipient / missing attachment);
  /// stays in the queue but is no longer retried automatically.
  final String status;

  bool get isFailed => status == 'failed';
}
