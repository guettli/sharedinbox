import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/widgets/undo_shell.dart';

import '../unit/undo_service_test.mocks.dart';

void main() {
  late MockUndoRepository mockUndoRepo;
  late MockEmailRepository mockEmailRepo;

  setUp(() {
    mockUndoRepo = MockUndoRepository();
    mockEmailRepo = MockEmailRepository();
    when(
      mockUndoRepo.pushAndTrim(any, maxHistory: anyNamed('maxHistory')),
    ).thenAnswer((_) async {});
    when(
      mockUndoRepo.trim(maxHistory: anyNamed('maxHistory')),
    ).thenAnswer((_) async {});
    when(mockUndoRepo.clearHistory()).thenAnswer((_) async {});
    // Some tests tap UNDO, which triggers repo access; give minimal stubs.
    when(mockEmailRepo.getEmail(any)).thenAnswer((_) async => null);
    when(
      mockEmailRepo.findEmailByMessageId(any, any),
    ).thenAnswer((_) async => null);
    when(
      mockEmailRepo.cancelPendingChange(any, any),
    ).thenAnswer((_) async => false);
    when(mockEmailRepo.moveEmail(any, any)).thenAnswer((_) async {});
    when(mockEmailRepo.restoreEmails(any)).thenAnswer((_) async {});
  });

  Widget buildShell(MockUndoRepository repo) {
    return ProviderScope(
      overrides: [
        undoRepositoryProvider.overrideWithValue(repo),
        emailRepositoryProvider.overrideWithValue(mockEmailRepo),
      ],
      child: const MaterialApp(
        home: UndoShell(child: Scaffold(body: Text('content'))),
      ),
    );
  }

  Future<void> pushAction(WidgetTester tester, UndoAction action) async {
    final context = tester.element(find.byType(UndoShell));
    await ProviderScope.containerOf(
      context,
    ).read(undoServiceProvider.notifier).pushAction(action);
    await tester.pumpAndSettle();
  }

  // Each fresh action produces two feedback surfaces owned by UndoShell: a
  // thin coloured strip painted below the AppBar (icon-less, so it does not
  // obscure the action buttons) and a SnackBar-shaped bottom bar carrying
  // the label, icon, and inline Undo. Every user-visible label therefore
  // appears exactly once — in the bottom overlay only.
  Finder findFlashStrip() => find.byKey(const ValueKey('undoFlashStrip'));

  testWidgets(
    'does not show feedback for stale action loaded from persistence on startup',
    (tester) async {
      final staleAction = UndoAction(
        id: '1',
        accountId: 'acc1',
        type: UndoType.move,
        emailIds: ['e1'],
        sourceMailboxPath: 'INBOX',
        timestamp: DateTime.now().subtract(const Duration(hours: 1)),
      );
      when(
        mockUndoRepo.getHistory(limit: anyNamed('limit')),
      ).thenAnswer((_) async => [staleAction]);

      await tester.pumpWidget(buildShell(mockUndoRepo));
      await tester.pumpAndSettle();

      expect(find.text('1 email moved'), findsNothing);
      expect(findFlashStrip(), findsNothing);
    },
  );

  testWidgets(
    'shows generic move label for a fresh action pushed in current session',
    (tester) async {
      when(
        mockUndoRepo.getHistory(limit: anyNamed('limit')),
      ).thenAnswer((_) async => []);

      await tester.pumpWidget(buildShell(mockUndoRepo));
      await tester.pumpAndSettle();

      await pushAction(
        tester,
        UndoAction(
          id: '1',
          accountId: 'acc1',
          type: UndoType.move,
          emailIds: ['e1'],
          sourceMailboxPath: 'INBOX',
        ),
      );

      // Bottom overlay carries the label + icon + Undo; the flash strip is
      // paint-only so nothing about it appears in the semantic tree beyond
      // its identifying key.
      expect(find.text('1 email moved'), findsOneWidget);
      expect(findFlashStrip(), findsOneWidget);
      expect(find.text('UNDO'), findsOneWidget);
    },
  );

  testWidgets('shows "Deleted" label for a delete action', (tester) async {
    when(
      mockUndoRepo.getHistory(limit: anyNamed('limit')),
    ).thenAnswer((_) async => []);

    await tester.pumpWidget(buildShell(mockUndoRepo));
    await tester.pumpAndSettle();

    await pushAction(
      tester,
      UndoAction(
        id: '2',
        accountId: 'acc1',
        type: UndoType.delete,
        emailIds: ['e1', 'e2'],
        sourceMailboxPath: 'INBOX',
      ),
    );

    expect(find.text('Deleted 2 emails'), findsOneWidget);
    expect(find.byIcon(Icons.delete), findsOneWidget);
    expect(findFlashStrip(), findsOneWidget);
  });

  testWidgets('shows "Archived" label for a move with archive role', (
    tester,
  ) async {
    when(
      mockUndoRepo.getHistory(limit: anyNamed('limit')),
    ).thenAnswer((_) async => []);

    await tester.pumpWidget(buildShell(mockUndoRepo));
    await tester.pumpAndSettle();

    await pushAction(
      tester,
      UndoAction(
        id: '3',
        accountId: 'acc1',
        type: UndoType.move,
        emailIds: ['e1'],
        sourceMailboxPath: 'INBOX',
        destinationMailboxPath: 'Archive',
        destinationMailboxRole: 'archive',
      ),
    );

    expect(find.text('Archived 1 email'), findsOneWidget);
    expect(find.byIcon(Icons.archive), findsOneWidget);
    expect(findFlashStrip(), findsOneWidget);
  });

  testWidgets('shows "Marked as spam" label for a move with junk role', (
    tester,
  ) async {
    when(
      mockUndoRepo.getHistory(limit: anyNamed('limit')),
    ).thenAnswer((_) async => []);

    await tester.pumpWidget(buildShell(mockUndoRepo));
    await tester.pumpAndSettle();

    await pushAction(
      tester,
      UndoAction(
        id: '4',
        accountId: 'acc1',
        type: UndoType.move,
        emailIds: ['e1', 'e2', 'e3'],
        sourceMailboxPath: 'INBOX',
        destinationMailboxPath: 'Junk',
        destinationMailboxRole: 'junk',
      ),
    );

    expect(find.text('Marked 3 emails as spam'), findsOneWidget);
    expect(find.byIcon(Icons.report), findsOneWidget);
    expect(findFlashStrip(), findsOneWidget);
  });

  testWidgets(
    'flash strip auto-dismisses after ~800 ms without obscuring the AppBar',
    (tester) async {
      when(
        mockUndoRepo.getHistory(limit: anyNamed('limit')),
      ).thenAnswer((_) async => []);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            undoRepositoryProvider.overrideWithValue(mockUndoRepo),
            emailRepositoryProvider.overrideWithValue(mockEmailRepo),
          ],
          child: MaterialApp(
            home: UndoShell(
              child: Scaffold(
                appBar: AppBar(title: const Text('T')),
                body: const Text('content'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await pushAction(
        tester,
        UndoAction(
          id: '5',
          accountId: 'acc1',
          type: UndoType.move,
          emailIds: ['e1'],
          sourceMailboxPath: 'INBOX',
          destinationMailboxPath: 'Archive',
          destinationMailboxRole: 'archive',
        ),
      );

      // Immediately after the push the flash strip is on screen and lives
      // strictly below the AppBar area (status-bar padding + kToolbarHeight),
      // so the AppBar action-button row remains visible for chained taps.
      expect(find.text('Archived 1 email'), findsOneWidget);
      expect(findFlashStrip(), findsOneWidget);

      final stripRect = tester.getRect(findFlashStrip());
      // Strip sits at or below the AppBar's bottom edge — so the trailing
      // action buttons (reply, archive, delete, ...) stay visible for the
      // next tap. Test view has no status-bar padding, so kToolbarHeight is
      // the exact expected top.
      expect(stripRect.top, greaterThanOrEqualTo(kToolbarHeight));
      // Strip is a paint-only marker, kept intentionally thin (see
      // `_AppBarFlashOverlay.stripHeight`) so it never encroaches on body
      // content.
      expect(stripRect.height, lessThanOrEqualTo(12.0));

      // After the flash timer (800 ms) fires only the bottom overlay remains.
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pump(const Duration(milliseconds: 250));
      expect(findFlashStrip(), findsNothing);
      expect(find.text('Archived 1 email'), findsOneWidget);
    },
  );

  testWidgets('bottom overlay auto-dismisses after ~5 s', (tester) async {
    when(
      mockUndoRepo.getHistory(limit: anyNamed('limit')),
    ).thenAnswer((_) async => []);

    await tester.pumpWidget(buildShell(mockUndoRepo));
    await tester.pumpAndSettle();

    await pushAction(
      tester,
      UndoAction(
        id: '6',
        accountId: 'acc1',
        type: UndoType.delete,
        emailIds: ['e1'],
        sourceMailboxPath: 'INBOX',
      ),
    );

    expect(find.text('Deleted 1 email'), findsOneWidget);

    // After 5.5 s both flash strip and bottom overlay are gone.
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Deleted 1 email'), findsNothing);
    expect(findFlashStrip(), findsNothing);
  });

  testWidgets(
    'feedback still fires when the undo log is already at the 10-entry cap',
    (tester) async {
      when(
        mockUndoRepo.getHistory(limit: anyNamed('limit')),
      ).thenAnswer((_) async => []);

      await tester.pumpWidget(buildShell(mockUndoRepo));
      await tester.pumpAndSettle();

      // Fill the log to the 10-entry cap.
      for (var i = 0; i < 10; i++) {
        await pushAction(
          tester,
          UndoAction(
            id: 'fill-$i',
            accountId: 'acc1',
            type: UndoType.move,
            emailIds: ['x'],
            sourceMailboxPath: 'INBOX',
          ),
        );
      }

      // Let both overlays for the 10th fill action fade away so the next
      // assertion only sees widgets from the 11th push.
      await tester.pump(const Duration(seconds: 6));
      await tester.pump(const Duration(milliseconds: 250));

      // Pushing an 11th action must still trigger feedback even though the
      // list length after trim equals the previous length.
      await pushAction(
        tester,
        UndoAction(
          id: '11',
          accountId: 'acc1',
          type: UndoType.delete,
          emailIds: ['e1'],
          sourceMailboxPath: 'INBOX',
        ),
      );

      expect(find.text('Deleted 1 email'), findsOneWidget);
      expect(findFlashStrip(), findsOneWidget);
    },
  );

  testWidgets(
    'tapping UNDO on the bottom overlay triggers the undo repo call',
    (tester) async {
      when(
        mockUndoRepo.getHistory(limit: anyNamed('limit')),
      ).thenAnswer((_) async => []);

      await tester.pumpWidget(buildShell(mockUndoRepo));
      await tester.pumpAndSettle();

      await pushAction(
        tester,
        UndoAction(
          id: 'undo-me',
          accountId: 'acc1',
          type: UndoType.move,
          emailIds: ['e1'],
          sourceMailboxPath: 'INBOX',
          destinationMailboxPath: 'Archive',
          destinationMailboxRole: 'archive',
        ),
      );

      expect(find.text('UNDO'), findsOneWidget);

      await tester.tap(find.text('UNDO'));
      await tester.pumpAndSettle();

      // undo() moves the email back to its source mailbox. Confirms the
      // UNDO button is actually wired to the notifier.
      verify(mockEmailRepo.moveEmail('e1', 'INBOX')).called(1);
    },
  );
}
