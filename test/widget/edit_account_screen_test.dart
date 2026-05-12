import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('EditAccountScreen', () {
    testWidgets('shows account email and type label after loading', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/edit',
          overrides: baseOverrides(accounts: [kTestAccount]),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('alice@example.com'), findsOneWidget);
      // "IMAP" appears as both the type badge and the IMAP section header.
      expect(find.text('IMAP'), findsWidgets);
    });

    testWidgets('pre-fills display name field', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/edit',
          overrides: baseOverrides(accounts: [kTestAccount]),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextFormField, 'Alice'), findsOneWidget);
    });

    testWidgets('shows Save button', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/edit',
          overrides: baseOverrides(accounts: [kTestAccount]),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Save'), findsOneWidget);
    });

    testWidgets('saving without password change pops back', (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/edit',
          overrides: baseOverrides(accounts: [kTestAccount]),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // After saving we pop back to the accounts list.
      expect(find.text('No accounts yet.'), findsNothing);
    });

    testWidgets('saving with new password runs connection test', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/edit',
          overrides: baseOverrides(accounts: [kTestAccount]),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('editPasswordField')),
        'newsecret',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // Successful save navigates back — edit screen title is gone.
      expect(find.text('Edit account'), findsNothing);
    });

    testWidgets('connection error shows error message', (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/edit',
          overrides: baseOverrides(
            accounts: [kTestAccount],
            connectionError: Exception('auth failed'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('editPasswordField')),
        'wrongpassword',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Save failed'), findsOneWidget);
    });
  });
}
