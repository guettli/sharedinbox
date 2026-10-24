import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/user_preferences.dart';
import 'package:sharedinbox/di.dart';

import 'helpers.dart';

void main() {
  group('CombinedInboxScreen', () {
    // Nothing on the combined inbox watches the preferences provider, so the
    // detail screen used to read no value and always moved on to the next
    // mail, whatever the user had chosen.
    Future<FakeEmailRepository> openFirstAnd(
      WidgetTester tester,
      AfterMailViewAction action,
      Future<void> Function() act,
    ) async {
      final first = testEmail(id: 'acc-1:1', subject: 'First mail');
      final second = testEmail(id: 'acc-1:2', subject: 'Second mail');
      final repo = FakeEmailRepository(
        emails: [first, second],
        emailDetail: first,
        emailBody: const EmailBody(
          emailId: 'acc-1:1',
          textBody: 'Hi',
          attachments: [],
        ),
      );
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/inbox',
          userPreferences:
              FakeUserPreferencesRepository(afterMailViewAction: action),
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
            emailRepositoryProvider.overrideWithValue(repo),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('First mail'));
      await tester.pumpAndSettle();
      await act();
      await tester.pumpAndSettle();
      return repo;
    }

    Future<void> openFirstAndDelete(
      WidgetTester tester,
      AfterMailViewAction action,
    ) =>
        openFirstAnd(
          tester,
          action,
          () => tester.tap(
            find.byWidgetPredicate(
              (w) => w is Tooltip && w.message == 'Delete',
            ),
          ),
        );

    testWidgets('after deleting, "Return to mailbox" goes back to the inbox', (
      tester,
    ) async {
      await openFirstAndDelete(tester, AfterMailViewAction.showMailbox);

      expect(find.text('Combined Inbox'), findsOneWidget);
      expect(find.byTooltip('Delete'), findsNothing);
    });

    testWidgets('after deleting, "Next message" stays in the mail view', (
      tester,
    ) async {
      await openFirstAndDelete(tester, AfterMailViewAction.nextMessage);

      expect(find.byTooltip('Delete'), findsOneWidget);
    });

    // "Mark as unread" keeps a mail for later; moving on to the next mail
    // would open it and mark it read although the user never chose it.
    testWidgets(
        'mark as unread returns to the inbox and leaves the next mail unread '
        'even with "Next message"', (tester) async {
      final repo = await openFirstAnd(
        tester,
        AfterMailViewAction.nextMessage,
        () async {
          await tester.tap(find.byType(PopupMenuButton<String>));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Mark as unread'));
        },
      );

      expect(find.text('Combined Inbox'), findsOneWidget);
      expect(find.byTooltip('Delete'), findsNothing);
      expect(
        repo.setFlagCalls.lastWhere((c) => c.emailId == 'acc-1:1').seen,
        isFalse,
      );
      expect(repo.setFlagCalls.where((c) => c.emailId == 'acc-1:2'), isEmpty);
    });

    testWidgets(
      'overflow menu exposes "Debug messages" entry in selection mode (#345)',
      (tester) async {
        final email = testEmail(subject: 'Merged inbox mail');
        await tester.pumpWidget(
          buildApp(
            initialLocation: '/inbox',
            overrides: [
              accountRepositoryProvider.overrideWithValue(
                FakeAccountRepository([kTestAccount]),
              ),
              mailboxRepositoryProvider.overrideWithValue(
                FakeMailboxRepository(),
              ),
              emailRepositoryProvider.overrideWithValue(
                FakeEmailRepository(emails: [email]),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Merged inbox mail'), findsOneWidget);

        // Enter selection mode: same long-press affordance as every other list.
        await tester.longPress(find.text('Merged inbox mail'));
        await tester.pumpAndSettle();

        // Selection AppBar swaps in and the "..." overflow is present.
        expect(find.text('1 selected'), findsOneWidget);
        expect(find.byIcon(Icons.select_all), findsOneWidget);
        expect(find.byTooltip('More actions'), findsOneWidget);

        await tester.tap(find.byTooltip('More actions'));
        await tester.pumpAndSettle();

        expect(find.text('Debug messages'), findsOneWidget);
      },
    );
  });
}
