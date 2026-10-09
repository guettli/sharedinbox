bool isLocalhost(String host) {
  final h = host.trim().toLowerCase();
  return h == 'localhost' || h == '127.0.0.1' || h == '::1';
}

String? validateHostname(String? value) {
  if (value == null || value.trim().isEmpty) return 'Required';
  return _checkHostChars(value.trim());
}

String? validateOptionalHostname(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  return _checkHostChars(value.trim());
}

/// Validates a JMAP API URL field. The URL carries the account password as
/// HTTP Basic auth on every request, so it must be https — except to a
/// localhost development server, where http is allowed (mirrors the IMAP/SMTP
/// STARTTLS carve-out). Rejected at save time so the user sees it here rather
/// than as a first-sync failure; `JmapClient.connect` enforces the same rule
/// at the connection boundary for every other code path.
String? validateJmapUrl(String? value) {
  if (value == null || value.trim().isEmpty) return 'Required';
  final uri = Uri.tryParse(value.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return 'Enter a full URL, e.g. https://mail.example.com/jmap';
  }
  if (uri.scheme == 'https') return null;
  if (uri.scheme == 'http' && isLocalhost(uri.host)) return null;
  return 'Must use https (http is allowed only for localhost)';
}

String? _checkHostChars(String h) {
  if (h.contains(RegExp(r'[@/\\]')) ||
      h.codeUnits.any((c) => c < 32 || c == 127)) {
    return 'Invalid hostname';
  }
  return null;
}
