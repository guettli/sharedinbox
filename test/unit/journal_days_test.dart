import 'package:sharedinbox/core/models/entry.dart';
import 'package:sharedinbox/core/utils/journal_days.dart';
import 'package:test/test.dart';

Entry _entry(String itemId, String? date, {int minute = 0}) => Entry(
      accountId: 'a',
      itemId: itemId,
      itemHmac: 'h-$itemId',
      date: date,
      versionId: 'v-$itemId',
      updatedAt: DateTime.utc(2026, 11, 23, 10, minute),
    );

void main() {
  test('only real YYYY-MM-DD dates parse', () {
    expect(parseJournalDate('2026-11-23'), DateTime(2026, 11, 23));
    expect(parseJournalDate('2028-02-29'), DateTime(2028, 2, 29));
    for (final bad in [
      null,
      '',
      '2026-02-30',
      '2026-13-01',
      '2026-00-10',
      '20261123',
      '2026-11-23T10:00',
      '2026-11-23 ',
      '2026-1-3',
    ]) {
      expect(parseJournalDate(bad), isNull, reason: '$bad');
    }
  });

  test('isoDate is the local day, also close to midnight', () {
    expect(isoDate(DateTime(2026, 11, 23, 23, 59, 59)), '2026-11-23');
    expect(isoDate(DateTime(2026, 11, 24)), '2026-11-24');
    expect(isoDate(DateTime(2026, 1, 2, 0, 0, 1)), '2026-01-02');
  });

  test('grouped by date, newest day first, several per day in a stable order',
      () {
    final days = groupJournal([
      _entry('c', '2026-11-23', minute: 5),
      _entry('old', '2026-11-20'),
      _entry('b', '2026-11-23', minute: 1),
      _entry('a', '2026-11-23', minute: 1),
    ]);
    expect([for (final d in days) d.date], ['2026-11-23', '2026-11-20']);
    expect(days.first.day, DateTime(2026, 11, 23));
    expect([for (final e in days.first.entries) e.itemId], ['a', 'b', 'c']);
    expect([for (final e in days.last.entries) e.itemId], ['old']);
  });

  test('entries without a date or with a malformed one are left out', () {
    final days = groupJournal([
      _entry('none', null),
      _entry('bad', '2026-02-30'),
      _entry('time', '2026-11-23T08:00:00Z'),
      _entry('ok', '2026-11-23'),
    ]);
    expect(days, hasLength(1));
    expect(days.single.entries.single.itemId, 'ok');
    expect(groupJournal(const []), isEmpty);
  });

  test('the previous and next day with entries', () {
    final days = groupJournal([
      _entry('a', '2026-11-23'),
      _entry('b', '2026-11-20'),
      _entry('c', '2026-11-15'),
    ]);
    expect(previousDayWithEntries(days, '2026-11-23'), '2026-11-20');
    expect(nextDayWithEntries(days, '2026-11-20'), '2026-11-23');
    // From a day without entries.
    expect(previousDayWithEntries(days, '2026-11-22'), '2026-11-20');
    expect(nextDayWithEntries(days, '2026-11-16'), '2026-11-20');
    // At the edges.
    expect(previousDayWithEntries(days, '2026-11-15'), isNull);
    expect(nextDayWithEntries(days, '2026-11-23'), isNull);
    expect(previousDayWithEntries(days, '2026-01-01'), isNull);
    expect(nextDayWithEntries(days, '2027-01-01'), isNull);
    expect(previousDayWithEntries(const [], '2026-11-23'), isNull);
  });
}
