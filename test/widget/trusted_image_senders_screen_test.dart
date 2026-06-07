import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('TrustedImageSendersScreen', () {
    testWidgets('shows empty state with glob hint when no senders', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/trusted-senders',
          overrides: baseOverrides(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('*@example.com'), findsOneWidget);
      expect(find.byIcon(Icons.add), findsOneWidget);
    });

    testWidgets('lists existing senders', (tester) async {
      final repo = FakeUserPreferencesRepository(
        trustedImageSenders: ['alice@example.com', '*@work.com'],
      );
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/trusted-senders',
          overrides: baseOverrides(),
          userPreferences: repo,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('alice@example.com'), findsOneWidget);
      expect(find.text('*@work.com'), findsOneWidget);
    });

    testWidgets('add dialog shows glob hint text', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/trusted-senders',
          overrides: baseOverrides(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      expect(find.text('Add allowed address'), findsOneWidget);
      expect(find.textContaining('*@example.com'), findsWidgets);
      expect(find.textContaining('* matches any characters'), findsOneWidget);
    });

    testWidgets('Add button is disabled when input is empty', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/trusted-senders',
          overrides: baseOverrides(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      final addButton = find.widgetWithText(TextButton, 'Add');
      final button = tester.widget<TextButton>(addButton);
      expect(button.onPressed, isNull);
    });

    testWidgets('typing in dialog enables Add button and adds sender', (
      tester,
    ) async {
      final repo = FakeUserPreferencesRepository();
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/trusted-senders',
          overrides: baseOverrides(),
          userPreferences: repo,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '*@example.com');
      await tester.pumpAndSettle();

      final addButton = find.widgetWithText(TextButton, 'Add');
      final button = tester.widget<TextButton>(addButton);
      expect(button.onPressed, isNotNull);

      await tester.tap(addButton);
      await tester.pumpAndSettle();

      expect(repo.trustedImageSendersForTest, contains('*@example.com'));
    });

    testWidgets('cancel closes dialog without adding', (tester) async {
      final repo = FakeUserPreferencesRepository();
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/trusted-senders',
          overrides: baseOverrides(),
          userPreferences: repo,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'someone@test.com');
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(repo.trustedImageSendersForTest, isEmpty);
    });

    testWidgets('delete button removes a sender', (tester) async {
      final repo = FakeUserPreferencesRepository(
        trustedImageSenders: ['alice@example.com'],
      );
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/trusted-senders',
          overrides: baseOverrides(),
          userPreferences: repo,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();

      expect(repo.trustedImageSendersForTest, isEmpty);
    });

    testWidgets('lists existing glob patterns', (tester) async {
      final repo = FakeUserPreferencesRepository(
        trustedImageSenders: ['*@example.com', 'alice@other.com'],
      );
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/trusted-senders',
          overrides: baseOverrides(),
          userPreferences: repo,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('*@example.com'), findsOneWidget);
      expect(find.text('alice@other.com'), findsOneWidget);
    });
  });
}
