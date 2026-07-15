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

  // Each fresh action produces two feedback surfaces owned by UndoShell:
  // the AppBar flash overlay and the bottom action bar. Both carry the same
  // label + icon, so every user-visible string appears twice while both are
  // on screen.
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

      expect(find.text('1 email moved'), findsNWidgets(2));
      // Bottom overlay carries an inline Undo button.
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

    expect(find.text('Deleted 2 emails'), findsNWidgets(2));
    expect(find.byIcon(Icons.delete), findsNWidgets(2));
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

    expect(find.text('Archived 1 email'), findsNWidgets(2));
    expect(find.byIcon(Icons.archive), findsNWidgets(2));
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

    expect(find.text('Marked 3 emails as spam'), findsNWidgets(2));
    expect(find.byIcon(Icons.report), findsNWidgets(2));
  });

  testWidgets('flash overlay auto-dismisses after ~1.4 s', (tester) async {
    when(
      mockUndoRepo.getHistory(limit: anyNamed('limit')),
    ).thenAnswer((_) async => []);

    await tester.pumpWidget(buildShell(mockUndoRepo));
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

    // Immediately after the push both the flash and the bottom overlay are
    // visible → text appears twice.
    expect(find.text('Archived 1 email'), findsNWidgets(2));

    // After the flash timer (1400 ms) fires only the bottom overlay remains.
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Archived 1 email'), findsOneWidget);
  });

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

    expect(find.text('Deleted 1 email'), findsNWidgets(2));

    // After 5.5 s both flash and bottom overlay are gone.
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Deleted 1 email'), findsNothing);
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

      expect(find.text('Deleted 1 email'), findsNWidgets(2));
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
