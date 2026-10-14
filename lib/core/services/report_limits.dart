/// Caps (in runes) on the public bug-report fields that end up in the GitHub
/// issue. The bugreport server truncates with the identical numbers and marker
/// (`server/bugreport/untrusted.go`); its `TestReportLimitsMatchApp` fails if
/// the two ever drift apart (issue #930).
const reportTitleMaxRunes = 120;
const reportDescriptionMaxRunes = 8000;
const reportAboutInfoMaxRunes = 4000;

/// Ends a field that was cut to its cap. It counts towards the cap, so a
/// truncated field is exactly `limit` runes long.
const reportTruncationMarker = '…[truncated]';

/// Cuts [s] to at most [limit] runes, ending it with [reportTruncationMarker]
/// when anything was dropped — the same truncation the server applies, so a
/// report sent by the app is never cut a second time.
String truncateReportField(String s, int limit) {
  final runes = s.runes.toList();
  if (runes.length <= limit) return s;
  final keep = limit - reportTruncationMarker.runes.length;
  return String.fromCharCodes(runes.take(keep)) + reportTruncationMarker;
}
