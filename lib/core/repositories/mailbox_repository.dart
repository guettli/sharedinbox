import '../models/mailbox.dart';

abstract class MailboxRepository {
  Stream<List<Mailbox>> observeMailboxes(String accountId);
  Future<void> syncMailboxes(String accountId);
}
