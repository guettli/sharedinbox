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

      expect(find.text('1 email(s) moved'), findsNothing);
    },
  );

  testWidgets('shows snackbar for fresh action pushed in current session', (
    tester,
  ) async {
    when(
      mockUndoRepo.getHistory(limit: anyNamed('limit')),
    ).thenAnswer((_) async => []);

    await tester.pumpWidget(buildShell(mockUndoRepo));
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(UndoShell));
    final freshAction = UndoAction(
      id: '1',
      accountId: 'acc1',
      type: UndoType.move,
      emailIds: ['e1'],
      sourceMailboxPath: 'INBOX',
    );
    await ProviderScope.containerOf(
      context,
    ).read(undoServiceProvider.notifier).pushAction(freshAction);
    await tester.pumpAndSettle();

    expect(find.text('1 email(s) moved'), findsOneWidget);
  });

  testWidgets('shows correct text for delete action (moved to Trash)', (
    tester,
  ) async {
    when(
      mockUndoRepo.getHistory(limit: anyNamed('limit')),
    ).thenAnswer((_) async => []);

    await tester.pumpWidget(buildShell(mockUndoRepo));
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(UndoShell));
    final deleteAction = UndoAction(
      id: '2',
      accountId: 'acc1',
      type: UndoType.delete,
      emailIds: ['e1', 'e2'],
      sourceMailboxPath: 'INBOX',
    );
    await ProviderScope.containerOf(
      context,
    ).read(undoServiceProvider.notifier).pushAction(deleteAction);
    await tester.pumpAndSettle();

    expect(find.text('2 email(s) moved to Trash'), findsOneWidget);
  });
}
