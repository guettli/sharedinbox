import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/flashcards/fsrs.dart';
import 'package:sharedinbox/core/models/card.dart' show FlashCard;
import 'package:sharedinbox/core/services/encrypted_key_service.dart';
import 'package:sharedinbox/di.dart';

import 'cards_fakes.dart';
import 'entries_fakes.dart';
import 'helpers.dart';

final _now = DateTime(2026, 11, 23, 9);

CardSchedule _schedule(CardState state, Duration fromNow) => CardSchedule(
      state: state,
      step: state == CardState.review ? null : 0,
      stability: 3,
      difficulty: 5,
      dueMs: _now.add(fromNow).millisecondsSinceEpoch,
      lastReviewMs:
          _now.subtract(const Duration(days: 3)).millisecondsSinceEpoch,
      reps: 2,
      lapses: 0,
    );

final _cards = [
  testCard('r1', 'deck-1', 'Gato', 'Cat'),
  testCard('n1', 'deck-1', 'Hola', 'Hello'),
  testCard('n2', 'deck-1', 'Adiós', 'Bye'),
];

/// Opens the study screen of deck-1 at 09:00: r1 is a review due an hour
/// ago, n1 and n2 are new unless [due] and [newIds] say otherwise.
Future<FakeReviewRepository> _pump(
  WidgetTester tester, {
  List<(String, CardSchedule)>? due,
  List<String> newIds = const ['n1', 'n2'],
  int newLeft = 20,
  List<FlashCard>? cards,
}) async {
  final reviews = FakeReviewRepository(
    due:
        due ?? [('r1', _schedule(CardState.review, const Duration(hours: -1)))],
    newIds: newIds,
    newLeft: newLeft,
  );
  await tester.pumpWidget(
    buildApp(
      initialLocation: '/accounts/acc-1/decks/deck-1/study',
      userPreferences: FakeUserPreferencesRepository(personalDataBeta: true),
      overrides: [
        ...baseOverrides(),
        encryptedKeyServiceProvider.overrideWithValue(
          FixedStatusKeyService(PersonalDataStatus.unlocked),
        ),
        cardRepositoryProvider.overrideWithValue(
          FakeCardRepository(
            decks: [testDeck('deck-1', 'Spanish')],
            cards: cards ?? _cards,
          ),
        ),
        reviewRepositoryProvider.overrideWithValue(reviews),
        todayProvider.overrideWithValue(() => _now),
      ],
    ),
  );
  await tester.pumpAndSettle();
  return reviews;
}

Finder _text(String text) => find.textContaining(text, findRichText: true);

IconButton _undoButton(WidgetTester tester) =>
    tester.widget<IconButton>(find.byKey(const Key('studyUndo')));

