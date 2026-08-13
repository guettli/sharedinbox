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
  final DateTime? snoozedUntil;
  final String? snoozedFromMailboxPath;
  // RFC 2369 List-Unsubscribe header value, e.g. "<mailto:...>, <https://...>".
  final String? listUnsubscribeHeader;

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
    this.snoozedUntil,
    this.snoozedFromMailboxPath,
    this.listUnsubscribeHeader,
  });

  factory Email.fromJson(Map<String, dynamic> json) {
    return Email(
      id: json['id'] as String,
      accountId: json['accountId'] as String,
      mailboxPath: json['mailboxPath'] as String,
      uid: json['uid'] as int,
      subject: json['subject'] as String?,
      sentAt: json['sentAt'] != null
          ? DateTime.parse(json['sentAt'] as String)
          : null,
      receivedAt: DateTime.parse(json['receivedAt'] as String),
      from: (json['from'] as List<dynamic>)
          .map((e) => EmailAddress.fromJson(e as Map<String, dynamic>))
          .toList(),
      to: (json['to'] as List<dynamic>)
          .map((e) => EmailAddress.fromJson(e as Map<String, dynamic>))
          .toList(),
      cc: (json['cc'] as List<dynamic>)
          .map((e) => EmailAddress.fromJson(e as Map<String, dynamic>))
          .toList(),
      preview: json['preview'] as String?,
      isSeen: json['isSeen'] as bool,
      isFlagged: json['isFlagged'] as bool,
      hasAttachment: json['hasAttachment'] as bool,
      threadId: json['threadId'] as String?,
      messageId: json['messageId'] as String?,
      inReplyTo: json['inReplyTo'] as String?,
      references: json['references'] as String?,
      snoozedUntil: json['snoozedUntil'] != null
          ? DateTime.parse(json['snoozedUntil'] as String)
          : null,
      snoozedFromMailboxPath: json['snoozedFromMailboxPath'] as String?,
      listUnsubscribeHeader: json['listUnsubscribeHeader'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'accountId': accountId,
      'mailboxPath': mailboxPath,
      'uid': uid,
      'subject': subject,
      'sentAt': sentAt?.toIso8601String(),
      'receivedAt': receivedAt.toIso8601String(),
      'from': from.map((e) => e.toJson()).toList(),
      'to': to.map((e) => e.toJson()).toList(),
      'cc': cc.map((e) => e.toJson()).toList(),
      'preview': preview,
      'isSeen': isSeen,
      'isFlagged': isFlagged,
      'hasAttachment': hasAttachment,
      'threadId': threadId,
      'messageId': messageId,
      'inReplyTo': inReplyTo,
      'references': references,
      'snoozedUntil': snoozedUntil?.toIso8601String(),
      'snoozedFromMailboxPath': snoozedFromMailboxPath,
      'listUnsubscribeHeader': listUnsubscribeHeader,
    };
  }

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
    DateTime? snoozedUntil,
    String? snoozedFromMailboxPath,
    String? listUnsubscribeHeader,
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
      snoozedUntil: snoozedUntil ?? this.snoozedUntil,
      snoozedFromMailboxPath:
          snoozedFromMailboxPath ?? this.snoozedFromMailboxPath,
      listUnsubscribeHeader:
          listUnsubscribeHeader ?? this.listUnsubscribeHeader,
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

  /// Wraps a single [Email] as a one-message thread for uniform rendering.
  factory EmailThread.fromEmail(Email e) => EmailThread(
        threadId: e.threadId ?? e.id,
        subject: e.subject,
        participants: e.from,
        latestDate: e.sentAt ?? e.receivedAt,
        messageCount: 1,
        hasUnread: !e.isSeen,
        isFlagged: e.isFlagged,
        latestEmailId: e.id,
        preview: e.preview,
        emailIds: [e.id],
        accountId: e.accountId,
        mailboxPath: e.mailboxPath,
      );
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
    return {if (name != null) 'name': name, 'email': email};
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
class MimePart {
  final String contentType;
  final String? filename;
  final int? size;
  final String? encoding;
  final List<MimePart> children;

  const MimePart({
    required this.contentType,
    this.filename,
    this.size,
    this.encoding,
    this.children = const [],
  });
}

class EmailBody {
  final String emailId;
  final String? textBody;
  final String? htmlBody;
  final List<EmailAttachment> attachments;
  final List<EmailHeader> headers;
  final MimePart? mimeTree;

  const EmailBody({
    required this.emailId,
    this.textBody,
    this.htmlBody,
    required this.attachments,
    this.headers = const [],
    this.mimeTree,
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

  static const zero = SyncEmailsResult(
    fetched: 0,
    skipped: 0,
    bytesTransferred: 0,
  );

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

/// A folder-scoped diagnostic snapshot, produced on demand (long-press a folder
/// → "Diagnose") to explain why a folder's cached message count can disagree
/// with what the folder actually holds — the symptom reported in #511, where a
/// folder shows a count of `0` yet opening it reveals messages.
///
/// It lines up three sources of truth for one mailbox:
///   * the **cached** count shown in the folder list ([cachedTotal] /
///     [cachedUnread], read straight from the `mailboxes` row),
///   * the **local** cache ([localEmailRows] / [localThreadRows]), and
///   * the **server's** live view ([serverTotal] / [serverUnread] /
///     [serverMessageCount], fetched over IMAP or JMAP).
///
/// When the server cannot be reached [error] is populated and the server-side
/// figures stay null, so the report degrades to the local numbers instead of
/// failing outright.
class MailboxDiagnostics {
  const MailboxDiagnostics({
    required this.accountId,
    required this.mailboxPath,
    required this.protocol,
    required this.cachedTotal,
    required this.cachedUnread,
    required this.localEmailRows,
    required this.localThreadRows,
    this.orphanThreadRows = 0,
    this.serverTotal,
    this.serverUnread,
    this.serverMessageCount,
    this.missingLocally = const [],
    this.missingOnServer = const [],
    this.error,
  });

  /// A zero-valued snapshot (all counts 0, server not consulted). Convenience
  /// for test doubles that satisfy the interface without exercising the check.
  factory MailboxDiagnostics.empty({
    required String accountId,
    required String mailboxPath,
    String protocol = 'IMAP',
  }) =>
      MailboxDiagnostics(
        accountId: accountId,
        mailboxPath: mailboxPath,
        protocol: protocol,
        cachedTotal: 0,
        cachedUnread: 0,
        localEmailRows: 0,
        localThreadRows: 0,
      );

  final String accountId;
  final String mailboxPath;

  /// `IMAP` or `JMAP` — the account's protocol, shown in the report.
  final String protocol;

  /// The total/unread counts cached in the `mailboxes` row — i.e. exactly the
  /// numbers the folder list renders.
  final int cachedTotal;
  final int cachedUnread;

  /// How many rows the local cache actually holds for this mailbox.
  final int localEmailRows;
  final int localThreadRows;

  /// How many of [localThreadRows] are orphans — thread rows whose id no longer
  /// matches any email currently in the folder, so the folder view shows them
  /// as phantom conversations backed by no mail (#523). Swept during sync and
  /// removable on demand from the diagnostics screen.
  final int orphanThreadRows;

  /// The server's own total/unread counts (IMAP `SELECT`/`STATUS`, JMAP
  /// `Mailbox/get` `totalEmails`/`unreadEmails`). Null when [error] is set.
  final int? serverTotal;
  final int? serverUnread;

  /// The number of messages the server actually lists for this mailbox (IMAP
  /// `UID SEARCH ALL`, JMAP `Email/query inMailbox`). Null when [error] is set.
  final int? serverMessageCount;

  /// Server message ids/UIDs absent from the local cache.
  final List<String> missingLocally;

  /// Locally cached ids no longer present on the server.
  final List<String> missingOnServer;

  /// Non-null when the live server check could not complete; the server-side
  /// figures are then unavailable.
  final String? error;

  /// Whether the live server check completed and produced counts.
  bool get reachedServer => error == null && serverMessageCount != null;

  /// Plain-English observations describing any mismatch between the cached
  /// folder count, the local cache and the server's live message list. Empty
  /// only in the (impossible) case that nothing at all could be said.
  List<String> get conclusions {
    final out = <String>[];
    if (error != null) {
      out.add(
        'Could not reach the server ($error). '
        'The figures below reflect only the local cache.',
      );
      return out;
    }
    final serverCount = serverMessageCount;
    if (serverCount != null) {
      if (cachedTotal == 0 && serverCount > 0) {
        out.add(
          'The folder count shows 0 but the server holds $serverCount '
          'message(s) — the cached count is stale. Re-fetch counts or resync '
          'this folder to fix it.',
        );
      } else if (cachedTotal != serverCount) {
        out.add(
          'The cached folder count ($cachedTotal) does not match the '
          "server's live count ($serverCount).",
        );
      }
      if (missingLocally.isNotEmpty) {
        out.add(
          '${missingLocally.length} message(s) are on the server but not '
          'cached locally — a resync will download them.',
        );
      }
      if (missingOnServer.isNotEmpty) {
        out.add(
          '${missingOnServer.length} locally cached message(s) are no longer '
          'on the server — a resync will remove them.',
        );
      }
      if (serverCount == 0 && localEmailRows == 0) {
        out.add('This folder is empty on the server and locally.');
      }
    }
    if (cachedTotal == 0 && localEmailRows > 0) {
      out.add(
        'The folder count shows 0 but $localEmailRows message(s) are cached '
        'locally — the cached count is out of date.',
      );
    }
    if (orphanThreadRows > 0) {
      out.add(
        'This folder lists $localThreadRows conversation(s) but only '
        '$localEmailRows message(s) are cached — $orphanThreadRows stale '
        'row(s) are showing mail that no longer exists here. Remove the '
        'phantom rows to fix it.',
      );
    }
    if (out.isEmpty) {
      out.add(
        'No discrepancies found — the cached count matches the server and the '
        'local cache.',
      );
    }
    return out;
  }
}
