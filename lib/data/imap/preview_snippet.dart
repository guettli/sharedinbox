import 'dart:convert';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart';

import 'package:sharedinbox/core/utils/email_preview.dart';

/// How many leading bytes of the first body part the sync path asks for to
/// build an offline preview snippet.
///
/// Measured against a live Gmail INBOX: at 8 KB only 5 of 8 sampled messages
/// yielded any preview, because an HTML-only newsletter spends its first
/// kilobytes on `<style>` and inline-styled markup; at 32 KB all 8 did. The
/// cost is bounded by the part itself — the text/plain part of a multipart
/// message is usually 1-3 KB, so only HTML-only mail actually transfers more.
const int kPreviewSnippetBytes = 32768;

final RegExp _uidPattern = RegExp(r'\bUID\s+(\d+)');

/// Extracts the UID from an untagged FETCH response line such as
/// `* 42 FETCH (UID 27025 BODY[TEXT]<0> {215}`.
///
/// Returns null when the line carries no UID, so callers can feed it every
/// untagged line.
int? parsePreviewSnippetUid(String line) {
  final match = _uidPattern.firstMatch(line);
  return match == null ? null : int.tryParse(match.group(1)!);
}

/// Builds a preview snippet from the leading body bytes of a message.
///
/// [message] is the sync fetch's message, carrying the BODYSTRUCTURE
/// `enough_mail` parsed for it; [snippet] is the raw `BODY[1]<0.n>` prefix
/// fetched separately by [fetchPreviewSnippetsFromServer]. A fetched body part
/// carries no headers of its own, so on its own it cannot be decoded — its
/// charset and transfer encoding live in the BODYSTRUCTURE. Pairing the two
/// back up makes it parsable.
///
/// A truncated snippet is expected and fine: the parser reads the parts it can
/// see and ignores the cut-off tail. Returns null when nothing decodes.
String? previewFromSnippet(MimeMessage message, Uint8List? snippet) {
  if (snippet == null || snippet.isEmpty) return null;
  // The snippet is body part 1: the first part of a multipart message (usually
  // its text/plain alternative), or the whole body of a single-part one. Its
  // content type lives on the BODYSTRUCTURE part, falling back to the
  // message-level one when the message has no sub-parts.
  final part = (message.body?.parts?.isNotEmpty ?? false)
      ? message.body!.parts!.first
      : message.body;
  final contentType = part?.contentType ?? message.getHeaderContentType();
  if (contentType == null) return null;

  final headers = StringBuffer('Content-Type: ${contentType.value}');
  contentType.parameters.forEach((name, value) {
    headers.write('; $name="$value"');
  });
  headers.write('\r\n');
  // A BODYSTRUCTURE-only message carries the transfer encoding on the parsed
  // body part rather than as a header — without it a quoted-printable body
  // keeps its `=XX` escapes and soft line breaks.
  final encoding =
      part?.encoding ?? message.getHeaderValue('content-transfer-encoding');
  if (encoding != null) {
    headers.write('Content-Transfer-Encoding: $encoding\r\n');
  }
  headers.write('\r\n');

  // Bytes, not a String: the snippet may be 8-bit text in any charset, and
  // enough_mail decodes it using the charset from the header block above.
  final rebuilt = Uint8List.fromList([
    ...utf8.encode(headers.toString()),
    ...snippet,
  ]);
  try {
    final parsed = MimeMessage.parseFromData(rebuilt);
    return previewFromBody(
      parsed.decodeTextPlainPart(),
      parsed.decodeTextHtmlPart(),
    );
  } catch (_) {
    // A malformed or awkwardly truncated body must never fail a sync — the
    // preview is a nicety, and getEmailBody backfills it when the message is
    // opened.
    return null;
  }
}
