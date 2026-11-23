import 'package:sharedinbox/core/models/entry.dart';

final _isoDay = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

/// The local day of a `date` field, or null unless it is a real
/// `YYYY-MM-DD` date (no time part, no `2026-02-30`).
DateTime? parseJournalDate(String? date) {
  final m = _isoDay.firstMatch(date ?? '');
  if (m == null) return null;
  final day = DateTime(
    int.parse(m[1]!),
    int.parse(m[2]!),
    int.parse(m[3]!),
  );
  if (isoDate(day) != date) return null;
  return day;
}

/// The journal entries of one day (#1358).
class JournalDay {
  const JournalDay({
    required this.date,
    required this.day,
    required this.entries,
  });

  /// `YYYY-MM-DD`.
  final String date;

  /// [date] as a local day.
  final DateTime day;

  /// Oldest edit first.
  final List<Entry> entries;
}

/// [entries] grouped by their `date`, newest day first; within a day oldest
/// edit first, then by itemId. Entries without a valid `date` are left out.
List<JournalDay> groupJournal(List<Entry> entries) {
  final byDate = <String, List<Entry>>{};
  for (final e in entries) {
    final date = e.date;
    if (parseJournalDate(date) == null) continue;
    byDate.putIfAbsent(date!, () => []).add(e);
  }
  final dates = byDate.keys.toList()..sort((a, b) => b.compareTo(a));
  return [
    for (final date in dates)
      JournalDay(
        date: date,
        day: parseJournalDate(date)!,
        entries: byDate[date]!
          ..sort((a, b) {
            final updated = a.updatedAt.compareTo(b.updatedAt);
            if (updated != 0) return updated;
            return a.itemId.compareTo(b.itemId);
          }),
      ),
  ];
}

/// The newest day of [days] (newest first) before [date], or null.
String? previousDayWithEntries(List<JournalDay> days, String date) {
  for (final d in days) {
    if (d.date.compareTo(date) < 0) return d.date;
  }
  return null;
}

/// The oldest day of [days] (newest first) after [date], or null.
String? nextDayWithEntries(List<JournalDay> days, String date) {
  for (final d in days.reversed) {
    if (d.date.compareTo(date) > 0) return d.date;
  }
  return null;
}
