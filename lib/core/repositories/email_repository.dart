import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/pending_change.dart';

export 'package:sharedinbox/core/sieve/sieve_parser.dart'
    show SieveParseException;

abstract class EmailRepository {
  Stream<List<Email>> observeEmails(
    String accountId,
    String mailboxPath, {
    int limit = 50,
  });

  /// Groups emails by threadId and returns one [EmailThread] per thread,
  /// sorted by the latest message date descending.
  Stream<List<EmailThread>> observeThreads(
    String accountId,
    String mailboxPath, {
    int limit = 50,
  });

  /// Returns threads from the INBOX mailbox of every account, sorted by latest
  /// message date descending. Inbox mailboxes are identified by role = 'inbox'.
  Stream<List<EmailThread>> observeAllInboxThreads({int limit = 50});

  /// Returns all emails belonging to [threadId] in [mailboxPath].
  Stream<List<Email>> observeEmailsInThread(
    String accountId,
    String mailboxPath,
    String threadId,
  );

  Future<Email?> getEmail(String emailId);

  /// Returns the body for [emailId], using the local cache when fresh.
  ///
  /// When [forceRefresh] is true, the cache is bypassed and a network fetch
  /// is performed. The result is then written back to the cache.
  Future<EmailBody> getEmailBody(String emailId, {bool forceRefresh = false});
  Future<SyncEmailsResult> syncEmails(String accountId, String mailboxPath);
  Future<void> setFlag(String emailId, {bool? seen, bool? flagged});
  Future<void> markAllAsRead(String accountId, String mailboxPath);
  Future<void> moveEmail(String emailId, String destMailboxPath);

  /// Deletes the email. Returns the path of the mailbox it was moved to
  /// (e.g. Trash) if it was a soft-delete, or null if it was hard-deleted.
  Future<String?> deleteEmail(String emailId);

  /// Sends [draft] synchronously. Throws on network/protocol failure.
  /// Prefer [enqueueSend] for user-initiated compose actions so the UI does
  /// not block on connectivity.
  Future<void> sendEmail(String accountId, EmailDraft draft);

  /// Persists [draft] in the offline send queue. Always returns immediately —
  /// transmission happens on the next sync cycle (see [flushOutbox]).
  /// Returns the new outbox row id.
  Future<int> enqueueSend(String accountId, EmailDraft draft);

  /// Drains queued outbox messages for [accountId] via the appropriate
  /// protocol. Called from [AccountSyncManager] on every sync cycle.
  /// Returns the number of messages successfully transmitted.
  Future<int> flushOutbox(String accountId, String password);

  /// Downloads [attachment] bytes from the server (or local cache) and returns
  /// the local file-system path.  Subsequent calls for the same attachment
  /// return the cached path without a network round-trip.
  Future<String> downloadAttachment(String emailId, EmailAttachment attachment);

  /// Fetches the original RFC 2822 message from the server as a raw string.
  /// Always performs a live network request — the raw message is not cached.
  Future<String> fetchRawRfc822(String emailId);

  /// Returns emails in [mailboxPath] whose subject or body contain [query].
  /// Results come from the server (IMAP SEARCH) and are not cached.
  Future<List<Email>> searchEmails(
    String accountId,
    String mailboxPath,
    String query,
  );

  /// Searches the local DB across all mailboxes of [accountId] (or all accounts
  /// if null) by subject, preview, and notes. Fast, works offline.
  Future<List<Email>> searchEmailsGlobal(String? accountId, String query);

  /// Searches the local DB using a structured [FilterGroup]. Fast, works offline.
  Future<List<Email>> searchEmailsStructured(
    String? accountId,
    FilterGroup filter,
  );

  /// Returns all locally cached emails in any mailbox of [accountId] (or all
  /// accounts if null) whose from, to, or cc fields contain [address].
  Future<List<Email>> getEmailsByAddress(String? accountId, String address);

  /// Returns unique email addresses from the local cache whose email or display
  /// name contains [query]. Results are deduplicated and capped at [limit].
  Future<List<EmailAddress>> searchAddresses(
    String? accountId,
    String query, {
    int limit = 10,
  });

  /// Sends any queued local mutations for [accountId] to the server.
  /// Returns the number of changes successfully applied.
  Future<int> flushPendingChanges(String accountId, String password);

  /// Emits the list of pending mutations that have failed at least once for
  /// [accountId]. Updates live whenever the queue changes.
  Stream<List<FailedMutation>> observeFailedMutations(String accountId);

  /// Emits every outbound queue row (failed or not-yet-tried) for [accountId],
  /// oldest first. Powers the per-account Pending Changes screen.
  Stream<List<PendingChange>> observePendingChanges(String accountId);

  /// Emits every outbound queue row across all accounts, oldest first. Backs
  /// the global Pending Changes screen and the drawer badge.
  Stream<List<PendingChange>> observeAllPendingChanges();

  /// Permanently removes the pending mutation with [id] from the queue.
  Future<void> discardMutation(int id);

  /// Resets the attempt counter for mutation [id] so the next sync cycle
  /// retries it.
  Future<void> retryMutation(int id);

  /// Tries to remove a pending change for [emailId] of [changeType] from the
  /// queue. Returns true if a pending change was found and removed.
  Future<bool> cancelPendingChange(String emailId, String changeType);

  /// Snoozes the email until [until]. It will be moved to a "Snoozed" mailbox.
  Future<void> snoozeEmail(String emailId, DateTime until);

  /// Checks for expired snoozes and moves them back to their original mailbox.
  /// Returns the number of emails woken up.
  Future<int> wakeUpEmails(String accountId);

  /// Restores previously deleted/moved emails to the local database.
  /// Used for the "Undo" feature when the original rows were hard-deleted (IMAP).
  Future<void> restoreEmails(List<Email> emails);

  /// Finds an email in [accountId]'s mailboxes by its RFC 2822 Message-ID header.
  /// Returns null if not found. Used during undo to locate an email after its
  /// IMAP UID changed (e.g. after a server-applied move assigned a new UID).
  Future<Email?> findEmailByMessageId(String accountId, String messageId);

  /// Applies locally stored active Sieve rules to INBOX emails that have not
  /// been processed yet. Records each processed email in LocalSieveApplied so
  /// the same email is never filtered twice (across restarts or re-syncs).
  /// Returns the number of emails where a rule matched and an action was taken.
  Future<int> applySieveRules(String accountId);

  /// Counts how many INBOX messages of [accountId] would be matched by the
  /// given [scriptContent] if it were run now. A message counts as matched
  /// whenever any rule's test fires, even when the resulting actions are a
  /// pure `keep` (no visible effect). Ignores LocalSieveApplied so a previously
  /// filtered message is still counted.
  ///
  /// Throws `SieveParseException` when [scriptContent] cannot be parsed.
  Future<int> previewSieveRuleMatches(String accountId, String scriptContent);

  /// Runs [scriptContent] against every INBOX message of [accountId] (regardless
  /// of LocalSieveApplied state) and enqueues the resulting moves/deletes/flag
  /// changes. Each processed message is recorded in LocalSieveApplied. Returns
  /// the number of matched messages.
  ///
  /// Throws `SieveParseException` when [scriptContent] cannot be parsed.
  Future<int> applySieveScriptToInbox(String accountId, String scriptContent);

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

  /// Deletes all locally-cached email rows and pending changes for [accountId],
  /// while preserving EmailBodies so already-downloaded content is not lost.
  /// Also resets sync-state checkpoints so the next sync fetches everything fresh.
  Future<void> clearForResync(String accountId);
}
