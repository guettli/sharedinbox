import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/email_action_helpers.dart';

import '../unit/undo_service_test.mocks.dart';

// Batch helpers must push one aggregated UndoAction per
// `(accountId, sourceMailboxPath)` group, not one per thread. UndoShell only
// renders the last-pushed action's `emailIds.length`, so per-thread actions
// caused the SnackBar to always read "1" for multi-thread batches (#289).
void main() {
  late MockEmailRepository mockEmailRepo;
  late MockUndoRepository mockUndoRepo;

  setUp(() {
    mockEmailRepo = MockEmailRepository();
    mockUndoRepo = MockUndoRepository();
    when(
      mockUndoRepo.pushAndTrim(any, maxHistory: anyNamed('maxHistory')),
    ).thenAnswer((_) async {});
    when(
      mockUndoRepo.trim(maxHistory: anyNamed('maxHistory')),
    ).thenAnswer((_) async {});
    when(
      mockUndoRepo.getHistory(limit: anyNamed('limit')),
    ).thenAnswer((_) async => []);
    when(mockEmailRepo.getEmail(any)).thenAnswer((_) async => null);
    when(mockEmailRepo.deleteEmail(any)).thenAnswer((_) async => 'Trash');
    when(mockEmailRepo.snoozeEmail(any, any)).thenAnswer((_) async {});
    when(mockEmailRepo.moveEmail(any, any)).thenAnswer((_) async {});
  });

  EmailThread thread({
    required String threadId,
    required String accountId,
    required String mailboxPath,
    required List<String> emailIds,
  }) =>
      EmailThread(
        threadId: threadId,
        subject: null,
        participants: const [],
        latestDate: DateTime.now(),
        messageCount: emailIds.length,
        hasUnread: false,
        isFlagged: false,
        latestEmailId: emailIds.last,
        emailIds: emailIds,
        accountId: accountId,
        mailboxPath: mailboxPath,
      );

  // Renders a bare Consumer so we can hand a real WidgetRef to the helper
  // without spinning up a full screen. The onReady callback runs once the
  // widget is mounted so tests can invoke the helper against a valid
  // container.
  Widget harness({
    required void Function(WidgetRef ref) onReady,
  }) {
    return ProviderScope(
      overrides: [
        emailRepositoryProvider.overrideWithValue(mockEmailRepo),
        undoRepositoryProvider.overrideWithValue(mockUndoRepo),
      ],
      child: MaterialApp(
        home: Consumer(
          builder: (ctx, ref, _) {
            WidgetsBinding.instance.addPostFrameCallback((_) => onReady(ref));
            return const Scaffold(body: SizedBox.shrink());
          },
        ),
      ),
    );
  }

  Future<List<UndoAction>> waitForActions(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    await container.read(undoServiceProvider.notifier).init();
    await tester.pumpAndSettle();
    return container.read(undoServiceProvider);
  }

  testWidgets(
    'batchDelete aggregates threads from the same source into one undo action',
    (tester) async {
      late WidgetRef capturedRef;
      await tester.pumpWidget(
        harness(onReady: (r) => capturedRef = r),
      );
      await tester.pump();

      final threads = [
        thread(
          threadId: 't1',
          accountId: 'acc1',
          mailboxPath: 'INBOX',
          emailIds: ['acc1:1'],
        ),
        thread(
          threadId: 't2',
          accountId: 'acc1',
          mailboxPath: 'INBOX',
          emailIds: ['acc1:2'],
        ),
        thread(
          threadId: 't3',
          accountId: 'acc1',
          mailboxPath: 'INBOX',
          emailIds: ['acc1:3'],
        ),
      ];

      await batchDelete(capturedRef, threads: threads);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(Consumer)),
      );
      final actions = await waitForActions(tester, container);

      expect(actions, hasLength(1));
      expect(actions.single.type, UndoType.delete);
      expect(actions.single.emailIds, ['acc1:1', 'acc1:2', 'acc1:3']);
      expect(actions.single.sourceMailboxPath, 'INBOX');
    },
  );

  testWidgets(
    'batchDelete keeps one undo action per source folder for cross-folder selections',
    (tester) async {
      late WidgetRef capturedRef;
      await tester.pumpWidget(
        harness(onReady: (r) => capturedRef = r),
      );
      await tester.pump();

      final threads = [
        thread(
          threadId: 't1',
          accountId: 'acc1',
          mailboxPath: 'INBOX',
          emailIds: ['acc1:1'],
        ),
        thread(
          threadId: 't2',
          accountId: 'acc1',
          mailboxPath: 'INBOX',
          emailIds: ['acc1:2'],
        ),
        thread(
          threadId: 't3',
          accountId: 'acc1',
          mailboxPath: 'Newsletters',
          emailIds: ['acc1:3'],
        ),
      ];

      await batchDelete(capturedRef, threads: threads);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(Consumer)),
      );
      final actions = await waitForActions(tester, container);

      expect(actions, hasLength(2));
      final bySource = {for (final a in actions) a.sourceMailboxPath: a};
      expect(bySource['INBOX']!.emailIds, ['acc1:1', 'acc1:2']);
      expect(bySource['Newsletters']!.emailIds, ['acc1:3']);
    },
  );

  // The swipe-tree snooze levels compute the target date themselves and call
  // snoozeThreadsUntil directly, bypassing the SnoozePicker modal (#240).
  testWidgets(
    'snoozeThreadsUntil snoozes every email and pushes one undo action',
    (tester) async {
      late WidgetRef capturedRef;
      await tester.pumpWidget(harness(onReady: (r) => capturedRef = r));
      await tester.pump();

      final until = DateTime(2026, 9, 1, 8);
      await snoozeThreadsUntil(
        capturedRef,
        threads: [
          thread(
            threadId: 't1',
            accountId: 'acc1',
            mailboxPath: 'INBOX',
            emailIds: ['acc1:1', 'acc1:2'],
          ),
        ],
        until: until,
      );

      verify(mockEmailRepo.snoozeEmail('acc1:1', until)).called(1);
      verify(mockEmailRepo.snoozeEmail('acc1:2', until)).called(1);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(Consumer)),
      );
      final actions = await waitForActions(tester, container);
      expect(actions, hasLength(1));
      expect(actions.single.type, UndoType.snooze);
      expect(actions.single.emailIds, ['acc1:1', 'acc1:2']);
    },
  );

  // The swipe-tree Move → folder leaves move to a concrete path directly.
  testWidgets(
    'moveThreadsToPath moves every email and pushes one move undo action',
    (tester) async {
      late WidgetRef capturedRef;
      await tester.pumpWidget(harness(onReady: (r) => capturedRef = r));
      await tester.pump();

      await moveThreadsToPath(
        capturedRef,
        threads: [
          thread(
            threadId: 't1',
            accountId: 'acc1',
            mailboxPath: 'INBOX',
            emailIds: ['acc1:1'],
          ),
        ],
        destPath: 'Archive/2026',
      );

      verify(mockEmailRepo.moveEmail('acc1:1', 'Archive/2026')).called(1);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(Consumer)),
      );
      final actions = await waitForActions(tester, container);
      expect(actions, hasLength(1));
      expect(actions.single.type, UndoType.move);
      expect(actions.single.destinationMailboxPath, 'Archive/2026');
    },
  );
}
