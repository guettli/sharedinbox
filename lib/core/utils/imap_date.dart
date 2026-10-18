const _months = {
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

/// `dd-Mon-yyyy HH:mm:ss ±hhmm`; the day may be space-padded (" 5-Oct-...").
final _imapDateTime = RegExp(
  r'^"?\s*(\d{1,2})-([A-Za-z]{3})-(\d{4}) (\d{2}):(\d{2}):(\d{2}) ([+-])(\d{2})(\d{2})"?$',
);

/// Parses an IMAP `date-time` (RFC 3501 §9), the format of `INTERNALDATE`,
/// e.g. `17-Jul-1996 02:44:25 -0700`. Returns the instant in UTC, or null
/// when [value] is null or not in that format.
DateTime? parseImapDateTime(String? value) {
  if (value == null) return null;
  final m = _imapDateTime.firstMatch(value.trim());
  if (m == null) return null;
  final month = _months[m.group(2)!.toLowerCase()];
  if (month == null) return null;
  final local = DateTime.utc(
    int.parse(m.group(3)!),
    month,
    int.parse(m.group(1)!),
    int.parse(m.group(4)!),
    int.parse(m.group(5)!),
    int.parse(m.group(6)!),
  );
  final offset = Duration(
    hours: int.parse(m.group(8)!),
    minutes: int.parse(m.group(9)!),
  );
  return m.group(7) == '+' ? local.subtract(offset) : local.add(offset);
}
