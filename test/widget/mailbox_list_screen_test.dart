import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/widgets/mailbox_count_label.dart';

import 'helpers.dart';

/// Pumps [MailboxListScreen] backed by [mailboxes] and settles the frame.
Future<void> _pumpMailboxList(
  WidgetTester tester,
  List<Mailbox> mailboxes,
) async {
  await tester.pumpWidget(
    buildApp(
      initialLocation: '/accounts/acc-1/mailboxes',
      overrides: [
        accountRepositoryProvider.overrideWithValue(
          FakeAccountRepository([kTestAccount]),
        ),
        mailboxRepositoryProvider.overrideWithValue(
          FakeMailboxRepository(mailboxes),
        ),
        emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
      ],
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('MailboxListScreen', () {
    testWidgets('shows mailbox name', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository([kTestMailbox]),
            ),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('INBOX'), findsWidgets);
    });

    testWidgets('shows "unread / total" label when totalCount > 0', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository([kTestMailbox]),
            ),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // kTestMailbox has unreadCount = 3, totalCount = 10.
      expect(
        find.text('3 / 10', findRichText: true),
        findsOneWidget,
      );
    });

    testWidgets('shows the role label and role icon for a roled mailbox', (
      tester,
    ) async {
      const inbox = Mailbox(
        id: 'acc-1:INBOX',
        accountId: 'acc-1',
        path: 'INBOX',
        name: 'INBOX',
        unreadCount: 0,
        totalCount: 1,
        role: 'inbox',
      );
      await _pumpMailboxList(tester, [inbox]);

      expect(find.text('Inbox'), findsOneWidget);
      expect(find.byIcon(Icons.inbox), findsOneWidget);
      expect(find.byIcon(Icons.folder), findsNothing);
    });

    testWidgets(
        'shows the generic folder icon and no role label for a '
        'user-created mailbox', (tester) async {
      const custom = Mailbox(
        id: 'acc-1:Work',
        accountId: 'acc-1',
        path: 'Work',
        name: 'Work',
        unreadCount: 0,
        totalCount: 1,
      );
      await _pumpMailboxList(tester, [custom]);

      expect(find.byIcon(Icons.folder), findsOneWidget);
      expect(find.text('Work'), findsOneWidget);
      // No role sub-label for user folders.
      expect(find.text('Inbox'), findsNothing);
    });

    testWidgets('tapping a mailbox tile navigates to its email list', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository([kTestMailbox]),
            ),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('INBOX').first);
      await tester.pumpAndSettle();

      expect(find.text('No emails'), findsOneWidget);
    });

    testWidgets(
      'shows "0 / total" label when unreadCount is zero but totalCount > 0',
      (tester) async {
        const mailbox = Mailbox(
          id: 'acc-1:Sent',
          accountId: 'acc-1',
          path: 'Sent',
          name: 'Sent',
          unreadCount: 0,
          totalCount: 5,
        );
        await tester.pumpWidget(
          buildApp(
            initialLocation: '/accounts/acc-1/mailboxes',
            overrides: [
              accountRepositoryProvider.overrideWithValue(
                FakeAccountRepository([kTestAccount]),
              ),
              mailboxRepositoryProvider.overrideWithValue(
                FakeMailboxRepository([mailbox]),
              ),
              emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
            ],
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Sent'), findsOneWidget);
        expect(find.byType(Badge), findsNothing);
        expect(
          find.text('0 / 5', findRichText: true),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'long-press on a mailbox opens the folder actions sheet',
      (tester) async {
        await tester.pumpWidget(
          buildApp(
            initialLocation: '/accounts/acc-1/mailboxes',
            overrides: [
              accountRepositoryProvider.overrideWithValue(
                FakeAccountRepository([kTestAccount]),
              ),
              mailboxRepositoryProvider.overrideWithValue(
                FakeMailboxRepository([kTestMailbox]),
              ),
              emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.longPress(find.text('INBOX').first);
        await tester.pumpAndSettle();

        expect(find.text('Rename'), findsOneWidget);
        expect(find.text('Move'), findsOneWidget);
        expect(find.text('Diagnose'), findsOneWidget);
        expect(find.text('Delete'), findsOneWidget);
      },
    );

    testWidgets(
      'choosing Diagnose navigates to the folder diagnostics screen',
      (tester) async {
        await _pumpMailboxList(tester, [kTestMailbox]);

        await tester.longPress(find.text('INBOX').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Diagnose'));
        await tester.pumpAndSettle();

        expect(find.text('Folder diagnostics'), findsOneWidget);
      },
    );

    testWidgets(
      'choosing Delete → confirming calls repo.deleteMailbox',
      (tester) async {
        final repo = FakeMailboxRepository([kTestMailbox]);
        await tester.pumpWidget(
          buildApp(
            initialLocation: '/accounts/acc-1/mailboxes',
            overrides: [
              accountRepositoryProvider.overrideWithValue(
                FakeAccountRepository([kTestAccount]),
              ),
              mailboxRepositoryProvider.overrideWithValue(repo),
              emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.longPress(find.text('INBOX').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();
        expect(find.text('Delete folder?'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
        await tester.pumpAndSettle();

        expect(repo.deleteCalls, ['INBOX']);
      },
    );

    testWidgets(
      'choosing Rename → submitting calls repo.renameMailbox',
      (tester) async {
        final repo = FakeMailboxRepository([kTestMailbox]);
        await tester.pumpWidget(
          buildApp(
            initialLocation: '/accounts/acc-1/mailboxes',
            overrides: [
              accountRepositoryProvider.overrideWithValue(
                FakeAccountRepository([kTestAccount]),
              ),
              mailboxRepositoryProvider.overrideWithValue(repo),
              emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.longPress(find.text('INBOX').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Rename'));
        await tester.pumpAndSettle();
        expect(find.text('Rename folder'), findsOneWidget);

        await tester.enterText(find.byType(TextFormField), 'Renamed');
        await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
        await tester.pumpAndSettle();

        expect(repo.renameCalls, [(path: 'INBOX', newName: 'Renamed')]);
      },
    );

    testWidgets(
      'renders sub-folders indented deeper than their parent',
      (tester) async {
        const parent = Mailbox(
          id: 'acc-1:Archive',
          accountId: 'acc-1',
          path: 'Archive',
          name: 'Archive',
          displayPath: 'Archive',
          unreadCount: 0,
          totalCount: 1,
        );
        const child = Mailbox(
          id: 'acc-1:Archive/2026',
          accountId: 'acc-1',
          path: 'Archive/2026',
          name: '2026',
          displayPath: 'Archive/2026',
          unreadCount: 0,
          totalCount: 1,
        );
        await _pumpMailboxList(tester, [child, parent]);

        // Both rows show their leaf name.
        expect(find.text('Archive'), findsOneWidget);
        expect(find.text('2026'), findsOneWidget);

        double startIndent(String label) {
          final tile = tester.widget<ListTile>(
            find.ancestor(
              of: find.text(label),
              matching: find.byType(ListTile),
            ),
          );
          return (tile.contentPadding! as EdgeInsetsDirectional).start;
        }

        // The child is indented one level deeper than its parent.
        expect(startIndent('2026'), greaterThan(startIndent('Archive')));
      },
    );

    testWidgets(
      'nested folder tap navigates via its real (opaque) path',
      (tester) async {
        // JMAP-style: path is an opaque id, displayPath is hierarchical.
        const parent = Mailbox(
          id: 'acc-1:a',
          accountId: 'acc-1',
          path: 'a',
          name: 'Parent',
          displayPath: 'Parent',
          unreadCount: 0,
          totalCount: 1,
        );
        const child = Mailbox(
          id: 'acc-1:b',
          accountId: 'acc-1',
          path: 'b',
          name: 'Child',
          displayPath: 'Parent/Child',
          unreadCount: 0,
          totalCount: 1,
        );
        await _pumpMailboxList(tester, [parent, child]);

        await tester.tap(find.text('Child'));
        await tester.pumpAndSettle();

        // Navigated into an (empty) email list rather than staying on Folders.
        expect(find.text('No emails'), findsOneWidget);
      },
    );

    testWidgets(
      'renders a non-tappable header for an inferred phantom parent',
      (tester) async {
        // Only the leaf exists as a real mailbox; "Archive" is inferred.
        const child = Mailbox(
          id: 'acc-1:Archive/2026',
          accountId: 'acc-1',
          path: 'Archive/2026',
          name: '2026',
          displayPath: 'Archive/2026',
          unreadCount: 0,
          totalCount: 1,
        );
        await _pumpMailboxList(tester, [child]);

        expect(find.text('Archive'), findsOneWidget);
        expect(find.text('2026'), findsOneWidget);
        expect(find.byIcon(Icons.folder_open), findsOneWidget);

        // Tapping the phantom header does nothing (stays on Folders).
        await tester.tap(find.text('Archive'));
        await tester.pumpAndSettle();
        expect(find.text('Folders'), findsOneWidget);
      },
    );

    testWidgets('shows a bare 0 when totalCount is zero', (tester) async {
      const emptyMailbox = Mailbox(
        id: 'acc-1:Empty',
        accountId: 'acc-1',
        path: 'Empty',
        name: 'Empty',
        unreadCount: 0,
        totalCount: 0,
      );
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository([emptyMailbox]),
            ),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Empty'), findsOneWidget);
      // An empty folder shows "0" (not a blank), so it is distinct from a
      // folder whose count could not be computed (#498).
      final label = tester.widget<MailboxCountLabel>(
        find.byType(MailboxCountLabel),
      );
      expect(label.total, 0);
      expect(find.text('0'), findsOneWidget);
      expect(find.textContaining('/', findRichText: true), findsNothing);
    });
  });
}
