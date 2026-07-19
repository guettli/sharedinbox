import 'package:sharedinbox/core/utils/html_utils.dart';

/// Maximum characters kept in a preview snippet. Matches the length JMAP
/// servers typically return (RFC 8621 §4.2.2), so IMAP and JMAP threads look
/// the same in the list.
const int kPreviewMaxChars = 256;

/// Builds a JMAP-style preview snippet from an already-decoded text and/or
/// HTML body. Prefers plain text; falls back to a tag-stripped HTML body.
///
/// Collapses runs of whitespace (including NBSP) into single spaces and
/// truncates to [kPreviewMaxChars]. Returns null when both inputs are empty.
String? previewFromBody(String? text, String? html) {
  String? source = text;
  if (source == null || source.trim().isEmpty) {
    if (html == null || html.trim().isEmpty) return null;
    source = htmlToPlain(html);
  }
  // `\s` matches NBSP (U+00A0) under Dart's ECMAScript regex semantics.
  final collapsed = source.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (collapsed.isEmpty) return null;
  return collapsed.length > kPreviewMaxChars
      ? collapsed.substring(0, kPreviewMaxChars)
      : collapsed;
}
