import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/repositories/sync_log_repository.dart';
import 'package:sharedinbox/ui/screens/force_resync_screen.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';

MailboxSyncStats _stats({
  String mailboxPath = 'INBOX',
  String? mailboxName,
  int fetched = 12,
  int skipped = 3456,
}) =>
    MailboxSyncStats(
      mailboxPath: mailboxPath,
      mailboxName: mailboxName,
      fetched: fetched,
      skipped: skipped,
      bytesTransferred: 0,
    );

/// Mirrors how _ProgressBody hosts the row: a padded, scrolling list. The
/// padding matters — it costs the row 32px, so a Column scaffold would give it
/// 32px more room than production and understate any overflow. Scrolling
/// matters too: in a Column a starved row grows unboundedly tall and reports a
/// *vertical* overflow, which takeException() cannot tell apart from the
/// horizontal one these tests are about.
Future<void> _pumpRow(WidgetTester tester, MailboxSyncStats stats) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [MailboxProgressRow(stats: stats)],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('MailboxProgressRow', () {
    testWidgets('shows the display name and the fetched/skipped counts',
        (tester) async {
      await _pumpRow(tester, _stats(mailboxName: 'Inbox'));

      expect(find.text('Inbox'), findsOneWidget);
      expect(find.text('new 12 · skipped 3456'), findsOneWidget);
    });

    // A contract guard rather than a live path: every force-resync producer in
    // account_sync_manager sets mailboxName from the non-nullable Mailbox.name,
    // so the null branch is unreachable from this screen today. It is reachable
    // in sync_log_screen, which renders stored rows.
    testWidgets('falls back to the mailbox path when there is no name',
        (tester) async {
      await _pumpRow(tester, _stats(mailboxPath: 'INBOX/Archive/2026'));

      expect(find.text('INBOX/Archive/2026'), findsOneWidget);
    });

    // Regression for the row-overflow class fixed in #965. The trailing
    // counts were an unconstrained Text, so they took their intrinsic width,
    // starved the Expanded mailbox name to zero and overflowed the row anyway.
    //
    // What makes this reproduce is the WIDTH OF THE COUNTS, not the folder
    // name — pre-fix the name is clamped to zero regardless of its length, so
    // it contributes nothing horizontally. Six digits each is deliberate:
    // dropping to five removes ~28px and the row fits again, leaving a test
    // that passes against the bug. The default 800x600 test surface hides it
    // entirely, which is why no existing test caught this.
    testWidgets('does not overflow at large text scale', (tester) async {
      // 320x800 logical: the narrowest phone width still in common use.
      tester.view.physicalSize = const Size(960, 2400);
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await _pumpRow(
        tester,
        _stats(
          mailboxName: 'Archived customer correspondence 2026',
          fetched: 999999,
          skipped: 888888,
        ),
      );

      // Prove the scale reached the widget, otherwise this passes against the
      // bug. The bound is loose on purpose: the effective scale
      // observed inside the app tree has not always matched the raw factor,
      // so this asserts only that the override arrived and is not identity.
      final scaler = MediaQuery.textScalerOf(
        tester.element(find.byType(MailboxProgressRow)),
      );
      expect(scaler.scale(14), greaterThan(16));

      // A positive invariant, so this test fails loudly rather than going
      // quiet if someone shortens the counts or widens the surface: the name
      // must still be wrapping onto more than one line at this scale.
      expect(
        tester
            .getSize(find.text('Archived customer correspondence 2026'))
            .height,
        greaterThan(40),
      );

      expect(tester.takeException(), isNull);
    });
  });
}
