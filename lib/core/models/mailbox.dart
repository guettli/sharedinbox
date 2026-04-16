/// A mailbox / folder within an account (maps to an IMAP mailbox).
class Mailbox {
  final String id; // "<accountId>:<path>"
  final String accountId;
  final String path; // e.g. "INBOX", "Sent", "INBOX/Work"
  final String name; // last path component
  final int unreadCount;
  final int totalCount;

  const Mailbox({
    required this.id,
    required this.accountId,
    required this.path,
    required this.name,
    required this.unreadCount,
    required this.totalCount,
  });
}
