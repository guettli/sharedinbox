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
