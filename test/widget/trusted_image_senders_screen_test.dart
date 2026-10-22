import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

Future<FakeUserPreferencesRepository> _pumpScreen(
  WidgetTester tester, {
  List<String> trustedImageSenders = const [],
}) async {
  final repo = FakeUserPreferencesRepository(
    trustedImageSenders: [...trustedImageSenders],
  );
  await tester.pumpWidget(
    buildApp(
      initialLocation: '/accounts/trusted-senders',
      overrides: baseOverrides(),
      userPreferences: repo,
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

/// Opens the add dialog and, when given, types [text] into it.
Future<void> _openAddDialog(WidgetTester tester, [String? text]) async {
  await tester.tap(find.byIcon(Icons.add));
  await tester.pumpAndSettle();
  if (text != null) {
    await tester.enterText(find.byType(TextField), text);
    await tester.pumpAndSettle();
  }
}

TextButton _addButton(WidgetTester tester) =>
    tester.widget<TextButton>(find.widgetWithText(TextButton, 'Add'));

void main() {
  group('TrustedImageSendersScreen', () {
    testWidgets('shows empty state with glob hint when no senders', (
      tester,
    ) async {
      await _pumpScreen(tester);

      expect(find.textContaining('*@example.com'), findsOneWidget);
      expect(find.byIcon(Icons.add), findsOneWidget);
    });

    testWidgets('lists existing senders and glob patterns', (tester) async {
      await _pumpScreen(
        tester,
        trustedImageSenders: ['alice@example.com', '*@work.com'],
      );

      expect(find.text('alice@example.com'), findsOneWidget);
      expect(find.text('*@work.com'), findsOneWidget);
    });

    testWidgets('add dialog shows glob hint text', (tester) async {
      await _pumpScreen(tester);
      await _openAddDialog(tester);

      expect(find.text('Add allowed address'), findsOneWidget);
      expect(find.textContaining('*@example.com'), findsWidgets);
      expect(find.textContaining('* matches any characters'), findsOneWidget);
    });

    testWidgets('Add button is disabled when input is empty', (tester) async {
      await _pumpScreen(tester);
      await _openAddDialog(tester);

      expect(_addButton(tester).onPressed, isNull);
    });

    testWidgets('typing in dialog enables Add button and adds sender', (
      tester,
    ) async {
      final repo = await _pumpScreen(tester);
      await _openAddDialog(tester, '*@example.com');

      expect(_addButton(tester).onPressed, isNotNull);

      await tester.tap(find.widgetWithText(TextButton, 'Add'));
      await tester.pumpAndSettle();

      expect(repo.trustedImageSendersForTest, contains('*@example.com'));
    });

    testWidgets('cancel closes dialog without adding', (tester) async {
      final repo = await _pumpScreen(tester);
      await _openAddDialog(tester, 'someone@test.com');

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(repo.trustedImageSendersForTest, isEmpty);
    });

    testWidgets('delete button removes a sender', (tester) async {
      final repo = await _pumpScreen(
        tester,
        trustedImageSenders: ['alice@example.com'],
      );

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();

      expect(repo.trustedImageSendersForTest, isEmpty);
    });

    testWidgets('a pasted "Name <address>" is added as the bare address', (
      tester,
    ) async {
      final repo = await _pumpScreen(tester);
      await _openAddDialog(tester, 'Bob Smith <bob@example.org>');

      await tester.tap(find.widgetWithText(TextButton, 'Add'));
      await tester.pumpAndSettle();

      // Stored verbatim it never matched the sender's bare address.
      expect(repo.trustedImageSendersForTest, ['bob@example.org']);
    });

    testWidgets('an entry that can never match is refused inline', (
      tester,
    ) async {
      final repo = await _pumpScreen(tester);
      await _openAddDialog(tester, 'foo');

      expect(
        find.text('Not an email address or pattern like *@example.com'),
        findsOneWidget,
      );
      expect(_addButton(tester).onPressed, isNull);

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(repo.trustedImageSendersForTest, isEmpty);
    });
  });
}
