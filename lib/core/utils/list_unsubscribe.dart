/// Parses a RFC 2369 `List-Unsubscribe` header and returns every usable URI
/// in the order they appear in the header.
///
/// The header is a comma-separated list of angle-bracketed URIs, e.g.
/// `<mailto:unsub@list.example>, <https://list.example/u?id=123>`.
///
/// Only `mailto:`, `https:` and `http:` schemes are considered usable;
/// anything else (e.g. `ftp:`) is skipped. Returns an empty list when no
/// usable URI is found.
///
/// Some senders (e.g. eBay) emit the URI without the RFC-required angle
/// brackets. When the bracketed form yields nothing, fall back to scanning the
/// raw header for bare `mailto:`/`https:`/`http:` tokens so those mails still
/// get an Unsubscribe action (#698).
List<Uri> parseListUnsubscribeUris(String? header) {
  if (header == null) return const [];
  final result = <Uri>[];
  for (final m in RegExp(r'<([^>]+)>').allMatches(header)) {
    _addUsable(result, m.group(1)!.trim());
  }
  if (result.isEmpty) {
    for (final token in header.split(RegExp(r'[\s,]+'))) {
      _addUsable(result, token.trim());
    }
  }
  return result;
}

void _addUsable(List<Uri> result, String candidate) {
  if (candidate.isEmpty) return;
  final uri = Uri.tryParse(candidate);
  if (uri == null) return;
  if (uri.scheme == 'mailto' || uri.scheme == 'https' || uri.scheme == 'http') {
    result.add(uri);
  }
}
