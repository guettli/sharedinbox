import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/storage/db_open_result.dart';
import 'package:sharedinbox/ui/screens/database_unreadable_screen.dart';

void main() {
  Future<void> pump(
    WidgetTester tester,
    DatabaseUnreadableScreen screen,
  ) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());
    await tester.pumpWidget(screen);
  }

  testWidgets('renders a message and error detail for each reason', (
    tester,
  ) async {
    for (final reason in DbUnreadableReason.values) {
      await pump(
        tester,
        DatabaseUnreadableScreen(
          result: DbProbeResult.unreadable(reason, 'SqliteException(26)'),
          onDeleteAndRestart: () async {},
        ),
      );
      expect(find.text('SqliteException(26)'), findsOneWidget);
      expect(find.text('Report Issue on GitHub'), findsOneWidget);
    }
  });

  testWidgets('offers delete for recoverable failures', (tester) async {
    await pump(
      tester,
      DatabaseUnreadableScreen(
        result: const DbProbeResult.unreadable(
          DbUnreadableReason.keyMissing,
          'boom',
        ),
        onDeleteAndRestart: () async {},
      ),
    );
    expect(find.text('Delete local cache and restart'), findsOneWidget);
  });

  testWidgets('hides delete for the build-bug case', (tester) async {
    await pump(
      tester,
      DatabaseUnreadableScreen(
        result: const DbProbeResult.unreadable(
          DbUnreadableReason.buildMissingCipher,
          'boom',
        ),
        // Even if a callback is passed, allowsDelete is false here.
        onDeleteAndRestart: () async {},
      ),
    );
    expect(find.text('Delete local cache and restart'), findsNothing);
  });

  testWidgets('delete button runs the callback after confirmation', (
    tester,
  ) async {
    var deleted = false;
    await pump(
      tester,
      DatabaseUnreadableScreen(
        result: const DbProbeResult.unreadable(
          DbUnreadableReason.corrupt,
          'boom',
        ),
        onDeleteAndRestart: () async {
          deleted = true;
        },
      ),
    );

    await tester.tap(find.text('Delete local cache and restart'));
    await tester.pumpAndSettle();
    // Confirmation dialog appears; confirm it.
    await tester.tap(find.text('Delete and restart'));
    await tester.pumpAndSettle();
    expect(deleted, isTrue);
  });
}
