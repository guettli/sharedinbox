import 'package:enough_mail/enough_mail.dart';

/// The kind of server-assigned, move-stable message identifier a server
/// exposes, used to relink a locally cached email to its new UID after an
/// IMAP `MOVE`/`COPY` instead of deleting and re-inserting the row (#589).
///
/// * [emailId] — RFC 8474 (`OBJECTID` capability) `EMAILID`, returned as a
///   parenthesised FETCH data item, e.g. `EMAILID (Mabc123)`.
/// * [gmailMsgId] — Gmail's proprietary `X-GM-MSGID` (`X-GM-EXT-1`
///   capability), returned as a bare 64-bit decimal, e.g.
///   `X-GM-MSGID 1278455344230334865`.
enum ObjectIdKind {
  /// RFC 8474 `EMAILID`.
  emailId,

  /// Gmail `X-GM-MSGID`.
  gmailMsgId,
}

extension ObjectIdKindFetch on ObjectIdKind {
  /// The FETCH data item name to request for this identifier.
  String get fetchItem {
    switch (this) {
      case ObjectIdKind.emailId:
        return 'EMAILID';
      case ObjectIdKind.gmailMsgId:
        return 'X-GM-MSGID';
    }
  }
}

/// Picks the move-stable identifier a server exposes, preferring the
/// standardised RFC 8474 `EMAILID` over Gmail's proprietary `X-GM-MSGID`.
///
/// Returns null when the server advertises neither extension, in which case
/// the caller keeps the UID-based identity scheme unchanged.
ObjectIdKind? resolveObjectIdKind(ImapServerInfo serverInfo) {
  if (serverInfo.supports('OBJECTID')) {
    return ObjectIdKind.emailId;
  }
  if (serverInfo.supports('X-GM-EXT-1')) {
    return ObjectIdKind.gmailMsgId;
  }
  return null;
}

final RegExp _uidPattern = RegExp(r'\bUID\s+(\d+)');
final RegExp _emailIdPattern = RegExp(r'\bEMAILID\s+\(([^()\s]+)\)');
final RegExp _gmailMsgIdPattern = RegExp(r'\bX-GM-MSGID\s+(\d+)');

/// Extracts the `(uid, serverEmailId)` pair from a single untagged FETCH
/// response line such as `* 42 FETCH (UID 42 EMAILID (Mabc123))`.
///
/// Returns null when the line does not carry both a UID and the requested
/// identifier, so callers can safely feed it every untagged line.
MapEntry<int, String>? parseObjectIdLine(String line, ObjectIdKind kind) {
  final uidMatch = _uidPattern.firstMatch(line);
  if (uidMatch == null) return null;
  final RegExpMatch? idMatch;
  switch (kind) {
    case ObjectIdKind.emailId:
      idMatch = _emailIdPattern.firstMatch(line);
      break;
    case ObjectIdKind.gmailMsgId:
      idMatch = _gmailMsgIdPattern.firstMatch(line);
      break;
  }
  if (idMatch == null) return null;
  final uid = int.tryParse(uidMatch.group(1)!);
  if (uid == null) return null;
  return MapEntry(uid, idMatch.group(1)!);
}
