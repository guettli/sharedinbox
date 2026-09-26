import 'package:enough_mail/enough_mail.dart';

/// Matches a single RFC 2047 encoded-word: `=?charset?encoding?text?=`.
///
/// The charset and encoded text may not contain `?` (a `?` inside Q-encoded
/// text is written `=3F`, and base64 has no `?`), so `[^?]` is safe here.
final _encodedWord = RegExp(r'=\?[^?]+\?[bBqQ]\?[^?]*\?=');

/// Matches linear whitespace only (space / horizontal tab).
final _linearWhitespace = RegExp(r'^[ \t]+$');

/// Decodes an RFC 2047 encoded-word header (Subject, display names, …).
///
/// Instead of handing the whole string to [MailCodec.decodeHeader] — which
/// inserts spurious spaces around an encoded-word that borderline-conformant
/// senders glue directly to surrounding text — this tokenizes the header
/// itself so *we* control the whitespace between tokens:
///
///  * Unfolds RFC 5322 header folding — a `CRLF` immediately followed by
///    `SP`/`HT` is a line continuation; the CRLF is stripped but the
///    whitespace is kept (`MailCodec.decodeHeader` only strips `"\r\n "`).
///  * Each encoded-word is decoded *in isolation*; a lone well-formed word
///    decodes cleanly with no spurious spaces.
///  * Linear whitespace *between two adjacent encoded-words* is dropped
///    (RFC 2047 §6.2 — it "is ignored"). This subsumes the #418 cases where
///    a charset case mismatch or `HT` folding left the space behind.
///  * Any other literal text — including text directly abutting an
///    encoded-word, e.g. `B=?utf8?Q?=C3=BC?=rostuhl` (#868) — is appended
///    verbatim, so we never inject a separator that wasn't there.
///
/// So `Schneidersitz B=?utf8?Q?=C3=BC?=rostuhl` decodes to
/// `Schneidersitz Bürostuhl` while `Prefix =?utf-8?Q?=C3=BCber?= suffix` still
/// keeps its legitimate spaces (`Prefix über suffix`).
String? decodeMailHeader(String? raw) {
  if (raw == null || raw.isEmpty) return raw;
  // Unfold: drop CRLF that precedes any whitespace character.
  final normalized = raw.replaceAll(RegExp(r'\r\n(?=[ \t])'), '');

  final matches = _encodedWord.allMatches(normalized).toList();
  if (matches.isEmpty) {
    // No encoded-words: plain text (decodeHeader is a no-op for ASCII).
    return MailCodec.decodeHeader(normalized);
  }

  final buffer = StringBuffer();
  var cursor = 0;
  var prevWasEncodedWord = false;
  for (final match in matches) {
    final gap = normalized.substring(cursor, match.start);
    if (gap.isNotEmpty) {
      // Whitespace between two adjacent encoded-words is ignored (§6.2);
      // everything else — including text abutting a word — is kept as-is.
      final dropGap = prevWasEncodedWord && _linearWhitespace.hasMatch(gap);
      if (!dropGap) buffer.write(gap);
    }
    final word = match.group(0)!;
    buffer.write(MailCodec.decodeHeader(word) ?? word);
    cursor = match.end;
    prevWasEncodedWord = true;
  }
  if (cursor < normalized.length) {
    buffer.write(normalized.substring(cursor));
  }
  return buffer.toString();
}
