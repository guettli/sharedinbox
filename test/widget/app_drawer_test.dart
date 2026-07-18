import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/ui/widgets/app_drawer.dart';

import 'helpers.dart';

void main() {
  group('AppDrawer', () {
    const accountA = Account(
      id: 'acc-1',
      displayName: 'Alice',
      email: 'alice@example.com',
      imapHost: 'imap.example.com',
      smtpHost: 'smtp.example.com',
    );
    const accountB = Account(
      id: 'acc-2',
      displayName: 'Bob',
      email: 'bob@example.com',
      imapHost: 'imap.other.com',
      smtpHost: 'smtp.other.com',
    );
    const inbox = Mailbox(
      id: 'acc-1:INBOX',
      accountId: 'acc-1',
      path: 'INBOX',
      name: 'INBOX',
      unreadCount: 3,
      totalCount: 10,
    );
    const sent = Mailbox(
      id: 'acc-1:Sent',
      accountId: 'acc-1',
      path: 'Sent',
      name: 'Sent',
      unreadCount: 0,
      totalCount: 5,
    );

    Future<void> openDrawer(WidgetTester tester) async {
      final scaffoldState = tester.firstState<ScaffoldState>(
        find.byType(Scaffold),
      );
      scaffoldState.openDrawer();
      await tester.pumpAndSettle();
    }

    /// Scopes the given text finder to inside the open drawer, so account /
    /// mailbox names that also appear in the body of the underlying screen
    /// don't match.
    Finder textInDrawer(String text) => find.descendant(
          of: find.byType(AppDrawer),
          matching: find.text(text),
        );

    testWidgets('lists Combined Inbox above every account', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts',
          overrides: baseOverrides(
            accounts: [accountA, accountB],
            mailboxes: [inbox, sent],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await openDrawer(tester);

      final combinedY = tester.getCenter(textInDrawer('Combined Inbox')).dy;
      final aliceY = tester.getCenter(textInDrawer('Alice')).dy;
      final bobY = tester.getCenter(textInDrawer('Bob')).dy;

      expect(combinedY, lessThan(aliceY));
      expect(aliceY, lessThan(bobY));
    });

    testWidgets('global entries appear once below the account list', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts',
          overrides: baseOverrides(
            accounts: [accountA],
            mailboxes: [inbox],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await openDrawer(tester);

      // Flutter's widget tester treats off-screen widgets as not found. The
      // drawer is taller than the test viewport, so assert the upper entries
      // while they're visible, then scroll to reveal the lower ones.
      expect(textInDrawer('Manage accounts'), findsOneWidget);
      expect(textInDrawer('Add account'), findsOneWidget);
      expect(textInDrawer('Receive accounts'), findsOneWidget);

      await tester.drag(
        find.byType(AppDrawer),
        const Offset(0, -1000),
      );
      await tester.pumpAndSettle();

      expect(textInDrawer('Preferences'), findsOneWidget);
      expect(textInDrawer('Sent Queue'), findsOneWidget);
      expect(textInDrawer('Undo Log'), findsOneWidget);
      expect(textInDrawer('ChangeLog'), findsOneWidget);
      expect(textInDrawer('About'), findsOneWidget);
    });

    testWidgets('expanding an account reveals its folder tree', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts',
          overrides: baseOverrides(
            accounts: [accountA, accountB],
            mailboxes: [inbox, sent],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await openDrawer(tester);

      // Neither account is expanded by default on the manage-accounts screen.
      expect(textInDrawer('INBOX'), findsNothing);

      final expandIcon = find
          .descendant(
            of: find.ancestor(
              of: textInDrawer('Alice'),
              matching: find.byType(ListTile),
            ),
            matching: find.byIcon(Icons.expand_more),
          )
          .first;
      await tester.tap(expandIcon);
      await tester.pumpAndSettle();

      expect(textInDrawer('INBOX'), findsOneWidget);
      expect(textInDrawer('Sent'), findsOneWidget);
    });

    testWidgets('tapping a mailbox navigates to its email list',
        (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes',
          overrides: baseOverrides(
            accounts: [accountA],
            mailboxes: [inbox],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await openDrawer(tester);

      await tester.tap(textInDrawer('INBOX'));
      await tester.pumpAndSettle();

      // EmailListScreen renders "No emails" for an empty fake email repo.
      expect(find.text('No emails'), findsOneWidget);
    });

    testWidgets('tapping the account row opens the account home screen', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts',
          overrides: baseOverrides(
            accounts: [accountA],
            mailboxes: [inbox],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await openDrawer(tester);

      await tester.tap(textInDrawer('Alice'));
      await tester.pumpAndSettle();

      // Account home renders the per-account action list.
      expect(find.text('Folders'), findsOneWidget);
      expect(find.text('Sync log'), findsOneWidget);
    });
  });
}
