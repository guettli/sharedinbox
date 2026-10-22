/// The bare address in what was typed or pasted as a sender:
/// `alice@example.com`, `Alice <alice@example.com>` or
/// `mailto:alice@example.com?subject=…`. Null when it is not an address.
/// Callers compare it with a sender's bare address, so anything else could
/// never match.
String? senderAddress(String input) {
  final address = _unwrap(input);
  return _address.hasMatch(address) ? address : null;
}

/// The entry to store for what was typed into "Allowed addresses for images",
/// lowercased, or null for anything that could never match a sender (`foo`).
/// It is matched with `globMatch` (`*` any characters, `?` one character)
/// against the sender's bare address, so it must be one of:
/// - an address, wildcards allowed: `bob@example.org`, `*@example.com`,
///   `bob@*`; also taken out of `Name <address>` / `mailto:`;
/// - a bare domain, `example.com` or `@example.com`, which becomes
///   `*@example.com` (not `*example.com`, which would also let in
///   lookalikes such as `evilexample.com`);
/// - without an `@`, a glob containing `*` (`*example.com`, `*`). A `?`
///   alone cannot stand for the `@` and the parts around it.
String? trustedImageSenderPattern(String input) {
  var pattern = _unwrap(input).toLowerCase();
  if (pattern.startsWith('@')) pattern = pattern.substring(1);
  if (_domain.hasMatch(pattern)) return '*@$pattern';
  if (pattern.contains('@')) {
    return _address.hasMatch(pattern) ? pattern : null;
  }
  return pattern.contains('*') && !pattern.contains(_spaceOrBracket)
      ? pattern
      : null;
}

final _address = RegExp(r'^[^\s@<>]+@[^\s@<>]+$');
final _domain = RegExp(r'^[a-z0-9-]+(\.[a-z0-9-]+)+$');
final _spaceOrBracket = RegExp(r'[\s<>]');
final _bracketed = RegExp(r'<([^<>]*)>\s*$');
final _mailto = RegExp(r'^mailto:([^?]*)(\?.*)?$', caseSensitive: false);

String _unwrap(String input) {
  final bracketed = _bracketed.firstMatch(input.trim());
  final value = (bracketed?.group(1) ?? input).trim();
  // A `?` after `mailto:` starts the query (`?subject=…`), not a glob.
  return _mailto.firstMatch(value)?.group(1)?.trim() ?? value;
}
