class EmailNote {
  final String id; // UUID (X-SharedInbox-Note-Id)
  final String accountId;
  final String messageId; // RFC 2822 Message-ID (X-SharedInbox-Note-For)
  final String noteText;
  final String serverId; // IMAP UID (as string) or JMAP email ID
  final DateTime createdAt;

  const EmailNote({
    required this.id,
    required this.accountId,
    required this.messageId,
    required this.noteText,
    required this.serverId,
    required this.createdAt,
  });
}
