import '../models/email.dart';

abstract class EmailRepository {
  Stream<List<Email>> observeEmails(String accountId, String mailboxPath);

  /// Groups emails by threadId and returns one [EmailThread] per thread,
  /// sorted by the latest message date descending.
  Stream<List<EmailThread>> observeThreads(
    String accountId,
    String mailboxPath,
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
  Future<void> deleteEmail(String emailId);
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

  /// Searches the local DB across all mailboxes of [accountId] by subject
  /// and preview. Fast, works offline, intended for incremental search UI.
  Future<List<Email>> searchEmailsGlobal(String accountId, String query);

  /// Returns all locally cached emails in any mailbox of [accountId] whose
  /// from, to, or cc fields contain [address].
  Future<List<Email>> getEmailsByAddress(String accountId, String address);

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

  /// Returns a stream that emits once for each JMAP push event (RFC 8887
  /// `StateChange`) received from the server's EventSource URL.
  ///
  /// Completes immediately — emitting nothing — if the account does not
  /// support push (IMAP accounts, or JMAP servers without an eventSourceUrl).
  /// Callers should fall back to polling when the stream ends.
  Stream<void> watchJmapPush(String accountId, String password);
}
