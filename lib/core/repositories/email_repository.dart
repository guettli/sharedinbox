import '../models/email.dart';

abstract class EmailRepository {
  Stream<List<Email>> observeEmails(String accountId, String mailboxPath);
  Future<Email?> getEmail(String emailId);
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
}
