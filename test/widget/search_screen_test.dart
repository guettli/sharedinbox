import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/di.dart';

import 'helpers.dart';

void main() {
  group('SearchScreen', () {
    testWidgets('shows placeholder hint text when empty', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/search',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
            searchHistoryRepositoryProvider.overrideWithValue(
              FakeSearchHistoryRepository(),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Type 3+ characters to search'), findsOneWidget);
    });

    testWidgets('typing fewer than 3 characters does not trigger search', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/search',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
            searchHistoryRepositoryProvider.overrideWithValue(
              FakeSearchHistoryRepository(),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'hi');
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Type 3+ characters to search'), findsOneWidget);
      expect(find.text('No results'), findsNothing);
    });

    testWidgets('shows "No results" when search returns nothing', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/search',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
            searchHistoryRepositoryProvider.overrideWithValue(
              FakeSearchHistoryRepository(),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'xyz');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.text('No results'), findsOneWidget);
    });

    testWidgets('shows email results under "Messages" section', (
      tester,
    ) async {
      final email = testEmail(subject: 'Invoice Q3');
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/search',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
            emailRepositoryProvider.overrideWithValue(
              FakeEmailRepository(searchResults: [email]),
            ),
            searchHistoryRepositoryProvider.overrideWithValue(
              FakeSearchHistoryRepository(),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'inv');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.text('Messages'), findsOneWidget);
      expect(find.text('Invoice Q3'), findsOneWidget);
    });

    testWidgets('shows folder results under "Folders" section', (
      tester,
    ) async {
      const archiveMailbox = Mailbox(
        id: 'acc-1:Archive',
        accountId: 'acc-1',
        path: 'Archive',
        name: 'Archive',
        unreadCount: 0,
        totalCount: 5,
      );
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/search',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository([archiveMailbox]),
            ),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
            searchHistoryRepositoryProvider.overrideWithValue(
              FakeSearchHistoryRepository(),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'arc');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.text('Folders'), findsOneWidget);
      expect(find.text('Archive'), findsOneWidget);
    });

    testWidgets('folder with query as word prefix is matched', (tester) async {
      const foobarMailbox = Mailbox(
        id: 'acc-1:Foobar',
        accountId: 'acc-1',
        path: 'Foobar',
        name: 'Foobar',
        unreadCount: 0,
        totalCount: 0,
      );
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/search',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository([foobarMailbox]),
            ),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
            searchHistoryRepositoryProvider.overrideWithValue(
              FakeSearchHistoryRepository(),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'foo');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.text('Folders'), findsOneWidget);
      expect(find.text('Foobar'), findsOneWidget);
    });

    testWidgets('folder whose name ends with query is not matched', (
      tester,
    ) async {
      const blafooMailbox = Mailbox(
        id: 'acc-1:Blafoo',
        accountId: 'acc-1',
        path: 'Blafoo',
        name: 'Blafoo',
        unreadCount: 0,
        totalCount: 0,
      );
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/search',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository([blafooMailbox]),
            ),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
            searchHistoryRepositoryProvider.overrideWithValue(
              FakeSearchHistoryRepository(),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'foo');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.text('Blafoo'), findsNothing);
      expect(find.text('No results'), findsOneWidget);
    });

    testWidgets('tapping clear button resets results to placeholder', (
      tester,
    ) async {
      final email = testEmail(subject: 'Found email');
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/search',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
            emailRepositoryProvider.overrideWithValue(
              FakeEmailRepository(searchResults: [email]),
            ),
            searchHistoryRepositoryProvider.overrideWithValue(
              FakeSearchHistoryRepository(),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'found');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Found email'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.clear));
      await tester.pumpAndSettle();

      // Results are gone; the recent-search chip for the prior query appears.
      expect(find.text('Found email'), findsNothing);
      expect(find.text('found'), findsOneWidget);
    });
  });
}
