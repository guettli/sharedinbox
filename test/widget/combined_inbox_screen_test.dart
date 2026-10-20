import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/user_preferences.dart';
import 'package:sharedinbox/di.dart';

import 'helpers.dart';

void main() {
  group('CombinedInboxScreen', () {
    testWidgets(
      'deleting an opened mail returns to the inbox when the preference '
      'says so',
      (tester) async {
        final first = testEmail(id: 'acc-1:1', subject: 'First mail');
        final second = testEmail(id: 'acc-1:2', subject: 'Second mail');
        await tester.pumpWidget(
          buildApp(
            initialLocation: '/inbox',
            userPreferences: FakeUserPreferencesRepository(
              afterMailViewAction: AfterMailViewAction.showMailbox,
            ),
            overrides: [
              accountRepositoryProvider.overrideWithValue(
                FakeAccountRepository([kTestAccount]),
              ),
              mailboxRepositoryProvider.overrideWithValue(
                FakeMailboxRepository(),
              ),
              emailRepositoryProvider.overrideWithValue(
                FakeEmailRepository(
                  emails: [first, second],
                  emailDetail: first,
                  emailBody: const EmailBody(
                    emailId: 'acc-1:1',
                    textBody: 'Hi',
                    attachments: [],
                  ),
                ),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('First mail'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byWidgetPredicate((w) => w is Tooltip && w.message == 'Delete'),
        );
        await tester.pumpAndSettle();

        // Nothing on the inbox watches the preferences provider, so the detail
        // screen used to read no value and moved on to the next mail.
        expect(find.text('Combined Inbox'), findsOneWidget);
        expect(find.byTooltip('Delete'), findsNothing);
      },
    );

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
