/// A single row in the outbound `pending_changes` queue.
///
/// The queue holds local mutations (flag, move, delete, append) that have
/// been applied optimistically to the local DB and still need to be pushed to
/// the server. Rows normally live only for as long as the next sync cycle
/// takes to flush them; a row that survives many cycles is stuck (bad
/// credentials, broken server, permanent error) and the Pending Changes
/// screen surfaces it so the user can Retry or Discard.
class PendingChange {
  const PendingChange({
    required this.id,
    required this.accountId,
    required this.kind,
    required this.resourceType,
    required this.resourceId,
    required this.payload,
    required this.createdAt,
    required this.attempts,
    this.lastError,
  });

  final int id;
  final String accountId;

  /// "flag_seen" | "flag_flagged" | "move" | "delete" | ...
  final String kind;

  /// e.g. "Email".
  final String resourceType;

  /// The id of the affected local row (email id).
  final String resourceId;

  /// JSON payload describing the mutation, e.g. `{"seen": true}` or
  /// `{"dest": "Archive"}`. Kept opaque here so the model does not depend
  /// on protocol details.
  final String payload;

  final DateTime createdAt;
  final int attempts;
  final String? lastError;

  bool get hasError => lastError != null;
}
