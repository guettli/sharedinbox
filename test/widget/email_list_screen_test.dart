import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/di.dart';

import 'helpers.dart';

void main() {
  group('EmailListScreen', () {
    testWidgets('shows "No emails" when list is empty', (tester) async {
      await tester.pumpWidget(buildApp(
        initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
        overrides: [
          accountRepositoryProvider
              .overrideWithValue(FakeAccountRepository([kTestAccount])),
          mailboxRepositoryProvider
              .overrideWithValue(FakeMailboxRepository()),
          emailRepositoryProvider
              .overrideWithValue(FakeEmailRepository()),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.text('No emails'), findsOneWidget);
    });

    testWidgets('shows email sender and subject', (tester) async {
      final email = testEmail(subject: 'Meeting agenda');
      await tester.pumpWidget(buildApp(
        initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
        overrides: [
          accountRepositoryProvider
              .overrideWithValue(FakeAccountRepository([kTestAccount])),
          mailboxRepositoryProvider
              .overrideWithValue(FakeMailboxRepository()),
          emailRepositoryProvider
              .overrideWithValue(FakeEmailRepository(emails: [email])),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.text('Bob'), findsOneWidget);
      expect(find.text('Meeting agenda'), findsOneWidget);
    });

    testWidgets('shows flag icon for flagged email', (tester) async {
      final email = testEmail(isFlagged: true);
      await tester.pumpWidget(buildApp(
        initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
        overrides: [
          accountRepositoryProvider
              .overrideWithValue(FakeAccountRepository([kTestAccount])),
          mailboxRepositoryProvider
              .overrideWithValue(FakeMailboxRepository()),
          emailRepositoryProvider
              .overrideWithValue(FakeEmailRepository(emails: [email])),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.star), findsOneWidget);
    });

    testWidgets('tapping search icon shows search bar', (tester) async {
      await tester.pumpWidget(buildApp(
        initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
        overrides: [
          accountRepositoryProvider
              .overrideWithValue(FakeAccountRepository([kTestAccount])),
          mailboxRepositoryProvider
              .overrideWithValue(FakeMailboxRepository()),
          emailRepositoryProvider
              .overrideWithValue(FakeEmailRepository()),
        ],
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Search…'), findsOneWidget);
    });

    testWidgets('tapping back arrow in search bar closes it', (tester) async {
      await tester.pumpWidget(buildApp(
        initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
        overrides: [
          accountRepositoryProvider
              .overrideWithValue(FakeAccountRepository([kTestAccount])),
          mailboxRepositoryProvider
              .overrideWithValue(FakeMailboxRepository()),
          emailRepositoryProvider
              .overrideWithValue(FakeEmailRepository()),
        ],
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(find.text('Search…'), findsNothing);
      expect(find.text('INBOX'), findsOneWidget);
    });
  });
}
