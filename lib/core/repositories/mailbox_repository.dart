import '../models/mailbox.dart';

abstract class MailboxRepository {
  Stream<List<Mailbox>> observeMailboxes(String accountId);

  /// Returns the number of mailboxes synced.
  Future<int> syncMailboxes(String accountId);
}
