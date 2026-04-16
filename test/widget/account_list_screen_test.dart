import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/di.dart';

import 'helpers.dart';

void main() {
  group('AccountListScreen', () {
    testWidgets('shows "No accounts yet." when repository is empty',
        (tester) async {
      await tester.pumpWidget(buildApp(
        initialLocation: '/accounts',
        overrides: [
          accountRepositoryProvider
              .overrideWithValue(FakeAccountRepository()),
          mailboxRepositoryProvider
              .overrideWithValue(FakeMailboxRepository()),
          emailRepositoryProvider
              .overrideWithValue(FakeEmailRepository()),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.text('No accounts yet.'), findsOneWidget);
      expect(find.text('Add account'), findsOneWidget);
    });

    testWidgets('shows account tile when repository has an account',
        (tester) async {
      await tester.pumpWidget(buildApp(
        initialLocation: '/accounts',
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

      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('alice@example.com'), findsOneWidget);
    });

    testWidgets('app bar shows "SharedInbox" title', (tester) async {
      await tester.pumpWidget(buildApp(
        initialLocation: '/accounts',
        overrides: [
          accountRepositoryProvider
              .overrideWithValue(FakeAccountRepository()),
          mailboxRepositoryProvider
              .overrideWithValue(FakeMailboxRepository()),
          emailRepositoryProvider
              .overrideWithValue(FakeEmailRepository()),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.text('SharedInbox'), findsOneWidget);
    });

    testWidgets('tapping settings icon navigates to /settings',
        (tester) async {
      await tester.pumpWidget(buildApp(
        initialLocation: '/accounts',
        overrides: [
          accountRepositoryProvider
              .overrideWithValue(FakeAccountRepository()),
          mailboxRepositoryProvider
              .overrideWithValue(FakeMailboxRepository()),
          emailRepositoryProvider
              .overrideWithValue(FakeEmailRepository()),
        ],
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.settings));
      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsOneWidget);
    });

    testWidgets('tapping FAB navigates to add-account screen', (tester) async {
      await tester.pumpWidget(buildApp(
        initialLocation: '/accounts',
        overrides: [
          accountRepositoryProvider
              .overrideWithValue(FakeAccountRepository()),
          mailboxRepositoryProvider
              .overrideWithValue(FakeMailboxRepository()),
          emailRepositoryProvider
              .overrideWithValue(FakeEmailRepository()),
        ],
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.text('Add account'), findsOneWidget);
    });
  });
}
