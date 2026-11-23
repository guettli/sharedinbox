import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/services/encrypted_key_service.dart';
import 'package:sharedinbox/di.dart';

import 'entries_fakes.dart';
import 'helpers.dart';

Future<FakeEntryRepository> _pump(
  WidgetTester tester, {
  String body = 'old body',
  FakeConflictStore? store,
}) async {
  final repo = FakeEntryRepository([
    testEntry('e1', title: 'Old title', body: body, conflict: true),
  ]);
  await tester.pumpWidget(
    buildApp(
      initialLocation: '/accounts/acc-1/entries',
      userPreferences: FakeUserPreferencesRepository(personalDataBeta: true),
      overrides: [
        ...baseOverrides(accounts: [kTestAccount]),
        encryptedKeyServiceProvider.overrideWithValue(
          FixedStatusKeyService(PersonalDataStatus.unlocked),
        ),
        entryRepositoryProvider.overrideWithValue(repo),
        mailObjectStoreProvider
            .overrideWithValue(store ?? FakeConflictStore({})),
      ],
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Old title'));
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  testWidgets('"Resolve…" opens the conflict view, then reloads',
      (tester) async {
    final store = FakeConflictStore({
      'hmac-e1': conflictItemOf([
        entryVersion('devA', 1, body: 'mine'),
        entryVersion('devB', 2, body: 'theirs'),
      ]),
    });
    await _pump(tester, store: store);
    await tester.tap(find.byKey(const Key('entryEditResolve')));
    await tester.pumpAndSettle();
    expect(find.text('Resolve conflict'), findsOneWidget);

    await tester.tap(find.byKey(const Key('conflictKeep_0')));
    await tester.pumpAndSettle();
    expect(store.resolved.single.itemHmac, 'hmac-e1');
    expect(find.text('Entry'), findsOneWidget);
    expect(find.byKey(const Key('entryEditConflict')), findsOneWidget);
  });

  testWidgets('edit saves title and body and goes back', (tester) async {
    final repo = await _pump(tester);
    expect(find.byKey(const Key('entryEditConflict')), findsOneWidget);
    expect(find.textContaining('old body', findRichText: true), findsWidgets);

    await tester.tap(find.byKey(const Key('entryEditPreviewToggle')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('entryEditTitle')), 'New');
    await tester.enterText(
      find.byKey(const Key('entryEditBody')),
      'line 1\nline 2',
    );
    await tester.tap(find.byKey(const Key('entryEditSave')));
    await tester.pumpAndSettle();

    expect(
      repo.updates.single,
      (itemId: 'e1', title: 'New', body: 'line 1\nline 2'),
    );
    // Back on the list, which shows the saved entry.
    expect(find.byKey(const Key('entriesQuickAdd')), findsOneWidget);
    expect(find.text('New'), findsOneWidget);
  });

  testWidgets('delete from the edit screen asks, then goes back',
      (tester) async {
    final repo = await _pump(tester);
    await tester.tap(find.byKey(const Key('entryEditDelete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('entryDeleteConfirm')));
    await tester.pumpAndSettle();
    expect(repo.entries, isEmpty);
    expect(find.text('No entries yet.'), findsOneWidget);
  });

  testWidgets('a non-empty body opens in the preview, toggles to the editor',
      (tester) async {
    await _pump(tester, body: '**bold**');
    expect(find.byKey(const Key('entryPreview')), findsOneWidget);
    expect(find.byKey(const Key('entryEditBody')), findsNothing);

    await tester.tap(find.byKey(const Key('entryEditPreviewToggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('entryPreview')), findsNothing);
    await tester.enterText(find.byKey(const Key('entryEditBody')), '# Typed');

    await tester.tap(find.byKey(const Key('entryEditPreviewToggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('entryEditBody')), findsNothing);
    final preview = find.byKey(const Key('entryPreview'));
    expect(
      find.descendant(
        of: preview,
        matching: find.textContaining('Typed', findRichText: true),
      ),
      findsWidgets,
    );
    expect(
      find.descendant(
        of: preview,
        matching: find.textContaining('# Typed', findRichText: true),
      ),
      findsNothing,
    );
  });

  testWidgets('an empty body opens in the editor', (tester) async {
    await _pump(tester, body: '');
    expect(find.byKey(const Key('entryEditBody')), findsOneWidget);
    expect(find.byKey(const Key('entryPreview')), findsNothing);
  });

  testWidgets('ticking a checkbox saves a new version and stays',
      (tester) async {
    final repo = await _pump(tester, body: '- [ ] a\n- [x] b');
    final before = repo.entries.single.versionId;

    await tester.tap(find.byKey(const Key('entryTask_0')));
    await tester.pumpAndSettle();

    expect(repo.updates.single.body, '- [x] a\n- [x] b');
    expect(repo.updates.single.title, 'Old title');
    expect(repo.entries.single.versionId, isNot(before));
    expect(find.byKey(const Key('entryPreview')), findsOneWidget);
    expect(
      tester.widget<Checkbox>(find.byKey(const Key('entryTask_0'))).value,
      isTrue,
    );
  });

  testWidgets('a checkbox toggle includes pending edits', (tester) async {
    final repo = await _pump(tester, body: '- [ ] a');
    await tester.enterText(find.byKey(const Key('entryEditTitle')), 'Edited');
    await tester.tap(find.byKey(const Key('entryTask_0')));
    await tester.pumpAndSettle();
    expect(
      repo.updates.single,
      (itemId: 'e1', title: 'Edited', body: '- [x] a'),
    );
  });
}
