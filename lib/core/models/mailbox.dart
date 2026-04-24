/// A mailbox / folder within an account (maps to an IMAP mailbox).
class Mailbox {
  final String id; // "<accountId>:<path>"
  final String accountId;
  final String path; // e.g. "INBOX", "Sent", "INBOX/Work"
  final String name; // last path component
  final int unreadCount;
  final int totalCount;
  // JMAP role (RFC 8621) or mapped from IMAP special-use (RFC 6154).
  // e.g. "inbox", "sent", "drafts", "junk", "trash", "archive"
  final String? role;

  const Mailbox({
    required this.id,
    required this.accountId,
    required this.path,
    required this.name,
    required this.unreadCount,
    required this.totalCount,
    this.role,
  });
}
