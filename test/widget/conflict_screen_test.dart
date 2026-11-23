import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/core/services/encrypted_key_service.dart';
import 'package:sharedinbox/di.dart';

import 'entries_fakes.dart';
import 'helpers.dart';

/// Opens the conflict view of `hmac-1` with [versions] as its heads, on a
/// screen [width] logical pixels wide.
Future<FakeConflictStore> _pump(
  WidgetTester tester,
  List<InnerObject> versions, {
  double width = 400,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 2400);
  addTearDown(tester.view.reset);
  final store = FakeConflictStore({'hmac-1': conflictItemOf(versions)});
  await tester.pumpWidget(
    buildApp(
      initialLocation: '/accounts/acc-1/entries',
      userPreferences: FakeUserPreferencesRepository(personalDataBeta: true),
      overrides: [
        ...baseOverrides(accounts: [kTestAccount]),
        encryptedKeyServiceProvider.overrideWithValue(
          FixedStatusKeyService(PersonalDataStatus.unlocked),
        ),
        entryRepositoryProvider.overrideWithValue(FakeEntryRepository()),
        mailObjectStoreProvider.overrideWithValue(store),
      ],
    ),
  );
  await tester.pumpAndSettle();
  // From the entries screen, so the view has a route to go back to.
  await tester.tap(find.byKey(const Key('entriesConflictsBadge')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('conflict_hmac-1')));
  await tester.pumpAndSettle();
  return store;
}

void main() {
  testWidgets('"Keep this" resolves with that version and goes back',
      (tester) async {
    final mine = entryVersion('devA', 1, body: 'mine');
    final theirs = entryVersion('devB', 2, body: 'theirs');
    final store = await _pump(tester, [mine, theirs]);
    expect(find.text('Resolve conflict'), findsOneWidget);
    // Own device, the other one, and the newest marked.
    expect(find.textContaining('This device'), findsOneWidget);
    expect(find.textContaining('Device devB'), findsOneWidget);
    expect(find.byKey(const Key('conflictNewest_1')), findsOneWidget);
    expect(find.byKey(const Key('conflictNewest_0')), findsNothing);
    expect(find.text('Keep both'), findsNWidgets(2));

    await tester.tap(find.byKey(const Key('conflictKeep_0')));
    await tester.pumpAndSettle();
    expect(store.resolved.single.itemHmac, 'hmac-1');
    expect(store.resolved.single.keep, mine.head.versionId);
    expect(store.keptAll, isEmpty);
    expect(find.text('Conflict resolved.'), findsOneWidget);
    expect(find.text('Conflicts'), findsOneWidget);
    expect(find.text('No conflicts.'), findsNothing);
  });

  testWidgets('"Keep both" keeps all versions', (tester) async {
    final mine = entryVersion('devA', 1, body: 'mine');
    final theirs = entryVersion('devB', 2, body: 'theirs');
    final store = await _pump(tester, [mine, theirs]);

    await tester.tap(find.byKey(const Key('conflictKeepAll_1')));
    await tester.pumpAndSettle();
    expect(store.keptAll.single.keep, theirs.head.versionId);
    expect(store.resolved, isEmpty);
    expect(find.textContaining('kept as new items'), findsOneWidget);
  });

  testWidgets('an edit against a deletion has no "Keep both"', (tester) async {
    final edited = entryVersion('devA', 1, body: 'edited');
    final deleted = entryVersion('devB', 2, deleted: true);
    final store = await _pump(tester, [edited, deleted]);
    expect(find.byKey(const Key('conflictDeleted_1')), findsOneWidget);
    expect(find.text('Keep deleted'), findsOneWidget);
    expect(find.byKey(const Key('conflictKeepAll_0')), findsNothing);
    expect(find.byKey(const Key('conflictKeepAll_1')), findsNothing);

    await tester.tap(find.text('Keep deleted'));
    await tester.pumpAndSettle();
    expect(store.resolved.single.keep, deleted.head.versionId);
  });

  testWidgets('three live versions offer "Keep all (3)"', (tester) async {
    await _pump(tester, [
      entryVersion('devA', 1, body: 'one'),
      entryVersion('devB', 2, body: 'two'),
      entryVersion('devC', 3, body: 'three'),
    ]);
    expect(find.text('Keep all (3)'), findsNWidgets(3));
    expect(find.text('Keep both'), findsNothing);
  });

  for (final (name, width, twoColumns) in [
    ('narrow', 400.0, false),
    ('wide', 1000.0, true),
  ]) {
    testWidgets('$name: diff lines against the newest version', (tester) async {
      await _pump(
        tester,
        [
          entryVersion('devA', 1, title: 'T', body: 'same\nmine'),
          entryVersion('devB', 2, title: 'T', body: 'same\ntheirs'),
        ],
        width: width,
      );
      final diff = find.byKey(const Key('conflictDiff_0'));
      expect(diff, findsOneWidget);
      expect(find.byKey(const Key('conflictDiff_1')), findsNothing);
      expect(
        find.descendant(of: diff, matching: find.text('- theirs')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: diff, matching: find.text('+ mine')),
        findsOneWidget,
      );
      final first = tester.getTopLeft(
        find.byKey(const Key('conflictVersion_0')),
      );
      final second = tester.getTopLeft(
        find.byKey(const Key('conflictVersion_1')),
      );
      expect(first.dy == second.dy, twoColumns);
      expect(first.dx < second.dx, twoColumns);
    });
  }

  testWidgets('a version resolved meanwhile shows the versions again',
      (tester) async {
    final store = await _pump(tester, [
      entryVersion('devA', 1, body: 'mine'),
      entryVersion('devB', 2, body: 'theirs'),
    ]);
    store.failWith = const ConflictChangedException('not in conflict');
    await tester.tap(find.byKey(const Key('conflictKeep_0')));
    await tester.pumpAndSettle();
    expect(find.textContaining('changed meanwhile'), findsOneWidget);
    expect(find.text('Resolve conflict'), findsOneWidget);

    store.items.clear();
    store.failWith = const ConflictChangedException('not in conflict');
    await tester.tap(find.byKey(const Key('conflictKeep_0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('conflictResolved')), findsOneWidget);
  });

  testWidgets('an error keeps the view open', (tester) async {
    final store = await _pump(tester, [
      entryVersion('devA', 1, body: 'mine'),
      entryVersion('devB', 2, body: 'theirs'),
    ]);
    store.failWith = Exception('offline');
    await tester.tap(find.byKey(const Key('conflictKeepAll_0')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not resolve'), findsOneWidget);
    expect(find.text('Resolve conflict'), findsOneWidget);
  });
}
