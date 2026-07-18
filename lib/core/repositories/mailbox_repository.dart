import 'package:sharedinbox/core/models/mailbox.dart';

abstract class MailboxRepository {
  Stream<List<Mailbox>> observeMailboxes(String? accountId);

  /// Returns the number of mailboxes synced.
  Future<int> syncMailboxes(String accountId);

  /// Returns the first mailbox with the given [role] for [accountId], or null.
  Future<Mailbox?> findMailboxByRole(String accountId, String role);

  /// Deletes all locally-cached mailbox rows for [accountId].
  Future<void> clearForResync(String accountId);

  /// Creates a new mailbox named [name] for [accountId] and tags it with
  /// [role] in the local database. For JMAP accounts the role is also sent
  /// to the server. Returns the newly created [Mailbox].
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
  /// The mailbox is created on the account's IMAP/JMAP server, so this call
  /// requires network connectivity.
  Future<Mailbox> createMailbox(
    String accountId,
    String name, {
    String? parentDisplayPath,
  });

  /// Renames the mailbox with [mailboxPath] under [accountId] so that its
  /// leaf name becomes [newName]. Parent stays the same. Returns the updated
  /// [Mailbox]. Talks to the account's IMAP/JMAP server.
  Future<Mailbox> renameMailbox(
    String accountId,
    String mailboxPath,
    String newName,
  );

  /// Deletes the mailbox with [mailboxPath] under [accountId] on the server
  /// and removes its local cache (emails, threads, sync state).
  Future<void> deleteMailbox(String accountId, String mailboxPath);

  /// Moves the mailbox with [mailboxPath] under [accountId] to live under
  /// [newParentDisplayPath] (null for top level). The leaf name is preserved.
  /// Returns the updated [Mailbox].
  Future<Mailbox> moveMailbox(
    String accountId,
    String mailboxPath, {
    required String? newParentDisplayPath,
  });
}
