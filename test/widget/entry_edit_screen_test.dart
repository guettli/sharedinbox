import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/services/encrypted_key_service.dart';
import 'package:sharedinbox/di.dart';

import 'entries_fakes.dart';
import 'helpers.dart';

Future<FakeEntryRepository> _pump(WidgetTester tester) async {
  final repo = FakeEntryRepository([
    testEntry('e1', title: 'Old title', body: 'old body', conflict: true),
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
      ],
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Old title'));
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  testWidgets('edit saves title and body and goes back', (tester) async {
    final repo = await _pump(tester);
    expect(find.byKey(const Key('entryEditConflict')), findsOneWidget);
    expect(find.text('old body'), findsOneWidget);

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
}
