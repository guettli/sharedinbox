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

  setUp(() {
    mockUndoRepo = MockUndoRepository();
    when(
      mockUndoRepo.pushAndTrim(any, maxHistory: anyNamed('maxHistory')),
    ).thenAnswer((_) async {});
    when(
      mockUndoRepo.trim(maxHistory: anyNamed('maxHistory')),
    ).thenAnswer((_) async {});
    when(mockUndoRepo.clearHistory()).thenAnswer((_) async {});
  });

  Widget buildShell(MockUndoRepository repo) {
    return ProviderScope(
      overrides: [undoRepositoryProvider.overrideWithValue(repo)],
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

  testWidgets(
    'does not show snackbar for stale action loaded from persistence on startup',
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

      expect(find.text('1 email moved'), findsOneWidget);
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
  });
}
