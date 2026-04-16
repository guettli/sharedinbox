import '../models/email.dart';

abstract class EmailRepository {
  Stream<List<Email>> observeEmails(String accountId, String mailboxPath);
  Future<EmailBody> getEmailBody(String emailId);
  Future<void> syncEmails(String accountId, String mailboxPath);
  Future<void> setFlag(
    String emailId, {
    bool? seen,
    bool? flagged,
  });
  Future<void> moveEmail(String emailId, String destMailboxPath);
  Future<void> deleteEmail(String emailId);
  Future<void> sendEmail(String accountId, EmailDraft draft);
}
