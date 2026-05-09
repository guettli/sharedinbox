import 'package:sharedinbox/core/models/email.dart';

abstract class EmailRepository {
  Stream<List<Email>> observeEmails(String accountId, String mailboxPath);

  /// Groups emails by threadId and returns one [EmailThread] per thread,
  /// sorted by the latest message date descending.
  Stream<List<EmailThread>> observeThreads(
    String accountId,
    String mailboxPath,
  );

  /// Returns all emails belonging to [threadId] in [mailboxPath].
  Stream<List<Email>> observeEmailsInThread(
    String accountId,
    String mailboxPath,
    String threadId,
  );

  Future<Email?> getEmail(String emailId);

  Future<EmailBody> getEmailBody(String emailId);
  Future<SyncEmailsResult> syncEmails(String accountId, String mailboxPath);
  Future<void> setFlag(
    String emailId, {
    bool? seen,
    bool? flagged,
  });
  Future<void> moveEmail(String emailId, String destMailboxPath);

  /// Deletes the email. Returns the path of the mailbox it was moved to
  /// (e.g. Trash) if it was a soft-delete, or null if it was hard-deleted.
  Future<String?> deleteEmail(String emailId);

  Future<void> sendEmail(String accountId, EmailDraft draft);

  /// Downloads [attachment] bytes from the server (or local cache) and returns
  /// the local file-system path.  Subsequent calls for the same attachment
  /// return the cached path without a network round-trip.
  Future<String> downloadAttachment(String emailId, EmailAttachment attachment);

  /// Returns emails in [mailboxPath] whose subject or body contain [query].
  /// Results come from the server (IMAP SEARCH) and are not cached.
  Future<List<Email>> searchEmails(
    String accountId,
    String mailboxPath,
    String query,
  );

  /// Searches the local DB across all mailboxes of [accountId] (or all accounts
  /// if null) by subject and preview. Fast, works offline.
  Future<List<Email>> searchEmailsGlobal(String? accountId, String query);

  /// Returns all locally cached emails in any mailbox of [accountId] (or all
  /// accounts if null) whose from, to, or cc fields contain [address].
  Future<List<Email>> getEmailsByAddress(String? accountId, String address);

  /// Sends any queued local mutations for [accountId] to the server.
  /// Returns the number of changes successfully applied.
  Future<int> flushPendingChanges(String accountId, String password);

  /// Emits the list of pending mutations that have failed at least once for
  /// [accountId]. Updates live whenever the queue changes.
  Stream<List<FailedMutation>> observeFailedMutations(String accountId);

  /// Permanently removes the pending mutation with [id] from the queue.
  Future<void> discardMutation(int id);

  /// Resets the attempt counter for mutation [id] so the next sync cycle
  /// retries it.
  Future<void> retryMutation(int id);

  /// Tries to remove a pending change for [emailId] of [changeType] from the
  /// queue. Returns true if a pending change was found and removed.
  Future<bool> cancelPendingChange(String emailId, String changeType);

  /// Restores previously deleted/moved emails to the local database.
  /// Used for the "Undo" feature when the original rows were hard-deleted (IMAP).
  Future<void> restoreEmails(List<Email> emails);

  /// Emits the accountId whenever a new change is enqueued locally.
  /// Used by AccountSyncManager to trigger an immediate flush.
  Stream<String> get onChangesQueued;

  /// Returns a stream that emits once for each JMAP push event (RFC 8887
  /// `StateChange`) received from the server's EventSource URL.
  ///
  /// Completes immediately — emitting nothing — if the account does not
  /// support push (IMAP accounts, or JMAP servers without an eventSourceUrl).
  /// Callers should fall back to polling when the stream ends.
  Stream<void> watchJmapPush(String accountId, String password);

  /// Compares local UIDs/IDs against the server's "ground truth" for [mailboxPath].
  /// Returns a [ReliabilityResult] containing any discrepancies found.
  Future<ReliabilityResult> verifySyncReliability(
    String accountId,
    String mailboxPath,
  );
}
