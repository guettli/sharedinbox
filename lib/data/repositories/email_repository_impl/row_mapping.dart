part of '../email_repository_impl.dart';

// Mapping between email rows and the domain model, and header parsing.

extension _RowMapping on EmailRepositoryImpl {
  String _encodeAddresses(List<imap.MailAddress>? addresses) => jsonEncode(
        (addresses ?? const [])
            .map((a) => {'name': a.personalName, 'email': a.email})
            .toList(),
      );

  model.Email _toModel(Email row) {
    List<model.EmailAddress> parseAddresses(String json) {
      final list = jsonDecode(json) as List<dynamic>;
      return list
          .map(
            (e) => model.EmailAddress(
              name: (e as Map<String, dynamic>)['name'] as String?,
              email: e['email'] as String,
            ),
          )
          .toList();
    }

    return model.Email(
      id: row.id,
      accountId: row.accountId,
      mailboxPath: row.mailboxPath,
      uid: row.uid,
      subject: row.subject,
      sentAt: row.sentAt,
      receivedAt: row.receivedAt,
      from: parseAddresses(row.fromJson),
      to: parseAddresses(row.toAddresses),
      cc: parseAddresses(row.ccJson),
      replyTo: parseAddresses(row.replyToJson),
      bcc: parseAddresses(row.bccJson),
      preview: row.preview,
      isSeen: row.isSeen,
      isFlagged: row.isFlagged,
      hasAttachment: row.hasAttachment,
      threadId: row.threadId,
      messageId: row.messageId,
      inReplyTo: row.inReplyTo,
      references: row.references,
      snoozedUntil: row.snoozedUntil,
      snoozedFromMailboxPath: row.snoozedFromMailboxPath,
      listUnsubscribeHeader: row.listUnsubscribeHeader,
      isLocal: row.isLocal,
      isVirtualSentCopy: row.isVirtualSentCopy,
      size: row.sizeBytes,
      srvMailboxPath: row.srvMailboxPath,
      srvUid: row.srvUid,
      srvUidValidity: row.srvUidValidity,
      srvJmapId: row.srvJmapId,
    );
  }

  List<model.EmailHeader> _parseHeaders(String? jsonStr) {
    if (jsonStr == null || jsonStr.isEmpty) return [];
    try {
      final list = jsonDecode(jsonStr) as List;
      return list
          .cast<Map<String, dynamic>>()
          .map((m) => model.EmailHeader.fromJson(m))
          .toList();
    } catch (e) {
      return [];
    }
  }
}
