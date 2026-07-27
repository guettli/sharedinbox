import 'package:enough_mail/enough_mail.dart';

/// Decodes an RFC 2047 encoded-word header (Subject, display names, …).
///
/// Wraps [MailCodec.decodeHeader] with two preprocessing passes so that
/// borderline-conformant senders don't produce spurious spaces around
/// non-ASCII characters in the output (see #418):
///
///  * Unfolds RFC 5322 header folding — a `CRLF` immediately followed by
///    `SP`/`HT` is a line continuation; the CRLF is stripped but the
///    whitespace is kept. `MailCodec.decodeHeader` only strips `"\r\n "`
///    (space), leaving literal tabs behind when the sender folds with `HT`.
///  * Strips any linear whitespace between two adjacent encoded-words.
///    RFC 2047 §6.2 says such whitespace "is ignored"; enough_mail's own
///    fixup only handles the case where the two words share the exact same
///    charset/encoding spelling, so `=?UTF-8?…?= =?utf-8?…?=` (case
///    mismatch) or `?=\r\n\t=?` (tab folding) slip through and leave the
///    space in the decoded output.
String? decodeMailHeader(String? raw) {
  if (raw == null || raw.isEmpty) return raw;
  // 1. Unfold: drop CRLF that precedes any whitespace character.
  var normalized = raw.replaceAll(RegExp(r'\r\n(?=[ \t])'), '');
  // 2. Collapse WSP between adjacent encoded-words so the decoder sees them
  //    as directly abutting and joins them without a separator.
  normalized = normalized.replaceAll(RegExp(r'\?=[ \t]+=\?'), '?==?');
  return MailCodec.decodeHeader(normalized);
}
