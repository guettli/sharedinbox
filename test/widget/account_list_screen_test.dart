import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/data/db/database.dart' show SyncHealthRow;

import 'helpers.dart';

void main() {
  group('AccountListScreen', () {
    testWidgets('shows onboarding walkthrough when repository is empty', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(initialLocation: '/accounts', overrides: baseOverrides()),
      );
      await tester.pumpAndSettle();

      expect(find.text('Welcome to sharedinbox.de'), findsOneWidget);
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

      expect(find.text('sharedinbox.de'), findsOneWidget);
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

    testWidgets('account popup menu contains Send accounts item', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts',
          overrides: baseOverrides(accounts: [kTestAccount]),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      expect(find.text('Send accounts'), findsOneWidget);
    });

    testWidgets('account popup menu contains Force full sync item', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts',
          overrides: baseOverrides(accounts: [kTestAccount]),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      expect(find.text('Force full sync'), findsOneWidget);
    });

    testWidgets(
      'Force full sync appears below Verify sync health in popup menu',
      (tester) async {
        await tester.pumpWidget(
          buildApp(
            initialLocation: '/accounts',
            overrides: baseOverrides(accounts: [kTestAccount]),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byIcon(Icons.more_vert));
        await tester.pumpAndSettle();

        final verifyPos = tester.getTopLeft(find.text('Verify sync health')).dy;
        final forcePos = tester.getTopLeft(find.text('Force full sync')).dy;
        expect(forcePos, greaterThan(verifyPos));
      },
    );

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
      expect(find.text('sharedinbox.de'), findsOneWidget);
    });

    testWidgets('shows Healthy when sync health is healthy', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts',
          overrides: baseOverrides(
            accounts: [kTestAccount],
            syncHealth: SyncHealthRow(
              accountId: kTestAccount.id,
              lastVerifiedAt: DateTime(2024, 6),
              isHealthy: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Healthy'), findsOneWidget);
    });

    testWidgets('shows discrepancy details when sync health has discrepancies',
        (
      tester,
    ) async {
      const summary =
          '{"INBOX":{"missingLocally":3,"missingOnServer":0,"flagMismatches":1}}';
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts',
          overrides: baseOverrides(
            accounts: [kTestAccount],
            syncHealth: SyncHealthRow(
              accountId: kTestAccount.id,
              lastVerifiedAt: DateTime(2024, 6),
              isHealthy: false,
              discrepancySummary: summary,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('missing locally: 3'), findsOneWidget);
      expect(find.textContaining('flag mismatches: 1'), findsOneWidget);
    });

    testWidgets('shows failure reason when the sync health check failed', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts',
          overrides: baseOverrides(
            accounts: [kTestAccount],
            syncHealth: SyncHealthRow(
              accountId: kTestAccount.id,
              lastVerifiedAt: DateTime(2024, 6),
              isHealthy: false,
              lastError: 'JMAP connect failed',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Sync check failed'), findsOneWidget);
      expect(find.textContaining('JMAP connect failed'), findsOneWidget);
    });

    testWidgets('shows verifying indicator while a check is in progress', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts',
          overrides: baseOverrides(
            accounts: [kTestAccount],
            verifying: {kTestAccount.id},
          ),
        ),
      );
      // Not pumpAndSettle: the in-progress row shows an indeterminate
      // CircularProgressIndicator that never stops animating. Pump a few frames
      // so the account and stream providers deliver their initial values.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(find.textContaining('verifying'), findsOneWidget);
    });

    testWidgets('sync health row is positioned below the account name row', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts',
          overrides: baseOverrides(
            accounts: [kTestAccount],
            syncHealth: SyncHealthRow(
              accountId: kTestAccount.id,
              lastVerifiedAt: DateTime(2024, 6),
              isHealthy: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final namePos = tester.getTopLeft(find.text('Alice')).dy;
      final healthPos = tester.getTopLeft(find.textContaining('Healthy')).dy;
      expect(healthPos, greaterThan(namePos));
    });
  });
}
