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

  const EmailAttachment({
    required this.filename,
    required this.contentType,
    required this.size,
  });
}

/// Outgoing email — used for compose / reply.
class EmailDraft {
  final EmailAddress from;
  final List<EmailAddress> to;
  final List<EmailAddress> cc;
  final String subject;
  final String body;

  const EmailDraft({
    required this.from,
    required this.to,
    required this.cc,
    required this.subject,
    required this.body,
  });
}
