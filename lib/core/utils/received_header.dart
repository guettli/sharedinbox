/// Parses the timestamp from a `Received:` header value and returns it as a
/// UTC [DateTime], or `null` if no timestamp can be found.
///
/// A well-formed Received header ends with `; date-time`, e.g.
/// `by mx.example.com; Mon, 1 Jan 2024 12:00:00 +0530 (IST)`. Some servers
/// (notably SendGrid) omit the `;` delimiter and/or stamp a Go-style
/// timestamp such as `2026-07-15 12:31:15.463485615 +0000 UTC m=+481743...`,
/// so the RFC 5322 date is looked for after the last `;` when present and
/// otherwise anywhere in the value, and both the RFC 5322 and the ISO-8601 /
/// Go layouts are attempted.
///
/// Dart's `intl` `DateFormat.parse` does not apply the parsed numeric zone
/// offset to the resulting instant, so naive parsing yields wrong durations
/// when consecutive hops report times in different time zones. This parser
/// reads the offset itself and normalises every timestamp to UTC, so that
/// subtracting two parsed values gives the real wall-clock delay.
DateTime? parseReceivedTimestamp(String value) {
  // Prefer the region after the last `;` (the RFC 5322 date position), but
  // fall back to the whole value for headers that omit the delimiter.
  final semiIndex = value.lastIndexOf(';');
  var s = semiIndex >= 0 ? value.substring(semiIndex + 1) : value;
  // Strip parenthesised comments like (UTC) or (IST).
  s = s.replaceAll(RegExp(r'\([^)]*\)'), ' ');
  // Collapse runs of whitespace.
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();

  return _parseRfc5322(s) ?? _parseIso8601(s);
}

/// RFC 5322 date-time: `[Day, ]D[D] Mon YYYY HH:MM:SS[.fff] [±HHMM|zone-name]`.
/// Matched unanchored so a leading day-of-week and surrounding text are
/// tolerated.
DateTime? _parseRfc5322(String s) {
  final match = RegExp(
    r'(\d{1,2}) ([A-Za-z]{3}) (\d{2,4}) '
    r'(\d{1,2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?'
    r'(?:\s+([+-]\d{4}|[A-Za-z]{1,5}))?',
  ).firstMatch(s);
  if (match == null) return null;

  final day = int.parse(match.group(1)!);
  final month = _monthNumber(match.group(2)!);
  if (month == null) return null;
  var year = int.parse(match.group(3)!);
  // RFC 5322 §4.3 obsolete two/three-digit year handling.
  if (year < 50) {
    year += 2000;
  } else if (year < 1000) {
    year += 1900;
  }
  return _utcFromTimeGroups(year, month, day, match);
}

/// ISO-8601 / Go date-time: `YYYY-MM-DD[ T]HH:MM[:SS][.fff] [±HHMM|zone-name]`.
/// Trailing noise such as `UTC` or a Go monotonic-clock suffix (`m=+...`) is
/// ignored. A missing offset is treated as UTC.
DateTime? _parseIso8601(String s) {
  final match = RegExp(
    r'(\d{4})-(\d{2})-(\d{2})[ T](\d{1,2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?'
    r'(?:\s*([+-]\d{4}|[A-Za-z]{2,5}))?',
  ).firstMatch(s);
  if (match == null) return null;

  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  return _utcFromTimeGroups(year, month, day, match);
}

/// Builds a UTC [DateTime] from the shared time groups of both date layouts:
/// group 4 = hour, 5 = minute, 6 = optional second, 7 = optional zone. The
/// parsed offset is subtracted so the result is a true UTC instant.
DateTime _utcFromTimeGroups(int year, int month, int day, RegExpMatch match) {
  final hour = int.parse(match.group(4)!);
  final minute = int.parse(match.group(5)!);
  final second = int.parse(match.group(6) ?? '0');
  final offsetMinutes = _zoneOffsetMinutes(match.group(7));

  return DateTime.utc(year, month, day, hour, minute, second)
      .subtract(Duration(minutes: offsetMinutes));
}

int? _monthNumber(String name) {
  const months = {
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  };
  return months[name.toLowerCase()];
}

/// Returns the zone's offset from UTC in minutes, or 0 if [zone] is null,
/// unknown, or one of the RFC 5322 "obsolete" placeholders that map to UTC.
int _zoneOffsetMinutes(String? zone) {
  if (zone == null || zone.isEmpty) return 0;
  if (zone.startsWith('+') || zone.startsWith('-')) {
    final sign = zone.startsWith('-') ? -1 : 1;
    final hours = int.parse(zone.substring(1, 3));
    final minutes = int.parse(zone.substring(3, 5));
    return sign * (hours * 60 + minutes);
  }
  // RFC 5322 §4.3 named obsolete zones.
  const namedZones = {
    'UT': 0,
    'UTC': 0,
    'GMT': 0,
    'Z': 0,
    'EST': -5 * 60,
    'EDT': -4 * 60,
    'CST': -6 * 60,
    'CDT': -5 * 60,
    'MST': -7 * 60,
    'MDT': -6 * 60,
    'PST': -8 * 60,
    'PDT': -7 * 60,
  };
  return namedZones[zone.toUpperCase()] ?? 0;
}
