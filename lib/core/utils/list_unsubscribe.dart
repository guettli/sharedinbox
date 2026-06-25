/// Parses a RFC 2369 `List-Unsubscribe` header and returns every usable URI
/// in the order they appear in the header.
///
/// The header is a comma-separated list of angle-bracketed URIs, e.g.
/// `<mailto:unsub@list.example>, <https://list.example/u?id=123>`.
///
/// Only `mailto:`, `https:` and `http:` schemes are considered usable;
/// anything else (e.g. `ftp:`) is skipped. Returns an empty list when no
/// usable URI is found.
List<Uri> parseListUnsubscribeUris(String? header) {
  if (header == null) return const [];
  final result = <Uri>[];
  for (final m in RegExp(r'<([^>]+)>').allMatches(header)) {
    final uri = Uri.tryParse(m.group(1)!.trim());
    if (uri == null) continue;
    if (uri.scheme == 'mailto' ||
        uri.scheme == 'https' ||
        uri.scheme == 'http') {
      result.add(uri);
    }
  }
  return result;
}
