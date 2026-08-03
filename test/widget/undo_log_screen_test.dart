import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mockito/mockito.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/undo_log_screen.dart';

import '../unit/undo_service_test.mocks.dart';
import 'helpers.dart';

Email _emailWith({
  String id = 'acc-1:42',
  String mailboxPath = 'INBOX',
  String subject = 'Hello world',
}) =>
    Email(
      id: id,
      accountId: 'acc-1',
      mailboxPath: mailboxPath,
      uid: 42,
      subject: subject,
      receivedAt: DateTime(2024, 6),
      sentAt: DateTime(2024, 6),
      from: const [EmailAddress(name: 'Bob', email: 'bob@example.com')],
      to: const [EmailAddress(email: 'alice@example.com')],
      cc: const [],
      isSeen: false,
      isFlagged: false,
      hasAttachment: false,
    );

Widget _buildApp({
  required List<UndoAction> history,
  List<Mailbox> mailboxes = const [],
  List<Account> accounts = const [
    Account(id: 'acc-1', displayName: 'Alice', email: 'alice@example.com'),
  ],
}) {
  final undoRepo = MockUndoRepository();
  when(undoRepo.getHistory(limit: anyNamed('limit')))
      .thenAnswer((_) async => history);
  when(undoRepo.trim(maxHistory: anyNamed('maxHistory')))
      .thenAnswer((_) async {});
  when(undoRepo.pushAndTrim(any, maxHistory: anyNamed('maxHistory')))
      .thenAnswer((_) async {});
  when(undoRepo.clearHistory()).thenAnswer((_) async {});

  final router = GoRouter(
    initialLocation: '/undo-log',
    routes: [
      GoRoute(
        path: '/undo-log',
        builder: (ctx, state) => const UndoLogScreen(),
      ),
      GoRoute(
        path: '/accounts/undo-log/:id',
        builder: (ctx, state) => const Scaffold(body: Text('detail-route')),
      ),
    ],
  );

  return ProviderScope(
    overrides: [
      undoRepositoryProvider.overrideWithValue(undoRepo),
      mailboxRepositoryProvider
          .overrideWithValue(FakeMailboxRepository(mailboxes)),
      emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
      accountRepositoryProvider
          .overrideWithValue(FakeAccountRepository(accounts)),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  group('UndoLogScreen subtitle', () {
    testWidgets(
      'shows "MOVE to <destination>" for move actions',
      (tester) async {
        // The undo log is about answering "what did I just do?" — for a move
        // that is the destination the user picked, not the origin folder.
        final action = UndoAction(
          id: 'undo-1',
          accountId: 'acc-1',
          type: UndoType.move,
          emailIds: ['acc-1:42'],
          sourceMailboxPath: 'INBOX',
          destinationMailboxPath: 'Archive',
          originalEmails: [_emailWith()],
          timestamp: DateTime(2024, 6, 1, 10),
        );

        await tester.pumpWidget(_buildApp(history: [action]));
        await tester.pumpAndSettle();

        expect(find.textContaining('MOVE to Archive'), findsOneWidget);
        expect(find.textContaining('from INBOX'), findsNothing);
      },
    );

    testWidgets(
      'still shows "DELETE from <source>" for delete actions',
      (tester) async {
        final action = UndoAction(
          id: 'undo-2',
          accountId: 'acc-1',
          type: UndoType.delete,
          emailIds: ['acc-1:42'],
          sourceMailboxPath: 'INBOX',
          originalEmails: [_emailWith()],
          timestamp: DateTime(2024, 6, 1, 10),
        );

        await tester.pumpWidget(_buildApp(history: [action]));
        await tester.pumpAndSettle();

        expect(find.textContaining('DELETE from INBOX'), findsOneWidget);
      },
    );

    testWidgets(
      'still shows "SNOOZE from <source>" for snooze actions',
      (tester) async {
        final action = UndoAction(
          id: 'undo-3',
          accountId: 'acc-1',
          type: UndoType.snooze,
          emailIds: ['acc-1:42'],
          sourceMailboxPath: 'INBOX',
          originalEmails: [_emailWith()],
          timestamp: DateTime(2024, 6, 1, 10),
        );

        await tester.pumpWidget(_buildApp(history: [action]));
        await tester.pumpAndSettle();

        expect(find.textContaining('SNOOZE from INBOX'), findsOneWidget);
      },
    );

    testWidgets(
      'move action without a destination path falls back to source',
      (tester) async {
        // Older log rows may lack destinationMailboxPath; showing "from
        // <source>" is more useful than dropping the folder entirely.
        final action = UndoAction(
          id: 'undo-4',
          accountId: 'acc-1',
          type: UndoType.move,
          emailIds: ['acc-1:42'],
          sourceMailboxPath: 'INBOX',
          originalEmails: [_emailWith()],
          timestamp: DateTime(2024, 6, 1, 10),
        );

        await tester.pumpWidget(_buildApp(history: [action]));
        await tester.pumpAndSettle();

        expect(find.textContaining('MOVE from INBOX'), findsOneWidget);
      },
    );

    testWidgets(
      'shows the account name, not the raw account id',
      (tester) async {
        final action = UndoAction(
          id: 'undo-6',
          accountId: 'acc-1',
          type: UndoType.delete,
          emailIds: ['acc-1:42'],
          sourceMailboxPath: 'INBOX',
          originalEmails: [_emailWith()],
          timestamp: DateTime(2024, 6, 1, 10),
        );

        await tester.pumpWidget(_buildApp(history: [action]));
        await tester.pumpAndSettle();

        expect(find.text('Alice'), findsOneWidget);
        expect(find.text('acc-1'), findsNothing);
      },
    );

    testWidgets(
      'falls back to the raw account id when the account is unknown',
      (tester) async {
        // Account removed after the action was logged: nothing to resolve, so
        // the raw id is shown rather than a blank line.
        final action = UndoAction(
          id: 'undo-7',
          accountId: 'gone',
          type: UndoType.delete,
          emailIds: ['acc-1:42'],
          sourceMailboxPath: 'INBOX',
          originalEmails: [_emailWith()],
          timestamp: DateTime(2024, 6, 1, 10),
        );

        await tester.pumpWidget(
          _buildApp(history: [action], accounts: const []),
        );
        await tester.pumpAndSettle();

        expect(find.text('gone'), findsOneWidget);
      },
    );

    testWidgets(
      'resolves JMAP opaque destination id to displayPath',
      (tester) async {
        // Same distinction as the detail screen (#288 / #227): the raw path
        // stored in the action row can be an opaque JMAP id.
        const inbox = Mailbox(
          id: 'acc-1:a',
          accountId: 'acc-1',
          path: 'a',
          name: 'INBOX',
          displayPath: 'INBOX',
          unreadCount: 0,
          totalCount: 0,
        );
        const archive = Mailbox(
          id: 'acc-1:b',
          accountId: 'acc-1',
          path: 'b',
          name: '2026',
          displayPath: 'Archive/2026',
          unreadCount: 0,
          totalCount: 0,
        );

        final action = UndoAction(
          id: 'undo-5',
          accountId: 'acc-1',
          type: UndoType.move,
          emailIds: ['acc-1:42'],
          sourceMailboxPath: 'a',
          destinationMailboxPath: 'b',
          originalEmails: [_emailWith(mailboxPath: 'a')],
          timestamp: DateTime(2024, 6, 1, 10),
        );

        await tester.pumpWidget(
          _buildApp(history: [action], mailboxes: const [inbox, archive]),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('MOVE to Archive/2026'), findsOneWidget);
        expect(find.textContaining('MOVE to b'), findsNothing);
      },
    );
  });
}
