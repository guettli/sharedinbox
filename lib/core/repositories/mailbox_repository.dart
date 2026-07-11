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
}
