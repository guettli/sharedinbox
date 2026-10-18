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

/// Normalises a list of Message-IDs to bracket-less ids joined by single
/// spaces. Whitespace and the `<`/`>` brackets all count as separators (an
/// id cannot contain either, RFC 5322 §3.6.4), so `<a><b>` without a space
/// and a half-stripped `a> <b` both come out as `a b`. Returns `null` when
/// no id is left.
String? normaliseReferences(String? raw) {
  if (raw == null) return null;
  final tokens =
      raw.split(RegExp(r'[\s<>]+')).where((t) => t.isNotEmpty).toList();
  if (tokens.isEmpty) return null;
  return tokens.join(' ');
}

/// How many of the most recent ancestors [replyThreading] keeps after the
/// thread root, so a long back-and-forth does not grow References without
/// bound (RFC 5322 §3.6.4 allows trimming; the root and the nearest
/// ancestors are what clients thread on).
const maxReplyReferenceTail = 20;

/// The `In-Reply-To` and `References` ids a reply must carry (RFC 5322
/// §3.6.4), given the parent's stored headers: the parent's own id, and the
/// parent's References (or, lacking those, its In-Reply-To) followed by the
/// parent's id, trimmed to the root plus the last [maxReplyReferenceTail]
/// ids. All ids come back bracket-less. Returns null when the parent has no
/// Message-ID, since a reply to it cannot be threaded at all.
({String inReplyTo, List<String> references})? replyThreading({
  required String? messageId,
  String? inReplyTo,
  String? references,
}) {
  final parent = normaliseMessageId(messageId);
  if (parent == null) return null;
  final ancestors =
      normaliseReferences(references) ?? normaliseReferences(inReplyTo) ?? '';
  final chain = [
    for (final id in ancestors.split(' '))
      if (id.isNotEmpty && id != parent) id,
    parent,
  ];
  if (chain.length > maxReplyReferenceTail + 1) {
    chain.replaceRange(1, chain.length - maxReplyReferenceTail, const []);
  }
  return (inReplyTo: parent, references: chain);
}

/// Renders bracket-less ids as an RFC 5322 header value: `<a> <b>`.
String bracketMessageIds(Iterable<String> ids) =>
    ids.map((id) => '<$id>').join(' ');

/// [ids] (a draft's References) run through [normaliseMessageId], dropping
/// any that end up empty, so senders never bracket an id twice.
List<String> normaliseDraftReferences(Iterable<String> ids) =>
    ids.map(normaliseMessageId).whereType<String>().toList();
