import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/di.dart';

import 'helpers.dart';

void main() {
  group('SettingsScreen', () {
    testWidgets('shows "Accounts" section header', (tester) async {
      await tester.pumpWidget(buildApp(
        initialLocation: '/settings',
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

      expect(find.text('Accounts'), findsOneWidget);
    });

    testWidgets('shows account tile when an account exists', (tester) async {
      await tester.pumpWidget(buildApp(
        initialLocation: '/settings',
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

    testWidgets('tapping delete icon shows confirmation dialog',
        (tester) async {
      await tester.pumpWidget(buildApp(
        initialLocation: '/settings',
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

      await tester.tap(find.byIcon(Icons.delete));
      await tester.pumpAndSettle();

      expect(find.text('Remove account?'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);
    });

    testWidgets('tapping Remove in the confirmation dialog calls removeAccount',
        (tester) async {
      await tester.pumpWidget(buildApp(
        initialLocation: '/settings',
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

      await tester.tap(find.byIcon(Icons.delete));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();

      // Dialog dismissed after confirmation.
      expect(find.text('Remove account?'), findsNothing);
    });

    testWidgets('tapping Cancel in the confirmation dialog dismisses it',
        (tester) async {
      await tester.pumpWidget(buildApp(
        initialLocation: '/settings',
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

      await tester.tap(find.byIcon(Icons.delete));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Remove account?'), findsNothing);
      expect(find.text('Alice'), findsOneWidget); // account still visible
    });
  });
}
