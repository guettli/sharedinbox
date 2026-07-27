/// Helpers for canonicalising RFC 2822 `Message-ID`, `In-Reply-To` and
/// `References` header values.
///
/// IMAP returns these with the RFC 5322 `<foo@bar>` angle brackets around
/// each id, whereas JMAP (RFC 8621 §4.1.2.3) returns arrays of strings
/// without the brackets. Storing both flavours side-by-side in the same
/// column breaks equality-based lookups (compare, threading, dedupe), so all
/// call sites route through these helpers to end up with one canonical
/// bracket-less form.
library;

/// Returns [raw] with a single pair of surrounding `<>` stripped and any
/// leading/trailing whitespace removed. Empty or `null` input yields `null`.
String? normaliseMessageId(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.startsWith('<') && trimmed.endsWith('>') && trimmed.length >= 2) {
    final inner = trimmed.substring(1, trimmed.length - 1);
    return inner.isEmpty ? null : inner;
  }
  return trimmed;
}

/// Normalises a whitespace-separated list of Message-IDs. Each token is run
/// through [normaliseMessageId]; empty tokens are dropped. Returns `null`
/// when the result is empty.
String? normaliseReferences(String? raw) {
  if (raw == null) return null;
  final tokens = raw
      .split(RegExp(r'\s+'))
      .map(normaliseMessageId)
      .whereType<String>()
      .toList();
  if (tokens.isEmpty) return null;
  return tokens.join(' ');
}
