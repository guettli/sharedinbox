import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/services/encrypted_key_service.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/study_screen.dart';

import 'cards_fakes.dart';
import 'entries_fakes.dart';
import 'helpers.dart';

const _url = '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42';
const _body = 'Pay the invoice by Friday';

/// Opens mail acc-1:42 and its menu.
Future<FakeCardRepository> _openMenu(WidgetTester tester) async {
  final cards = FakeCardRepository(decks: [testDeck('deck-1', 'Work')]);
  await tester.pumpWidget(
    buildApp(
      keyService: FixedStatusKeyService(PersonalDataStatus.unlocked),
      initialLocation: _url,
      userPreferences: FakeUserPreferencesRepository(),
      overrides: [
        accountRepositoryProvider
            .overrideWithValue(FakeAccountRepository([kTestAccount])),
        mailboxRepositoryProvider.overrideWithValue(FakeMailboxRepository()),
        emailRepositoryProvider.overrideWithValue(
          FakeEmailRepository(
            emailDetail: testEmail(subject: 'Invoice'),
            emailBody: const EmailBody(
              emailId: 'acc-1:42',
              textBody: _body,
              attachments: [],
            ),
          ),
        ),
        conversationNotesProvider.overrideWith((ref, key) => Stream.value([])),
        entryRepositoryProvider.overrideWithValue(FakeEntryRepository()),
        mailObjectStoreProvider.overrideWithValue(FakeConflictStore({})),
        cardRepositoryProvider.overrideWithValue(cards),
        reviewRepositoryProvider.overrideWithValue(FakeReviewRepository()),
      ],
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byType(PopupMenuButton<String>));
  await tester.pumpAndSettle();
  return cards;
}

/// Selects [from]..[to] of the select-text dialog's text.
void _select(WidgetTester tester, int from, int to) {
  final editable = tester.state<EditableTextState>(
    find.descendant(
      of: find.byKey(const Key('selectTextBody')),
      matching: find.byType(EditableText),
    ),
  );
  editable.userUpdateTextEditingValue(
    TextEditingValue(
      text: _body,
      selection: TextSelection(baseOffset: from, extentOffset: to),
    ),
    SelectionChangedCause.drag,
  );
}

Future<void> _pickDeck(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('newCardDeck')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Work').last);
  await tester.pumpAndSettle();
}

/// Types [front] and saves the open new-card dialog.
Future<void> _save(WidgetTester tester, String front) async {
  await tester.enterText(find.byKey(const Key('newCardFront')), front);
  // The Add button enables on the next frame.
  await tester.pump();
  await tester.tap(find.byKey(const Key('newCardSave')));
  await tester.pumpAndSettle();
}

String _textOf(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(Key(key))).controller!.text;

void main() {
  testWidgets(
      'Create card: the selection is the back, the front is empty and '
      'focused, saving adds the card', (tester) async {
    final cards = await _openMenu(tester);
    await tester.tap(find.byKey(const Key('emailCreateCard')));
    await tester.pumpAndSettle();
    _select(tester, 8, 15);
    await tester.pump();
    await tester.tap(find.byKey(const Key('selectTextCreateCard')));
    await tester.pumpAndSettle();

    expect(_textOf(tester, 'newCardBack'), 'invoice');
    expect(_textOf(tester, 'newCardFront'), isEmpty);
    final front = tester.state<EditableTextState>(
      find.descendant(
        of: find.byKey(const Key('newCardFront')),
        matching: find.byType(EditableText),
      ),
    );
    expect(front.widget.focusNode.hasFocus, isTrue);

    await _pickDeck(tester);
    await _save(tester, 'Pay what?');
    final added = cards.added.single;
    expect(added.deckId, 'deck-1');
    expect(added.content.front, 'Pay what?');
    expect(added.content.back, 'invoice');
    expect(find.text('Card added'), findsOneWidget);

    await tester.tap(find.text('Study'));
    await tester.pumpAndSettle();
    expect(find.byType(StudyScreen), findsOneWidget);
  });

  testWidgets(
      'without a selection the whole text is the back; the deck is '
      'remembered', (tester) async {
    final cards = await _openMenu(tester);
    await tester.tap(find.text('Select text'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('selectTextCreateCard')));
    await tester.pumpAndSettle();
    expect(_textOf(tester, 'newCardBack'), _body);
    await _pickDeck(tester);
    await _save(tester, 'Q');
    expect(cards.added.single.content.back, _body);

    // The next card goes to the same deck without picking it.
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('emailCreateCard')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('selectTextCreateCard')));
    await tester.pumpAndSettle();
    await _save(tester, 'Q2');
    expect(cards.added.map((c) => c.deckId), ['deck-1', 'deck-1']);
  });
}
