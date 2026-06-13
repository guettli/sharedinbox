/// Parses a RFC 2369 `List-Unsubscribe` header and returns the first usable
/// URI.
///
/// The header is a comma-separated list of angle-bracketed URIs, e.g.
/// `<mailto:unsub@list.example>, <https://list.example/u?id=123>`.
///
/// `mailto:` is preferred over `https:` / `http:` so the unsubscribe request
/// stays inside the mail client when possible; HTTPS is used as a fallback.
/// Unsupported schemes (e.g. `ftp:`) are ignored. Returns `null` when no
/// usable URI is found.
Uri? parseListUnsubscribeUri(String? header) {
  if (header == null) return null;
  final matches = RegExp(r'<([^>]+)>').allMatches(header);
  Uri? fallback;
  for (final m in matches) {
    final raw = m.group(1)!.trim();
    final uri = Uri.tryParse(raw);
    if (uri == null) continue;
    if (uri.scheme == 'mailto') return uri;
    if ((uri.scheme == 'https' || uri.scheme == 'http') && fallback == null) {
      fallback = uri;
    }
  }
  return fallback;
}
