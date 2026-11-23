import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/entry.dart';
import 'package:sharedinbox/core/services/encrypted_key_service.dart';
import 'package:sharedinbox/di.dart';

import 'entries_fakes.dart';
import 'helpers.dart';

Future<FakeEntryRepository> _pump(
  WidgetTester tester, {
  List<Entry> entries = const [],
  bool beta = true,
  PersonalDataStatus status = PersonalDataStatus.unlocked,
  String location = '/accounts/acc-1/entries',
  FakeConflictStore? store,
}) async {
  final repo = FakeEntryRepository(entries);
  await tester.pumpWidget(
    buildApp(
      initialLocation: location,
      userPreferences: FakeUserPreferencesRepository(personalDataBeta: beta),
      overrides: [
        ...baseOverrides(accounts: [kTestAccount]),
        encryptedKeyServiceProvider
            .overrideWithValue(FixedStatusKeyService(status)),
        entryRepositoryProvider.overrideWithValue(repo),
        mailObjectStoreProvider
            .overrideWithValue(store ?? FakeConflictStore({})),
      ],
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  testWidgets('quick add shows the entry at once and clears the field',
      (tester) async {
    final repo = await _pump(tester);
    expect(find.text('No entries yet.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('entriesQuickAdd')),
      'Call Bob about the offer',
    );
    await tester.tap(find.byKey(const Key('entriesQuickAddSend')));
    // No time passes: the list updates from the local write alone, in the
    // next frames.
    await tester.pump();
    await tester.pump();

    expect(find.text('Call Bob about the offer'), findsOneWidget);
    final field = tester.widget<TextField>(
      find.byKey(const Key('entriesQuickAdd')),
    );
    expect(field.controller!.text, isEmpty);
    expect(repo.entries.single.title, isNull);
    expect(repo.entries.single.body, 'Call Bob about the offer');
  });

  testWidgets('a row shows the title, or else the first line of the body',
      (tester) async {
    await _pump(
      tester,
      entries: [
        testEntry('t', title: 'Titled', body: 'its body', minute: 2),
        testEntry('b', body: '\nFirst line\nsecond line', minute: 1),
      ],
    );
    expect(find.text('Titled'), findsOneWidget);
    expect(find.textContaining('its body'), findsOneWidget);
    expect(find.text('First line'), findsOneWidget);
    expect(find.textContaining('second line'), findsOneWidget);
    // Newest first.
    expect(
      tester.getTopLeft(find.text('Titled')).dy,
      lessThan(tester.getTopLeft(find.text('First line')).dy),
    );
  });

  testWidgets('search filters the list', (tester) async {
    await _pump(
      tester,
      entries: [
        testEntry('a', title: 'Groceries', body: 'milk'),
        testEntry('b', body: 'Dentist on Monday'),
      ],
    );
    await tester.enterText(find.byKey(const Key('entriesSearch')), 'MILK');
    await tester.pumpAndSettle();
    expect(find.text('Groceries'), findsOneWidget);
    expect(find.text('Dentist on Monday'), findsNothing);

    await tester.enterText(find.byKey(const Key('entriesSearch')), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('No match.'), findsOneWidget);
  });

  testWidgets('a conflict shows an icon', (tester) async {
    await _pump(
      tester,
      entries: [
        testEntry('c', body: 'clash', conflict: true),
        testEntry('d', body: 'calm'),
      ],
    );
    expect(find.byKey(const Key('entryConflict_c')), findsOneWidget);
    expect(find.byKey(const Key('entryConflict_d')), findsNothing);
    // No conflict in the store: no badge.
    expect(find.byKey(const Key('entriesConflictsBadge')), findsNothing);
  });

  testWidgets('the conflict icon opens the conflict view of the entry',
      (tester) async {
    await _pump(
      tester,
      entries: [testEntry('c', body: 'clash', conflict: true)],
      store: FakeConflictStore({
        'hmac-c': conflictItemOf([
          entryVersion('devA', 1, body: 'mine'),
          entryVersion('devB', 2, body: 'theirs'),
        ]),
      }),
    );
    await tester.tap(find.byKey(const Key('entryConflict_c')));
    await tester.pumpAndSettle();
    expect(find.text('Resolve conflict'), findsOneWidget);
    expect(find.byKey(const Key('conflictVersion_1')), findsOneWidget);
  });

  testWidgets('the badge shows the conflicts and opens their list',
      (tester) async {
    await _pump(
      tester,
      entries: [testEntry('c', body: 'clash', conflict: true)],
      store: FakeConflictStore({
        'hmac-c': conflictItemOf([
          entryVersion('devA', 1, title: 'Mine', body: 'a'),
          entryVersion('devB', 2, title: 'Theirs', body: 'b'),
        ]),
      }),
    );
    final badge = find.byKey(const Key('entriesConflictsBadge'));
    expect(badge, findsOneWidget);
    expect(
      find.descendant(of: badge, matching: find.text('1')),
      findsOneWidget,
    );

    await tester.tap(badge);
    await tester.pumpAndSettle();
    expect(find.text('Conflicts'), findsOneWidget);
    final row = find.byKey(const Key('conflict_hmac-c'));
    expect(row, findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.text('Theirs')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.textContaining('2 versions')),
      findsOneWidget,
    );

    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.text('Resolve conflict'), findsOneWidget);
  });

  testWidgets('delete asks first', (tester) async {
    final repo = await _pump(
      tester,
      entries: [testEntry('x', body: 'Old note')],
    );
    await tester.tap(find.byKey(const Key('entryMenu_x')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('entryDelete')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(repo.entries, hasLength(1));

    await tester.tap(find.byKey(const Key('entryMenu_x')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('entryDelete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('entryDeleteConfirm')));
    await tester.pumpAndSettle();
    expect(repo.entries, isEmpty);
    expect(find.text('Old note'), findsNothing);
  });

  testWidgets('tapping a row opens the edit screen', (tester) async {
    await _pump(tester, entries: [testEntry('x', title: 'Open me')]);
    await tester.tap(find.text('Open me'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('entryEditTitle')), findsOneWidget);
  });

  testWidgets('hidden while the beta switch is off', (tester) async {
    await _pump(tester, beta: false, entries: [testEntry('x', title: 'Hid')]);
    expect(find.textContaining('Personal data (beta)'), findsOneWidget);
    expect(find.byKey(const Key('entriesQuickAdd')), findsNothing);
    expect(find.text('Hid'), findsNothing);
  });

  testWidgets('hidden while the account is locked', (tester) async {
    await _pump(
      tester,
      status: PersonalDataStatus.locked,
      entries: [testEntry('x', title: 'Hid')],
    );
    expect(find.byKey(const Key('entriesQuickAdd')), findsNothing);
    expect(find.text('Hid'), findsNothing);
    expect(find.byKey(const Key('entriesOpenPersonalData')), findsOneWidget);
  });
}