void main() {
  testWidgets('a deck without cards says so and offers Add card',
      (tester) async {
    await _pump(tester, due: const [], newIds: const [], cards: const []);
    expect(find.byKey(const Key('studyEmpty')), findsOneWidget);
    expect(find.byKey(const Key('studyDone')), findsNothing);
    await tester.tap(find.byKey(const Key('studyAddCard')));
    await tester.pumpAndSettle();
    expect(find.text('New card'), findsOneWidget);
  });

  testWidgets('the front first; Show answer reveals the back and 4 ratings',
      (tester) async {
    await _pump(tester);
    expect(find.text('Spanish'), findsOneWidget);
    expect(find.text('2 new · 0 learning · 1 due'), findsOneWidget);
    expect(_text('Gato'), findsWidgets);
    expect(_text('Cat'), findsNothing);
    for (final r in ['again', 'hard', 'good', 'easy']) {
      expect(find.byKey(Key('studyRate_$r')), findsNothing);
    }

    await tester.tap(find.byKey(const Key('studyReveal')));
    await tester.pumpAndSettle();
    expect(_text('Cat'), findsWidgets);
    expect(find.byKey(const Key('studyReveal')), findsNothing);
    for (final r in ['again', 'hard', 'good', 'easy']) {
      expect(find.byKey(Key('studyRate_$r')), findsOneWidget);
    }
    // A review lapse relearns in 10 min; the others are days.
    expect(
      tester.widget<Text>(find.byKey(const Key('studyInterval_again'))).data,
      '10m',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('studyInterval_easy'))).data,
      endsWith('d'),
    );
  });

  testWidgets('Good rates the card and the next one shows in the next frame',
      (tester) async {
    final reviews = await _pump(tester);
    await tester.tap(find.byKey(const Key('studyReveal')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('studyRate_good')));
    await tester.pump();

    expect(_text('Hola'), findsWidgets);
    expect(_text('Gato'), findsNothing);
    expect(find.byKey(const Key('studyReveal')), findsOneWidget);
    expect(reviews.rated.single.cardId, 'r1');
    expect(reviews.rated.single.rating, Rating.good);
    await tester.pumpAndSettle();
    expect(find.text('2 new · 0 learning · 0 due'), findsOneWidget);
  });

  testWidgets('undo cancels the last rating and shows its card front first',
      (tester) async {
    final reviews = await _pump(tester);
    expect(_undoButton(tester).onPressed, isNull);

    await tester.tap(find.byKey(const Key('studyReveal')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('studyRate_good')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('studyReveal')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('studyRate_easy')));
    await tester.pumpAndSettle();
    expect(_text('Adiós'), findsWidgets);
    expect(reviews.rated.map((r) => r.cardId), ['r1', 'n1']);
    expect(_undoButton(tester).onPressed, isNotNull);

    await tester.tap(find.byKey(const Key('studyUndo')));
    await tester.pumpAndSettle();
    expect(reviews.undone, [('dev', 2)]);
    expect(_text('Hola'), findsWidgets);
    expect(_text('Hello'), findsNothing);
    expect(find.byKey(const Key('studyReveal')), findsOneWidget);

    await tester.tap(find.byKey(const Key('studyUndo')));
    await tester.pumpAndSettle();
    expect(reviews.undone, [('dev', 2), ('dev', 1)]);
    expect(_text('Gato'), findsWidgets);
    expect(_undoButton(tester).onPressed, isNull);
  });

  testWidgets('keys: Space reveals, 1–4 rate, U undoes', (tester) async {
    final reviews = await _pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await tester.pumpAndSettle();
    expect(reviews.rated, isEmpty, reason: 'no rating before the answer');

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(_text('Cat'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit4);
    await tester.pumpAndSettle();
    expect(reviews.rated.single.rating, Rating.easy);
    expect(_text('Hola'), findsWidgets);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyU);
    await tester.pumpAndSettle();
    expect(reviews.undone, [('dev', 1)]);
    expect(_text('Gato'), findsWidgets);
  });

  testWidgets('newPerDay: only what is left of the day of new cards',
      (tester) async {
    await _pump(tester, due: const [], newLeft: 1);
    expect(find.text('1 new · 0 learning · 0 due'), findsOneWidget);
    await tester.tap(find.byKey(const Key('studyReveal')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('studyRate_easy')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('studyDone')), findsOneWidget);
    expect(_text('Adiós'), findsNothing);
  });

  testWidgets('nothing left: All done, with the next learning card',
      (tester) async {
    await _pump(
      tester,
      due: [
        ('r1', _schedule(CardState.learning, const Duration(minutes: 30))),
      ],
      newIds: const [],
    );
    expect(find.text('All done for now'), findsOneWidget);
    expect(find.text('Next learning card at 09:30'), findsOneWidget);
  });

  testWidgets('a learning card due within 20 minutes is shown early',
      (tester) async {
    await _pump(
      tester,
      due: [
        ('r1', _schedule(CardState.learning, const Duration(minutes: 15))),
      ],
      newIds: const [],
    );
    expect(find.text('0 new · 1 learning · 0 due'), findsOneWidget);
    expect(_text('Gato'), findsWidgets);
  });

  testWidgets('a rating that cannot be saved puts the card back',
      (tester) async {
    final reviews = await _pump(tester);
    reviews.failRateWith = Exception('disk full');
    await tester.tap(find.byKey(const Key('studyReveal')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('studyRate_good')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not save the rating'), findsOneWidget);
    expect(_text('Gato'), findsWidgets);
    expect(_undoButton(tester).onPressed, isNull);
  });

  testWidgets('leaving the screen ends the session', (tester) async {
    final reviews = await _pump(tester);
    expect(reviews.sessionsEnded, isEmpty);
    await tester.pumpWidget(const SizedBox());
    expect(reviews.sessionsEnded, ['acc-1']);
  });
}
