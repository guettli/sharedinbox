import 'package:enough_mail/enough_mail.dart';

/// Decodes the `text/html` part of [message], recovering from a known
/// enough_mail quoted-printable bug that would otherwise blank the whole part.
///
/// See [decodeTextPlainPartSafe] for the details of the workaround.
String? decodeTextHtmlPartSafe(MimeMessage message) => _decodeTextPartSafe(
      message,
      MediaSubtype.textHtml,
      message.decodeTextHtmlPart,
    );

/// Decodes the `text/plain` part of [message], recovering from a known
/// enough_mail quoted-printable bug that would otherwise blank the whole part.
///
/// enough_mail 2.1.7's [QuotedPrintableMailCodec.decodeText] runs an unguarded
/// `substring(i + 1, i + 3)` for every `=` byte, so a quoted-printable part
/// that ends with a dangling `=` (one that is not followed by two more
/// characters) throws `RangeError (end)` instead of decoding — see #588 (and
/// the related crashes #232 / #579). When that happens we re-decode the part
/// ourselves after stripping the dangling `=`, so a single malformed byte at
/// the tail no longer costs the reader the entire body. Returns `null` (and
/// lets the original error propagate) when the part genuinely can't be
/// recovered, so the caller's outer salvage can still flag the body as partial.
///
/// Remove this workaround once the upstream bug is fixed and the fix is
/// released.
String? decodeTextPlainPartSafe(MimeMessage message) => _decodeTextPartSafe(
      message,
      MediaSubtype.textPlain,
      message.decodeTextPlainPart,
    );

String? _decodeTextPartSafe(
  MimeMessage message,
  MediaSubtype subtype,
  String? Function() decode,
) {
  try {
    return decode();
    // The buggy third-party decoder throws a RangeError, not an Exception, so
    // catching it precisely is the whole point of this workaround.
    // ignore: avoid_catching_errors
  } on RangeError {
    final recovered = _recoverQuotedPrintablePart(message, subtype);
    if (recovered != null) {
      return recovered;
    }
    rethrow;
  }
}

/// Finds the [subtype] part enough_mail would have decoded, then decodes it
/// again with the dangling trailing `=` removed. Returns `null` when there is
/// no such part, when it isn't quoted-printable (so the RangeError came from
/// elsewhere), or when the repaired decode still fails.
String? _recoverQuotedPrintablePart(MimeMessage message, MediaSubtype subtype) {
  final part = _findTextPart(message, subtype);
  if (part == null) {
    return null;
  }
  final transferEncoding =
      part.getHeaderValue('content-transfer-encoding')?.toLowerCase();
  if (transferEncoding != 'quoted-printable') {
    return null;
  }
  // Render the part's raw, still-encoded body — exactly the input decodeText
  // choked on — without going through the throwing decoder.
  final data = part.mimeData;
  if (data == null) {
    return null;
  }
  final buffer = StringBuffer();
  data.render(buffer, renderHeader: false);
  final repaired = _stripDanglingQuotedPrintableEquals(buffer.toString());
  final charset = part.getHeaderContentType()?.charset;
  try {
    return MailCodec.decodeAnyText(repaired, 'quoted-printable', charset);
    // Defensive: if the repaired text still trips the decoder, fall back to the
    // caller's salvage rather than propagating.
    // ignore: avoid_catching_errors
  } on RangeError {
    return null;
  }
}

/// Depth-first search for the first part with the given media [subtype],
/// mirroring enough_mail's private `MimePart._decodeTextPart` traversal.
MimePart? _findTextPart(MimePart part, MediaSubtype subtype) {
  if (part.mediaType.sub == subtype) {
    return part;
  }
  final parts = part.parts;
  if (parts != null) {
    for (final child in parts) {
      final match = _findTextPart(child, subtype);
      if (match != null) {
        return match;
      }
    }
  }
  return null;
}

/// Drops a trailing `=` that is not followed by two more characters.
///
/// Mirrors the decoder's first step — soft line breaks (`=\r\n`) are removed
/// before the byte-by-byte scan — so a genuine soft break at the very end is
/// not treated as dangling, and a `=` that only becomes the last byte *after*
/// soft breaks are stripped (the common case for a wrapped multipart part) is
/// still caught. Only a truly dangling `=` (the byte that overruns
/// `substring(i + 1, i + 3)`) is removed.
String _stripDanglingQuotedPrintableEquals(String raw) {
  var text = raw.replaceAll('=\r\n', '');
  if (text.endsWith('=')) {
    // `…=` — bare escape byte at the end of the data.
    text = text.substring(0, text.length - 1);
  } else if (text.length >= 2 && text[text.length - 2] == '=') {
    // `…=X` — escape byte with a single trailing character; keep the trailing
    // character but drop the `=` that can never form a valid `=XX` sequence.
    text = text.substring(0, text.length - 2) + text[text.length - 1];
  }
  return text;
}
