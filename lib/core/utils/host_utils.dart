import 'package:flutter/foundation.dart' show kReleaseMode;

bool isLocalhost(String host) {
  final h = host.trim().toLowerCase();
  return h == 'localhost' || h == '127.0.0.1' || h == '::1';
}

/// Hosts allowed to carry credentials over a plaintext connection in addition
/// to localhost. Populated ONLY by the test bootstrap
/// (`test/flutter_test_config.dart`) for a dev server addressed by a
/// non-localhost name — the Stalwart docker service in CI. Consulted solely
/// outside a release build (see [isPlaintextAllowedHost]), so it is physically
/// inert in a shipped app even if left populated. Shared by `JmapClient` (http)
/// and `ManageSieveClient` (STARTTLS) so the dev carve-out has one definition.
final Set<String> debugAllowedPlaintextHosts = <String>{};

/// Whether [host] may carry credentials over a plaintext (non-TLS) connection:
/// a localhost dev server always, or a test-registered dev host — the latter
/// never in a release build.
bool isPlaintextAllowedHost(String host) {
  if (isLocalhost(host)) return true;
  return !kReleaseMode && debugAllowedPlaintextHosts.contains(host);
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
/// than as a first-sync failure; the runtime paths (`JmapClient` and
/// `ConnectionTestService`) enforce the same rule with `JmapClient.isSecureUrl`
/// so a missing validator cannot re-open the leak.
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
