import 'package:sharedinbox/core/models/mailbox.dart';

abstract class MailboxRepository {
  Stream<List<Mailbox>> observeMailboxes(String accountId);

  /// Returns the number of mailboxes synced.
  Future<int> syncMailboxes(String accountId);

  /// Returns the first mailbox with the given [role] for [accountId], or null.
  Future<Mailbox?> findMailboxByRole(String accountId, String role);
}
