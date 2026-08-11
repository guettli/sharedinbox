import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/widgets/mailbox_count_label.dart';

import 'helpers.dart';

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
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository([inbox]),
            ),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Inbox'), findsOneWidget);
      expect(find.byIcon(Icons.inbox), findsOneWidget);
      expect(find.byIcon(Icons.folder), findsNothing);
    });

    testWidgets('shows the generic folder icon and no role label for a '
        'user-created mailbox', (tester) async {
      const custom = Mailbox(
        id: 'acc-1:Work',
        accountId: 'acc-1',
        path: 'Work',
        name: 'Work',
        unreadCount: 0,
        totalCount: 1,
      );
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository([custom]),
            ),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
          ],
        ),
      );
      await tester.pumpAndSettle();

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
        expect(find.text('Delete'), findsOneWidget);
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

    testWidgets('shows no count label when totalCount is zero', (tester) async {
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
      // The label widget is present but renders nothing when total is 0.
      final label = tester.widget<MailboxCountLabel>(
        find.byType(MailboxCountLabel),
      );
      expect(label.total, 0);
      expect(find.textContaining('/', findRichText: true), findsNothing);
    });
  });
}
