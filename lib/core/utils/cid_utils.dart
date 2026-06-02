import 'dart:convert';

import 'package:enough_mail/enough_mail.dart' as imap;

/// Replaces `src="cid:..."` references in [html] with inline `data:` URIs
/// by looking up each Content-ID in the MIME tree of [msg].
///
/// Emails with `multipart/related` often embed images this way.  Without
/// substitution the WebView shows broken image icons even after the full
/// message has been downloaded.
String injectInlineImages(String html, imap.MimeMessage msg) {
  final inlineParts = msg.findContentInfo(
    disposition: imap.ContentDisposition.inline,
  );
  if (inlineParts.isEmpty) return html;

  var result = html;
  for (final info in inlineParts) {
    final cid = info.cid;
    if (cid == null || cid.isEmpty) continue;
    final bareCid = cid.startsWith('<') && cid.endsWith('>')
        ? cid.substring(1, cid.length - 1)
        : cid;

    final part = msg.getPart(info.fetchId);
    if (part == null) continue;
    final bytes = part.decodeContentBinary();
    if (bytes == null || bytes.isEmpty) continue;

    final contentType =
        info.contentType?.mediaType.text ?? 'application/octet-stream';
    final dataUri = 'data:$contentType;base64,${base64.encode(bytes)}';

    result = result
        .replaceAll('src="cid:$bareCid"', 'src="$dataUri"')
        .replaceAll("src='cid:$bareCid'", "src='$dataUri'")
        .replaceAll('src="cid:${bareCid.toLowerCase()}"', 'src="$dataUri"')
        .replaceAll("src='cid:${bareCid.toLowerCase()}'", "src='$dataUri'");
  }
  return result;
}
