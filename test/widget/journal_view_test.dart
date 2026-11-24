import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/entry.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';

import 'entries_fakes.dart';

/// Opens the Journal tab of the entries home of acc-1 on 2026-11-23.
Future<FakeEntryRepository> _pump(
  WidgetTester tester, {
  List<Entry> entries = const [],
}) async {
  final repo = FakeEntryRepository(entries);
  await pumpEntriesApp(
    tester,
    repo: repo,
    store: FakeConflictStore({}),
    today: () => DateTime(2026, 11, 23, 9),
  );
  await tester.tap(find.byKey(const Key('entriesTab_journal')));
  await tester.pumpAndSettle();
  return repo;
}

List<Entry> _journal() => [
      testEntry('note', body: 'Not in the journal'),
      testEntry('t2', body: 'Lunch', date: '2026-11-23', minute: 2),
      testEntry('t1', body: 'Morning', date: '2026-11-23', minute: 1),
      testEntry('old', body: 'Long ago', date: '2026-11-15'),
      testEntry('past', body: 'Friday', date: '2026-11-20'),
      testEntry('future', body: 'Plans', date: '2026-11-30'),
    ];

String _day(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('journalDay'))).data!;

bool _enabled(WidgetTester tester, String key) =>
    tester.widget<IconButton>(find.byKey(Key(key))).onPressed != null;

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets("today's entries show first, oldest first", (tester) async {
    await _pump(tester, entries: _journal());
    expect(_day(tester), 'Mon, Nov 23, 2026');
    expect(
      tester.getTopLeft(find.text('Morning')).dy,
      lessThan(tester.getTopLeft(find.text('Lunch')).dy),
    );
    expect(find.text('Friday'), findsNothing);
    expect(find.text('Not in the journal'), findsNothing);
    expect(find.byKey(const Key('journalToday')), findsNothing);
  });

  testWidgets('‹ and › move one day; Today goes back', (tester) async {
    await _pump(tester, entries: _journal());
    await _tap(tester, 'journalPrevDay');
    expect(_day(tester), 'Sun, Nov 22, 2026');
    expect(find.text('No entries for this day.'), findsOneWidget);
    await _tap(tester, 'journalPrevDay');
    await _tap(tester, 'journalPrevDay');
    expect(_day(tester), 'Fri, Nov 20, 2026');
    expect(find.text('Friday'), findsOneWidget);
    await _tap(tester, 'journalNextDay');
    expect(_day(tester), 'Sat, Nov 21, 2026');

    await _tap(tester, 'journalToday');
    expect(_day(tester), 'Mon, Nov 23, 2026');
    expect(find.text('Morning'), findsOneWidget);
    expect(find.byKey(const Key('journalToday')), findsNothing);
  });

  testWidgets('the jumps go to the next day with entries, off at the edges',
      (tester) async {
    await _pump(tester, entries: _journal());
    await _tap(tester, 'journalPrevFilled');
    expect(_day(tester), 'Fri, Nov 20, 2026');
    await _tap(tester, 'journalPrevFilled');
    expect(_day(tester), 'Sun, Nov 15, 2026');
    expect(find.text('Long ago'), findsOneWidget);
    expect(_enabled(tester, 'journalPrevFilled'), isFalse);

    await _tap(tester, 'journalNextFilled');
    expect(_day(tester), 'Fri, Nov 20, 2026');
    await _tap(tester, 'journalNextFilled');
    await _tap(tester, 'journalNextFilled');
    expect(_day(tester), 'Mon, Nov 30, 2026');
    expect(find.text('Plans'), findsOneWidget);
    expect(_enabled(tester, 'journalNextFilled'), isFalse);
    expect(_enabled(tester, 'journalPrevFilled'), isTrue);
  });

  testWidgets('a day picked in the calendar is shown', (tester) async {
    await _pump(tester, entries: _journal());
    await _tap(tester, 'journalPickDay');
    await tester.tap(find.text('20'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(_day(tester), 'Fri, Nov 20, 2026');
    expect(find.text('Friday'), findsOneWidget);
  });

  testWidgets('"New entry" on a past day writes it for that day and opens it',
      (tester) async {
    final repo = await _pump(tester, entries: _journal());
    await _tap(tester, 'journalPrevDay');
    await _tap(tester, 'journalNewEntry');
    final created = repo.entries.last;
    expect(created.date, '2026-11-22');
    expect(created.body, '');
    expect(find.byKey(const Key('entryEditDate')), findsOneWidget);
  });

  testWidgets('"New entry" left without typing is deleted again',
      (tester) async {
    final repo = await _pump(tester);
    await _tap(tester, 'journalNewEntry');
    expect(repo.entries, hasLength(1));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(repo.entries, isEmpty);
    expect(find.text('No entries for this day.'), findsOneWidget);
  });

  testWidgets('"New entry" with text typed is kept', (tester) async {
    final repo = await _pump(tester);
    await _tap(tester, 'journalNewEntry');
    await tester.enterText(
      find.byKey(const Key('entryEditBody')),
      'Dear diary',
    );
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(repo.entries.single.body, 'Dear diary');
    expect(repo.entries.single.date, isNotNull);
  });

  testWidgets('"New entry" with only Todo turned on is kept', (tester) async {
    final repo = await _pump(tester);
    await _tap(tester, 'journalNewEntry');
    await tester.tap(find.byKey(const Key('entryTodoSwitch')));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(repo.entries.single.task, isNotNull);
  });

  testWidgets('"New entry": a failed save, then Discard, deletes it',
      (tester) async {
    final repo = await _pump(tester);
    await _tap(tester, 'journalNewEntry');
    repo.failUpdateWith = Exception('offline');
    await tester.enterText(find.byKey(const Key('entryEditBody')), 'x');
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('entryEditDiscard')));
    await tester.pumpAndSettle();
    expect(repo.entries, isEmpty);
  });

  testWidgets('"New entry" while locked asks to unlock', (tester) async {
    final repo = await _pump(tester);
    expect(find.text('No entries for this day.'), findsOneWidget);
    repo.failCreateWith = const NoWriteKeyException('personal');
    await _tap(tester, 'journalNewEntry');
    expect(find.text('Unlock personal data to add entries.'), findsOneWidget);
  });
}
