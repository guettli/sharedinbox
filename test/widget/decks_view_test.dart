import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/import/card_import.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/core/services/encrypted_key_service.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/study_screen.dart';

import 'cards_fakes.dart';
import 'entries_fakes.dart';
import 'helpers.dart';

/// Opens the Cards tab of the entries home of acc-1 with two decks.
Future<FakeCardRepository> _pump(
  WidgetTester tester, {
  CardImporter? importer,
  PickedImportFile? picked,
}) async {
  final cards = FakeCardRepository(
    decks: [
      testDeck('deck-1', 'Spanish'),
      testDeck('deck-2', 'Biology', hasConflict: true),
    ],
    cards: [
      testCard('c1', 'deck-1', 'Gato', 'Cat'),
      testCard('c2', 'deck-1', 'Perro', 'Dog'),
    ],
  );
  await tester.pumpWidget(
    buildApp(
      initialLocation: '/accounts/acc-1/entries',
      userPreferences: FakeUserPreferencesRepository(personalDataBeta: true),
      overrides: [
        ...baseOverrides(),
        encryptedKeyServiceProvider.overrideWithValue(
          FixedStatusKeyService(PersonalDataStatus.unlocked),
        ),
        entryRepositoryProvider.overrideWithValue(FakeEntryRepository()),
        mailObjectStoreProvider.overrideWithValue(FakeConflictStore({})),
        cardRepositoryProvider.overrideWithValue(cards),
        reviewRepositoryProvider.overrideWithValue(
          FakeReviewRepository(
            counts: {
              'deck-1': (due: 3, learning: 1, newCards: 20),
            },
          ),
        ),
        cardImporterProvider.overrideWithValue(importer),
        pickImportFileProvider.overrideWithValue(() async => picked),
        todayProvider.overrideWithValue(() => DateTime(2026, 11, 23, 9)),
      ],
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('entriesTab_cards')));
  await tester.pumpAndSettle();
  return cards;
}

Future<void> _menu(WidgetTester tester, String deckId, String item) async {
  await tester.tap(find.byKey(Key('deckMenu_$deckId')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key(item)));
  await tester.pumpAndSettle();
}

String? _textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data;

void main() {
  testWidgets('the decks with what is left; a tap studies the deck',
      (tester) async {
    await _pump(tester);
    expect(find.text('Spanish'), findsOneWidget);
    expect(find.text('Biology'), findsOneWidget);
    expect(_textOf(tester, 'deckDue_deck-1'), '3 due');
    expect(_textOf(tester, 'deckLearning_deck-1'), '1 learning');
    expect(_textOf(tester, 'deckNew_deck-1'), '20 new');
    expect(_textOf(tester, 'deckDue_deck-2'), '0 due');
    expect(find.byKey(const Key('deckConflict_deck-2')), findsOneWidget);
    expect(find.byKey(const Key('deckConflict_deck-1')), findsNothing);
    // Without an importer (#1383) there is no Import….
    expect(find.byKey(const Key('decksImport')), findsNothing);

    await tester.tap(find.byKey(const Key('deckTile_deck-1')));
    await tester.pumpAndSettle();
    expect(find.byType(StudyScreen), findsOneWidget);
  });

  testWidgets('New deck and Rename', (tester) async {
    final cards = await _pump(tester);
    await tester.tap(find.byKey(const Key('decksNew')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'French');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.text('French'), findsOneWidget);

    await _menu(tester, 'deck-1', 'deckRename');
    await tester.enterText(find.byType(TextField).last, 'Español');
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(cards.renamed, [('deck-1', 'Español')]);
    expect(find.text('Español'), findsOneWidget);
  });

  testWidgets('Delete names the card count and deletes after confirming',
      (tester) async {
    final cards = await _pump(tester);
    await _menu(tester, 'deck-1', 'deckDelete');
    expect(
      find.text('Delete deck "Spanish" and its 2 cards?'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(cards.deleted, isEmpty);

    await _menu(tester, 'deck-1', 'deckDelete');
    await tester.tap(find.byKey(const Key('deckDeleteConfirm')));
    await tester.pumpAndSettle();
    expect(cards.deleted, ['deck-1']);
    expect(find.text('Spanish'), findsNothing);
  });

  testWidgets('a locked account asks to unlock', (tester) async {
    final cards = await _pump(tester);
    cards.failWith = const NoWriteKeyException('deck-1');
    await _menu(tester, 'deck-1', 'deckDelete');
    await tester.tap(find.byKey(const Key('deckDeleteConfirm')));
    await tester.pumpAndSettle();
    expect(find.text('Unlock personal data to change decks.'), findsOneWidget);
    expect(find.text('Spanish'), findsOneWidget);
  });

  testWidgets('Add card adds to the deck of the menu', (tester) async {
    final cards = await _pump(tester);
    await _menu(tester, 'deck-2', 'deckAddCard');
    await tester.enterText(find.byKey(const Key('newCardFront')), 'Cell');
    await tester.enterText(find.byKey(const Key('newCardBack')), 'Unit');
    await tester.enterText(find.byKey(const Key('newCardTags')), 'bio  a');
    await tester.pump();
    await tester.tap(find.byKey(const Key('newCardSave')));
    await tester.pumpAndSettle();
    final added = cards.added.single;
    expect(added.deckId, 'deck-2');
    expect(added.content.front, 'Cell');
    expect(added.content.back, 'Unit');
    expect(added.content.tags, ['bio', 'a']);
    expect(find.text('Card added'), findsOneWidget);
  });

  testWidgets('Import… shows what the import did', (tester) async {
    final importer = FakeCardImporter(
      result: const ImportResult(
        added: 5,
        updated: 1,
        unchanged: 2,
        skippedCloze: 3,
        missingMedia: 1,
        decks: ['Spanish', 'Verbs'],
      ),
    );
    await _pump(
      tester,
      importer: importer,
      picked: (name: 'deck.apkg', bytes: Uint8List(7)),
    );
    await tester.tap(find.byKey(const Key('decksImport')));
    await tester.pumpAndSettle();
    expect(importer.apkg, [7]);
    expect(find.byKey(const Key('decksImportResult')), findsOneWidget);
    expect(
      find.textContaining('5 added, 1 updated, 2 unchanged'),
      findsOneWidget,
    );
    expect(find.textContaining('3 skipped (cloze)'), findsOneWidget);
    expect(find.textContaining('1 images missing'), findsOneWidget);
    expect(find.textContaining('Decks: Spanish, Verbs'), findsOneWidget);
  });

  testWidgets('a file the importer cannot read shows an error', (tester) async {
    final importer = FakeCardImporter(
      error: const UnsupportedAnkiFormatException('only anki21b'),
    );
    await _pump(
      tester,
      importer: importer,
      picked: (name: 'deck.APKG', bytes: Uint8List(1)),
    );
    await tester.tap(find.byKey(const Key('decksImport')));
    await tester.pumpAndSettle();
    expect(find.text('Cannot import deck.APKG: only anki21b'), findsOneWidget);
    expect(find.byKey(const Key('decksImportResult')), findsNothing);
  });

  testWidgets('a CSV file goes to the CSV import as text', (tester) async {
    final importer = FakeCardImporter();
    await _pump(
      tester,
      importer: importer,
      picked: (name: 'cards.csv', bytes: Uint8List.fromList('a,b'.codeUnits)),
    );
    await tester.tap(find.byKey(const Key('decksImport')));
    await tester.pumpAndSettle();
    expect(importer.csv, ['a,b']);
    expect(importer.apkg, isEmpty);
  });
}
