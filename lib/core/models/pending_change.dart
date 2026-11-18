/// Failed attempts after which a queued change counts as
/// [PendingChange.stuck]: still retried, with a growing backoff, and shown as
/// "not synced yet" (SYNC.md §6).
const int maxPendingChangeAttempts = 5;

/// A single row in the outbound `pending_changes` queue.
///
/// The queue holds local mutations (flag, move, delete, append) that have
/// been applied optimistically to the local DB and still need to be pushed to
/// the server. Rows normally live only for as long as the next sync cycle
/// takes to flush them. A change that keeps failing is retried up to
/// [maxPendingChangeAttempts] times; then, or at once when the server refuses
/// it, it becomes [failed]: no longer flushed, and the local mail shows the
/// server's state again. The Pending Changes screen surfaces it so the user
/// can Retry or Discard.
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
    this.failed = false,
    this.sending = false,
    this.stuck = false,
    this.nextTry,
    this.parked = false,
    this.waitingForFolder,
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

  /// The app gave up on this change (retry limit reached or refused by the
  /// server). It is not flushed again until the user retries it. A change
  /// with a [lastError] that is not [failed] is still being retried.
  final bool failed;

  /// A flush claimed this change and may be sending it right now. It can no
  /// longer be cancelled; Undo queues a reverse change instead.
  final bool sending;

  /// It failed [maxPendingChangeAttempts] times in a way that may pass: it
  /// keeps the user's value locally and is retried at [nextTry].
  final bool stuck;
  final DateTime? nextTry;

  /// The mail has no server copy yet (a self-sent note waiting for its
  /// delivery, a JMAP mail whose server id is unknown): the change shows
  /// locally and is sent once the server copy is found.
  final bool parked;

  /// The name of a folder created offline (not on the server yet) that the
  /// change needs: it waits for the folder's creation and is sent right
  /// after it (SYNC.md §6b). Derived when read; the change stays queued.
  final String? waitingForFolder;

  bool get hasError => lastError != null;
}
