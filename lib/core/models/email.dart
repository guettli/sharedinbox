/// Email header — stored locally after sync, body fetched on demand.
class Email {
  final String id; // "<accountId>:<uid>"
  final String accountId;
  final String mailboxPath;
  final int uid;
  final String? subject;
  final DateTime? sentAt;
  final DateTime receivedAt;
  final List<EmailAddress> from;
  final List<EmailAddress> to;
  final List<EmailAddress> cc;
  final String? preview;
  final bool isSeen;
  final bool isFlagged;
  final bool hasAttachment;

  const Email({
    required this.id,
    required this.accountId,
    required this.mailboxPath,
    required this.uid,
    this.subject,
    this.sentAt,
    required this.receivedAt,
    required this.from,
    required this.to,
    required this.cc,
    this.preview,
    required this.isSeen,
    required this.isFlagged,
    required this.hasAttachment,
  });
}

class EmailAddress {
  final String? name;
  final String email;

  const EmailAddress({this.name, required this.email});

  @override
  String toString() => name != null ? '$name <$email>' : email;
}

/// Full message body — fetched on demand, cached in the local DB.
class EmailBody {
  final String emailId;
  final String? textBody;
  final String? htmlBody;
  final List<EmailAttachment> attachments;

  const EmailBody({
    required this.emailId,
    this.textBody,
    this.htmlBody,
    required this.attachments,
  });
}

class EmailAttachment {
  final String filename;
  final String contentType;
  final int size;
  /// IMAP BODYSTRUCTURE part identifier (e.g. "2", "2.1") used for on-demand
  /// download. Empty for attachments cached before this field was added.
  final String fetchPartId;

  const EmailAttachment({
    required this.filename,
    required this.contentType,
    required this.size,
    this.fetchPartId = '',
  });
}

/// A pending local mutation (flag, move, delete) that has failed at least once
/// and may be stuck in the outbound queue.
class FailedMutation {
  final int id;
  final String accountId;
  /// "flag_seen" | "flag_flagged" | "move" | "delete"
  final String changeType;
  final String resourceId;
  final String lastError;
  final int attempts;
  final DateTime createdAt;

  const FailedMutation({
    required this.id,
    required this.accountId,
    required this.changeType,
    required this.resourceId,
    required this.lastError,
    required this.attempts,
    required this.createdAt,
  });
}

/// Outgoing email — used for compose / reply.
class EmailDraft {
  final EmailAddress from;
  final List<EmailAddress> to;
  final List<EmailAddress> cc;
  final String subject;
  final String body;
  /// Local file-system paths of files to attach when sending.
  final List<String> attachmentFilePaths;

  const EmailDraft({
    required this.from,
    required this.to,
    required this.cc,
    required this.subject,
    required this.body,
    this.attachmentFilePaths = const [],
  });
}
