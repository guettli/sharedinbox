/// The bare address in what was typed or pasted as a sender:
/// `alice@example.com`, `Alice <alice@example.com>` or
/// `mailto:alice@example.com`. Null when it is not an address. Callers compare
/// it with a sender's bare address, so anything else could never match.
String? senderAddress(String input) {
  final address = _unwrap(input);
  return _address.hasMatch(address) ? address : null;
}

/// The entry to store for what was typed into "Allowed addresses for images",
/// lowercased: a bare address (also out of `Name <address>`) or a `*`/`?` glob
/// such as `*@example.com`, matched with `globMatch` against the sender's bare
/// address. Null for anything that could never match a sender, e.g. `foo`.
String? trustedImageSenderPattern(String input) {
  final pattern = _unwrap(input).toLowerCase();
  if (pattern.contains('@')) {
    return _address.hasMatch(pattern) ? pattern : null;
  }
  // No `@`: only a wildcard can stand for it (`*example.com`, `*`).
  return pattern.contains('*') && !pattern.contains(RegExp(r'[\s<>]'))
      ? pattern
      : null;
}

final _address = RegExp(r'^[^\s@<>]+@[^\s@<>]+$');

String _unwrap(String input) {
  final bracketed = RegExp(r'<([^<>]*)>\s*$').firstMatch(input.trim());
  return (bracketed?.group(1) ?? input)
      .trim()
      .replaceFirst(RegExp('^mailto:', caseSensitive: false), '');
}
