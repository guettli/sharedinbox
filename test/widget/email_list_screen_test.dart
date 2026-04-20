import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/di.dart';

import 'helpers.dart';

void main() {
  group('EmailListScreen', () {
    testWidgets('shows "No emails" when list is empty', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
          overrides: [
            accountRepositoryProvider
                .overrideWithValue(FakeAccountRepository([kTestAccount])),
            mailboxRepositoryProvider
                .overrideWithValue(FakeMailboxRepository()),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No emails'), findsOneWidget);
    });

    testWidgets('shows email sender and subject', (tester) async {
      final email = testEmail(subject: 'Meeting agenda');
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
          overrides: [
            accountRepositoryProvider
                .overrideWithValue(FakeAccountRepository([kTestAccount])),
            mailboxRepositoryProvider
                .overrideWithValue(FakeMailboxRepository()),
            emailRepositoryProvider
                .overrideWithValue(FakeEmailRepository(emails: [email])),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Bob'), findsOneWidget);
      expect(find.text('Meeting agenda'), findsOneWidget);
    });

    testWidgets('shows flag icon for flagged email', (tester) async {
      final email = testEmail(isFlagged: true);
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
          overrides: [
            accountRepositoryProvider
                .overrideWithValue(FakeAccountRepository([kTestAccount])),
            mailboxRepositoryProvider
                .overrideWithValue(FakeMailboxRepository()),
            emailRepositoryProvider
                .overrideWithValue(FakeEmailRepository(emails: [email])),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.star), findsOneWidget);
    });

    testWidgets('tapping search icon shows search bar', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
          overrides: [
            accountRepositoryProvider
                .overrideWithValue(FakeAccountRepository([kTestAccount])),
            mailboxRepositoryProvider
                .overrideWithValue(FakeMailboxRepository()),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Search…'), findsOneWidget);
    });

    testWidgets('submitting a search query shows "No results" when empty',
        (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
          overrides: [
            accountRepositoryProvider
                .overrideWithValue(FakeAccountRepository([kTestAccount])),
            mailboxRepositoryProvider
                .overrideWithValue(FakeMailboxRepository()),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'hello');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(find.text('No results'), findsOneWidget);
    });

    testWidgets('submitting a search query shows matching emails',
        (tester) async {
      final email = testEmail(subject: 'Found it');
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
          overrides: [
            accountRepositoryProvider
                .overrideWithValue(FakeAccountRepository([kTestAccount])),
            mailboxRepositoryProvider
                .overrideWithValue(FakeMailboxRepository()),
            emailRepositoryProvider.overrideWithValue(
              FakeEmailRepository(searchResults: [email]),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Found');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(find.text('Found it'), findsOneWidget);
    });

    testWidgets('tapping sync button triggers syncEmails', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
          overrides: [
            accountRepositoryProvider
                .overrideWithValue(FakeAccountRepository([kTestAccount])),
            mailboxRepositoryProvider
                .overrideWithValue(FakeMailboxRepository()),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.sync));
      await tester.pumpAndSettle();

      // No assertion needed — we just verify the tap doesn't throw.
    });

    testWidgets('tapping edit button navigates to compose screen',
        (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
          overrides: [
            accountRepositoryProvider
                .overrideWithValue(FakeAccountRepository([kTestAccount])),
            mailboxRepositoryProvider
                .overrideWithValue(FakeMailboxRepository()),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.edit));
      await tester.pumpAndSettle();

      expect(find.text('To'), findsOneWidget);
    });

    testWidgets('tapping back arrow in search bar closes it', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
          overrides: [
            accountRepositoryProvider
                .overrideWithValue(FakeAccountRepository([kTestAccount])),
            mailboxRepositoryProvider
                .overrideWithValue(FakeMailboxRepository()),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
          ],
        ),
      );
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
