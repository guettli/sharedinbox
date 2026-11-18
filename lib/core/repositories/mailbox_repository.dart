import 'package:sharedinbox/core/models/mailbox.dart';

abstract class MailboxRepository {
  Stream<List<Mailbox>> observeMailboxes(String? accountId);

  /// Emits an account id whenever a folder change of that account was
  /// queued (create, rename): the sync loop flushes it soon, as it does for
  /// `EmailRepository.onChangesQueued`.
  Stream<String> get onChangesQueued;

  /// Returns the number of mailboxes synced.
  Future<int> syncMailboxes(String accountId);

  /// Returns the first mailbox with the given [role] for [accountId], or null.
  Future<Mailbox?> findMailboxByRole(String accountId, String role);

  /// Force resync of [accountId]: makes the next [syncMailboxes] a
  /// complete listing, which prunes the cached folders the server no
  /// longer lists. Deletes no mailbox row (mark-and-sweep, #1236).
  Future<void> clearForResync(String accountId);

  /// Creates a new mailbox named [name] for [accountId] and tags it with
  /// [role] in the local database. For JMAP accounts the role is also sent
  /// to the server. Returns the newly created [Mailbox] at once, offline
  /// too: the creation on the server is queued (a server refusal becomes a
  /// failed change), and mail moved into it waits for it.
  ///
  /// When [parentDisplayPath] is non-null, the new mailbox is created as a
  /// child of the mailbox with that [Mailbox.displayPath] in the local cache.
  Future<Mailbox> createMailboxWithRole(
    String accountId,
    String name,
    String role, {
    String? parentDisplayPath,
  });

  /// Creates a new mailbox named [name] for [accountId] without a special role.
  /// Returns the newly created [Mailbox].
  ///
  /// When [parentDisplayPath] is non-null, the new mailbox is created as a
  /// child of the mailbox with that [Mailbox.displayPath] in the local cache.
  /// Like [createMailboxWithRole], it works offline: the creation on the
  /// server is queued.
  Future<Mailbox> createMailbox(
    String accountId,
    String name, {
    String? parentDisplayPath,
  });

  /// Renames the mailbox with [mailboxPath] under [accountId] so that its
  /// leaf name becomes [newName]. Parent stays the same. Returns the updated
  /// [Mailbox] at once, offline too: the rename on the server is queued.
  Future<Mailbox> renameMailbox(
    String accountId,
    String mailboxPath,
    String newName,
  );

  /// Deletes the mailbox with [mailboxPath] under [accountId], offline too:
  /// it is hidden at once and the delete on the server is queued; once the
  /// server confirmed it, its local cache (emails, threads, sync state)
  /// goes. A folder created offline that is not on the server yet only
  /// gives up its creation. A folder with subfolders is refused (delete
  /// them first).
  ///
  /// With [removeEmails] the mail it contains is deleted too (mail that is
  /// also in another JMAP mailbox stays there) — pass it only when the user
  /// confirmed deleting mail. Without it a folder that is not empty on the
  /// server is refused (a failed change, the folder shows again), so mail
  /// that arrived after a stale "empty" count is never deleted silently.
  Future<void> deleteMailbox(
    String accountId,
    String mailboxPath, {
    bool removeEmails = false,
  });

  /// Moves the mailbox with [mailboxPath] under [accountId] to live under
  /// [newParentDisplayPath] (null for top level), offline too: it shows
  /// there at once and the move on the server is queued. The leaf name is
  /// preserved. Returns the updated [Mailbox].
  Future<Mailbox> moveMailbox(
    String accountId,
    String mailboxPath, {
    required String? newParentDisplayPath,
  });

  /// Undoes the latest move or delete of the folder [mailboxId] of
  /// [accountId]: one not sent yet is cancelled; a move already sent is
  /// moved back. Returns false when it can no longer be undone (a delete
  /// being sent, or one that may have reached the server).
  Future<bool> undoFolderChange(String accountId, String mailboxId);
}
