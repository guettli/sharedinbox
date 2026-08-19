import 'package:enough_mail/enough_mail.dart';

/// Encodes a human-readable Unicode mailbox [path] into the modified UTF-7
/// wire form required by IMAP (RFC 3501 §5.1.3), keeping the hierarchy
/// [separator] literal.
///
/// `enough_mail`'s [Mailbox.encode] only encodes the last path segment, so a
/// non-ASCII parent segment (e.g. `Geschäftsführer/Sub`) would leak raw bytes.
/// We split on [separator] and encode each segment individually — a segment
/// with no separator makes [Mailbox.encode] encode the whole thing — then
/// rejoin so the separators stay untouched.
///
/// Needed because [ImapClient.selectMailboxByPath] treats its argument as the
/// already-encoded `encodedPath` and writes it into `SELECT "…"` verbatim
/// without re-encoding. We persist the *decoded* Unicode path (`Mailbox.path`),
/// so it must be re-encoded before selecting (#633).
String encodeImapMailboxPath(String path, String separator) => path
    .split(separator)
    .map((segment) => Mailbox.encode(segment, separator))
    .join(separator);

extension UnicodeMailboxSelect on ImapClient {
  /// Selects a mailbox given its decoded Unicode [path], encoding it to
  /// modified UTF-7 first so folders with non-ASCII names (umlauts, …) are
  /// sent in the form the server expects.
  ///
  /// The path separator is taken from [serverInfo] (populated once mailboxes
  /// have been listed), falling back to `/`. ASCII paths encode to themselves,
  /// so this is safe to use for `INBOX` and other plain names too.
  Future<Mailbox> selectUnicodeMailboxByPath(
    String path, {
    bool enableCondStore = false,
    QResyncParameters? qresync,
  }) {
    final separator = serverInfo.pathSeparator ?? '/';
    return selectMailboxByPath(
      encodeImapMailboxPath(path, separator),
      enableCondStore: enableCondStore,
      qresync: qresync,
    );
  }
}
