/// Strips reply/forward prefixes and ticket-like tokens from [subject] so that
/// near-duplicate spam messages share an identical key.
///
/// Repeatedly removes leading `Re:`, `Fwd:`/`Fw:`, `AW:`, `WG:` prefixes
/// (case-insensitive, common European variants), drops `#1234`-style
/// ticket numbers and bracketed/parenthesised tokens, collapses any
/// remaining whitespace and lowercases the result.
///
/// Returns the empty string when [subject] is null or contains nothing
/// meaningful after stripping.
String normalizedSubject(String? subject) {
  if (subject == null) return '';
  var s = subject.trim();
  if (s.isEmpty) return '';

  // Strip leading reply/forward prefixes — possibly stacked, e.g. "Re: Fwd: …".
  final prefix = RegExp(r'^\s*(re|fwd?|aw|wg)\s*:\s*', caseSensitive: false);
  while (true) {
    final match = prefix.firstMatch(s);
    if (match == null) break;
    s = s.substring(match.end);
  }

  // Drop ticket-style tokens that change per occurrence but not per "kind".
  s = s.replaceAll(RegExp(r'#\d+'), ' ');
  s = s.replaceAll(RegExp(r'\[[^\]]*\]'), ' ');
  s = s.replaceAll(RegExp(r'\([^)]*\)'), ' ');

  // Collapse any whitespace (incl. non-breaking) to single spaces.
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s.toLowerCase();
}
