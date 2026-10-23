/// The IMAP system flags a Sieve script may set, keyed by lower case.
const _systemFlags = {
  r'\seen': r'\Seen',
  r'\flagged': r'\Flagged',
  r'\answered': r'\Answered',
  r'\draft': r'\Draft',
};

/// Characters that may not appear in an IMAP flag atom (RFC 3501
/// `atom-specials` minus SP and CTL, which the range check already rules out,
/// plus `\`, which only a system flag may carry as its first character).
const _atomSpecials = '(){]%*"\\';

/// Turns the flag strings of Sieve `setflag` / `addflag` actions into IMAP
/// flags that are safe to put on the wire.
///
/// Each string is a space-separated list of flags (RFC 5232 §3), so
/// `"Work Urgent"` is two keywords and `"\\Seen \\Flagged"` two system flags.
/// System flags come back in their canonical spelling (`\Seen`), keywords as
/// written; duplicates are dropped case-insensitively. Everything that is not
/// a valid flag atom (RFC 3501) is returned in `dropped` instead — a string
/// with CR or LF is dropped whole, so it can never break the IMAP command
/// line. `\Deleted` and `\Recent` are dropped too: the first only takes effect
/// on EXPUNGE and has no JMAP keyword, the second is server-managed.
({List<String> flags, List<String> dropped}) normalizeSieveFlags(
  Iterable<String> raw,
) {
  final flags = <String>[];
  final seen = <String>{};
  final dropped = <String>[];
  for (final value in raw) {
    if (value.contains('\r') || value.contains('\n')) {
      dropped.add(value);
      continue;
    }
    for (final part in value.split(RegExp(r'[ \t]+'))) {
      if (part.isEmpty) continue;
      // Tolerate a still-escaped `\\Seen` from hand-written scripts.
      final token = part.replaceFirst(RegExp(r'^\\+'), r'\');
      final flag = _validFlag(token);
      if (flag == null) {
        dropped.add(part);
      } else if (seen.add(flag.toLowerCase())) {
        flags.add(flag);
      }
    }
  }
  return (flags: flags, dropped: dropped);
}

String? _validFlag(String token) {
  if (token.startsWith(r'\')) return _systemFlags[token.toLowerCase()];
  if (token.isEmpty || token.length > 255) return null;
  for (final c in token.codeUnits) {
    if (c < 0x21 ||
        c > 0x7E ||
        _atomSpecials.contains(String.fromCharCode(c))) {
      return null;
    }
  }
  return token;
}
