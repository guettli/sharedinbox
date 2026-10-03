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

/// Returns [raw] with all surrounding `<>` pairs stripped and any
/// leading/trailing whitespace removed. Empty or `null` input yields `null`.
///
/// Repeated stripping canonicalises doubled brackets such as the
/// `<<foo@bar>>` `Message-ID` that Stalwart emits on delivery-status
/// notifications (see #859) down to the same bracket-less form the IMAP
/// ENVELOPE and JMAP arrays produce, so equality-based lookups still match.
String? normaliseMessageId(String? raw) {
  if (raw == null) return null;
  var id = raw.trim();
  if (id.isEmpty) return null;
  while (id.length >= 2 && id.startsWith('<') && id.endsWith('>')) {
    id = id.substring(1, id.length - 1);
  }
  return id.isEmpty ? null : id;
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
