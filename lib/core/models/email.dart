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
  final String? threadId;
  final String? messageId;
  final String? inReplyTo;
  // Space-separated RFC 2822 References header value.
  final String? references;

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
    this.threadId,
    this.messageId,
    this.inReplyTo,
    this.references,
  });

  Email copyWith({
    String? id,
    String? accountId,
    String? mailboxPath,
    int? uid,
    String? subject,
    DateTime? sentAt,
    DateTime? receivedAt,
    List<EmailAddress>? from,
    List<EmailAddress>? to,
    List<EmailAddress>? cc,
    String? preview,
    bool? isSeen,
    bool? isFlagged,
    bool? hasAttachment,
    String? threadId,
    String? messageId,
    String? inReplyTo,
    String? references,
  }) {
    return Email(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      mailboxPath: mailboxPath ?? this.mailboxPath,
      uid: uid ?? this.uid,
      subject: subject ?? this.subject,
      sentAt: sentAt ?? this.sentAt,
      receivedAt: receivedAt ?? this.receivedAt,
      from: from ?? this.from,
      to: to ?? this.to,
      cc: cc ?? this.cc,
      preview: preview ?? this.preview,
      isSeen: isSeen ?? this.isSeen,
      isFlagged: isFlagged ?? this.isFlagged,
      hasAttachment: hasAttachment ?? this.hasAttachment,
      threadId: threadId ?? this.threadId,
      messageId: messageId ?? this.messageId,
      inReplyTo: inReplyTo ?? this.inReplyTo,
      references: references ?? this.references,
    );
  }
}

/// A group of related emails sharing the same thread.
class EmailThread {
  final String threadId;
  final String? subject;
  final List<EmailAddress> participants;
  final DateTime latestDate;
  final int messageCount;
  final bool hasUnread;
  final bool isFlagged;
  final String latestEmailId;
  final String? preview;
  final String accountId;
  final String mailboxPath;

  // All email IDs in this thread (oldest-first). Needed for batch operations.
  final List<String> emailIds;

  const EmailThread({
    required this.threadId,
    required this.subject,
    required this.participants,
    required this.latestDate,
    required this.messageCount,
    required this.hasUnread,
    required this.isFlagged,
    required this.latestEmailId,
    this.preview,
    required this.emailIds,
    required this.accountId,
    required this.mailboxPath,
  });
}

class EmailAddress {
  final String? name;
  final String email;

  const EmailAddress({this.name, required this.email});

  factory EmailAddress.fromJson(Map<String, dynamic> json) {
    return EmailAddress(
      name: json['name'] as String?,
      email: json['email'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (name != null) 'name': name,
      'email': email,
    };
  }

  @override
  String toString() => name != null ? '$name <$email>' : email;
}

class EmailHeader {
  final String name;
  final String value;

  const EmailHeader({required this.name, required this.value});

  factory EmailHeader.fromJson(Map<String, dynamic> json) {
    return EmailHeader(
      name: json['name'] as String,
      value: json['value'] as String,
    );
  }

  Map<String, dynamic> toJson() => {'name': name, 'value': value};
}

/// Full message body — fetched on demand, cached in the local DB.
class EmailBody {
  final String emailId;
  final String? textBody;
  final String? htmlBody;
  final List<EmailAttachment> attachments;
  final List<EmailHeader> headers;

  const EmailBody({
    required this.emailId,
    this.textBody,
    this.htmlBody,
    required this.attachments,
    this.headers = const [],
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

class SyncEmailsResult {
  const SyncEmailsResult({
    required this.fetched,
    required this.skipped,
    required this.bytesTransferred,
  });

  final int fetched;
  final int skipped;
  final int bytesTransferred;

  static const zero =
      SyncEmailsResult(fetched: 0, skipped: 0, bytesTransferred: 0);

  SyncEmailsResult operator +(SyncEmailsResult other) => SyncEmailsResult(
        fetched: fetched + other.fetched,
        skipped: skipped + other.skipped,
        bytesTransferred: bytesTransferred + other.bytesTransferred,
      );
}

class ReliabilityResult {
  const ReliabilityResult({
    required this.missingLocally,
    required this.missingOnServer,
    required this.flagMismatches,
  });

  final List<String> missingLocally; // Server UIDs/IDs not in local DB
  final List<String> missingOnServer; // Local UIDs/IDs not on server
  final List<FlagMismatch> flagMismatches;

  bool get isHealthy =>
      missingLocally.isEmpty &&
      missingOnServer.isEmpty &&
      flagMismatches.isEmpty;

  static const healthy = ReliabilityResult(
    missingLocally: [],
    missingOnServer: [],
    flagMismatches: [],
  );
}

class FlagMismatch {
  const FlagMismatch({
    required this.id,
    required this.serverSeen,
    required this.localSeen,
    required this.serverFlagged,
    required this.localFlagged,
  });

  final String id;
  final bool serverSeen;
  final bool localSeen;
  final bool serverFlagged;
  final bool localFlagged;
}
