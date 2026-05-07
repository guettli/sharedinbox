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

/// Sorts mailboxes by role priority (Inbox first, etc) then alphabetically by path.
int compareMailboxes(Mailbox a, Mailbox b) {
  const roleOrder = ['inbox', 'drafts', 'sent', 'archive', 'junk', 'trash'];
  if (a.role != b.role) {
    final idxA = a.role == null ? 99 : roleOrder.indexOf(a.role!);
    final idxB = b.role == null ? 99 : roleOrder.indexOf(b.role!);
    if (idxA != idxB) {
      return (idxA == -1 ? 99 : idxA).compareTo(idxB == -1 ? 99 : idxB);
    }
  }
  return a.path.toLowerCase().compareTo(b.path.toLowerCase());
}
