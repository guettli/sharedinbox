import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('AccountListScreen', () {
    testWidgets('shows "No accounts yet." when repository is empty', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(initialLocation: '/accounts', overrides: baseOverrides()),
      );
      await tester.pumpAndSettle();

      expect(find.text('No accounts yet.'), findsOneWidget);
      expect(find.text('Add account'), findsOneWidget);
    });

    testWidgets('shows account tile when repository has an account', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts',
          overrides: baseOverrides(accounts: [kTestAccount]),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Alice'), findsOneWidget);
      // Email and type label are now a single Text widget ('email\ntype').
      expect(find.textContaining('alice@example.com'), findsOneWidget);
      expect(find.textContaining('IMAP'), findsOneWidget);
    });

    testWidgets('shows IMAP type label for IMAP account', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts',
          overrides: baseOverrides(accounts: [kTestAccount]),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('IMAP'), findsOneWidget);
    });

    testWidgets('shows check icon after successful connection test', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts',
          overrides: baseOverrides(accounts: [kTestAccount]),
        ),
      );

      // Before settling: connection test is in-flight → spinner visible.
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // After settling: connection succeeded → check icon visible.
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });

    testWidgets('shows error icon when connection test fails', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts',
          overrides: baseOverrides(
            accounts: [kTestAccount],
            connectionError: Exception('auth failed'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });

    testWidgets('app bar shows "SharedInbox" title', (tester) async {
      await tester.pumpWidget(
        buildApp(initialLocation: '/accounts', overrides: baseOverrides()),
      );
      await tester.pumpAndSettle();

      expect(find.text('SharedInbox'), findsOneWidget);
    });

    testWidgets(
      '"Add account" button in empty state navigates to add-account screen',
      (tester) async {
        await tester.pumpWidget(
          buildApp(initialLocation: '/accounts', overrides: baseOverrides()),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Add account'));
        await tester.pumpAndSettle();

        expect(find.text('Email address'), findsOneWidget);
      },
    );

    testWidgets('tapping an account tile navigates to its mailboxes', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts',
          overrides: baseOverrides(
            accounts: [kTestAccount],
            mailboxes: [kTestMailbox],
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Alice'));
      await tester.pumpAndSettle();

      expect(find.text('INBOX'), findsWidgets);
    });

    testWidgets('tapping FAB navigates to add-account screen', (tester) async {
      await tester.pumpWidget(
        buildApp(initialLocation: '/accounts', overrides: baseOverrides()),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.text('Add account'), findsOneWidget);
    });

    testWidgets('AppBar does not overflow at minimum supported window size', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        buildApp(initialLocation: '/accounts', overrides: baseOverrides()),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('SharedInbox'), findsOneWidget);
    });
  });
}
