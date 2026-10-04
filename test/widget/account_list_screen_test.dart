import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/models/pending_change.dart';
import 'package:sharedinbox/data/db/database.dart' show SyncHealthRow;

import 'helpers.dart';

PendingChange _pendingChange({int id = 1}) => PendingChange(
      id: id,
      accountId: kTestAccount.id,
      kind: 'flag_seen',
      resourceType: 'Email',
      resourceId: 'acc-1:42',
      payload: '{"seen": true}',
      createdAt: DateTime(2024, 6),
      attempts: 0,
    );

/// Pumps the account list with a single [kTestAccount] and the given
/// [pendingChanges], then settles. Keeps the pending-changes tests free of
/// repeated `buildApp`/`baseOverrides` boilerplate.
Future<void> _pumpAccountsWithPending(
  WidgetTester tester, {
  List<PendingChange> pendingChanges = const [],
}) async {
  await tester.pumpWidget(
    buildApp(
      initialLocation: '/accounts',
      overrides: baseOverrides(
        accounts: [kTestAccount],
        pendingChanges: pendingChanges,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Pumps the account list for a single [kTestAccount], optionally seeding its
/// sync-health row and the set of accounts currently being verified. Keeps the
/// buildApp/baseOverrides scaffold in one place so the sync-health tests differ
/// only in what they assert.
Future<void> _pumpAccountList(
  WidgetTester tester, {
  SyncHealthRow? syncHealth,
  Set<String> verifying = const <String>{},
}) {
  return tester.pumpWidget(
    buildApp(
      initialLocation: '/accounts',
      overrides: baseOverrides(
        accounts: [kTestAccount],
        syncHealth: syncHealth,
        verifying: verifying,
      ),
    ),
  );
}

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

    SyncHealthRow healthRow({
      required bool isHealthy,
      String? discrepancySummary,
      String? lastError,
    }) =>
        SyncHealthRow(
          accountId: kTestAccount.id,
          lastVerifiedAt: DateTime(2024, 6),
          isHealthy: isHealthy,
          discrepancySummary: discrepancySummary,
          lastError: lastError,
        );

    // The three rendered states of the health row. 'Discrepancies found' is
    // six characters longer than 'Healthy' and adds detail lines beneath, and
    // the verifying row pairs a fixed-size spinner with its label, so all
    // three need the same overflow guarantee.
    final healthVariants = [
      (
        name: 'healthy',
        marker: 'Healthy',
        row: healthRow(isHealthy: true),
        verifying: const <String>{},
      ),
      (
        name: 'discrepancies',
        marker: 'Discrepancies found',
        row: healthRow(
          isHealthy: false,
          discrepancySummary:
              '{"INBOX":{"missingLocally":3,"missingOnServer":0,'
              '"flagMismatches":1}}',
        ),
        verifying: const <String>{},
      ),
      (
        name: 'verifying',
        marker: 'verifying',
        row: healthRow(isHealthy: true),
        verifying: {kTestAccount.id},
      ),
    ];

    testWidgets('shows Healthy when sync health is healthy', (tester) async {
      await _pumpAccountList(tester, syncHealth: healthRow(isHealthy: true));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Healthy', findRichText: true),
        findsOneWidget,
      );
    });

    // Regression: the health row used to be a Row whose 'Sync health: ' label
    // and trailing date were sized to their intrinsic widths. At accessibility
    // text scales they squeezed the status to zero width and overflowed — by
    // 52px on a Galaxy A80 at font_scale 1.8, and by far more on the narrow
    // surface used here. Every other test in this file runs at the default
    // 800x600 logical surface, where even scale 2.0 fits, which is why none of
    // them caught it. takeException() is a catch-all, so this also fails on
    // any unrelated reported error, which is fine for a smoke assertion.
    for (final variant in healthVariants) {
      testWidgets('${variant.name} row does not overflow at large text scale',
          (tester) async {
        // 360x800 logical, i.e. a compact phone — the row gets 360 - 72 indent
        // - 16 trailing = 272px.
        tester.view.physicalSize = const Size(1080, 2400);
        tester.platformDispatcher.textScaleFactorTestValue = 2.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

        await _pumpAccountList(
          tester,
          syncHealth: variant.row,
          verifying: variant.verifying,
        );
        // pump, not pumpAndSettle: the verifying row holds a
        // CircularProgressIndicator, whose animation never ends, so
        // pumpAndSettle simulates its full 10-minute timeout and throws.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // Guard the precondition. Without the scale actually reaching the
        // widget the old Row fits in 272px and this test would pass against
        // the very bug it exists to catch. The bound is deliberately loose:
        // since Flutter 3.16 the platform text scaler is non-linear, so a
        // system factor of 2.0 renders a 14px font at ~18.8px, not 28px. All
        // this has to prove is that the override arrived and is not identity.
        final scaler = MediaQuery.textScalerOf(
          tester.element(find.text('sharedinbox.de')),
        );
        expect(scaler.scale(14), greaterThan(16));
        // ...and that the row under test actually rendered, so a silently
        // empty screen cannot masquerade as "no overflow".
        expect(
          find.textContaining(variant.marker, findRichText: true),
          findsOneWidget,
        );

        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('shows discrepancy details when sync health has discrepancies',
        (
      tester,
    ) async {
      const summary =
          '{"INBOX":{"missingLocally":3,"missingOnServer":0,"flagMismatches":1}}';
      await _pumpAccountList(
        tester,
        syncHealth: healthRow(isHealthy: false, discrepancySummary: summary),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Discrepancies found', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('missing locally: 3'), findsOneWidget);
      expect(find.text('flag mismatches: 1'), findsOneWidget);
      // Zero-valued metrics are not listed.
      expect(find.textContaining('missing on server'), findsNothing);
    });

    testWidgets(
      'shows plain "Discrepancies found" when the summary is unparseable',
      (tester) async {
        await _pumpAccountList(
          tester,
          syncHealth:
              healthRow(isHealthy: false, discrepancySummary: 'not-json'),
        );
        await tester.pumpAndSettle();

        expect(
          find.textContaining('Discrepancies found', findRichText: true),
          findsOneWidget,
        );
        expect(find.textContaining('missing locally'), findsNothing);
      },
    );

    testWidgets('each discrepancy metric is on its own line', (tester) async {
      const summary =
          '{"INBOX":{"missingLocally":3,"missingOnServer":2,"flagMismatches":1}}';
      await _pumpAccountList(
        tester,
        syncHealth: healthRow(isHealthy: false, discrepancySummary: summary),
      );
      await tester.pumpAndSettle();

      final localPos = tester.getTopLeft(find.text('missing locally: 3')).dy;
      final serverPos = tester.getTopLeft(find.text('missing on server: 2')).dy;
      final flagPos = tester.getTopLeft(find.text('flag mismatches: 1')).dy;
      expect(serverPos, greaterThan(localPos));
      expect(flagPos, greaterThan(serverPos));
    });

    testWidgets('shows labeled pending-changes row when changes are queued', (
      tester,
    ) async {
      await _pumpAccountsWithPending(
        tester,
        pendingChanges: [_pendingChange(), _pendingChange(id: 2)],
      );

      expect(find.text('Pending changes: 2'), findsOneWidget);
    });

    testWidgets('hides pending-changes row when there are no changes', (
      tester,
    ) async {
      await _pumpAccountsWithPending(tester);

      expect(find.textContaining('Pending changes:'), findsNothing);
    });

    testWidgets('tapping the pending-changes row opens the pending list', (
      tester,
    ) async {
      await _pumpAccountsWithPending(
        tester,
        pendingChanges: [_pendingChange()],
      );

      await tester.tap(find.text('Pending changes: 1'));
      await tester.pumpAndSettle();

      expect(find.text('Pending Changes'), findsOneWidget);
    });

    testWidgets(
      'pending-changes row is positioned below the account name row',
      (tester) async {
        await _pumpAccountsWithPending(
          tester,
          pendingChanges: [_pendingChange()],
        );

        final namePos = tester.getTopLeft(find.text('Alice')).dy;
        final pendingPos =
            tester.getTopLeft(find.text('Pending changes: 1')).dy;
        expect(pendingPos, greaterThan(namePos));
      },
    );

    testWidgets('shows failure reason when the sync health check failed', (
      tester,
    ) async {
      await _pumpAccountList(
        tester,
        syncHealth:
            healthRow(isHealthy: false, lastError: 'JMAP connect failed'),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Sync check failed'), findsOneWidget);
      expect(find.textContaining('JMAP connect failed'), findsOneWidget);
    });

    testWidgets('shows verifying indicator while a check is in progress', (
      tester,
    ) async {
      await _pumpAccountList(tester, verifying: {kTestAccount.id});
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
      await _pumpAccountList(tester, syncHealth: healthRow(isHealthy: true));
      await tester.pumpAndSettle();

      final namePos = tester.getTopLeft(find.text('Alice')).dy;
      final healthPos = tester
          .getTopLeft(find.textContaining('Healthy', findRichText: true))
          .dy;
      expect(healthPos, greaterThan(namePos));
    });
  });
}
