import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/mailbox.dart';

import 'helpers.dart';

/// Pumps [AccountHomeScreen] for [kTestAccount], backed by [mailboxes].
Future<void> _pumpAccountHome(
  WidgetTester tester,
  List<Mailbox> mailboxes,
) async {
  await tester.pumpWidget(
    buildApp(
      initialLocation: '/accounts/acc-1',
      overrides: baseOverrides(accounts: [kTestAccount], mailboxes: mailboxes),
    ),
  );
  await tester.pumpAndSettle();
}

const _inbox = Mailbox(
  id: 'acc-1:INBOX',
  accountId: 'acc-1',
  path: 'INBOX',
  name: 'INBOX',
  unreadCount: 0,
  totalCount: 0,
  role: 'inbox',
);

void main() {
  group('AccountHomeScreen', () {
    testWidgets('shows an Inbox tile above the Folders tile', (tester) async {
      await _pumpAccountHome(tester, [_inbox]);

      final inboxTile = find.widgetWithText(ListTile, 'Inbox');
      final foldersTile = find.widgetWithText(ListTile, 'Folders');
      expect(inboxTile, findsOneWidget);
      expect(foldersTile, findsOneWidget);

      final inboxY = tester.getTopLeft(inboxTile).dy;
      final foldersY = tester.getTopLeft(foldersTile).dy;
      expect(inboxY, lessThan(foldersY));
    });

    testWidgets('tapping Inbox opens the inbox mailbox email list', (
      tester,
    ) async {
      await _pumpAccountHome(tester, [_inbox]);

      await tester.tap(find.widgetWithText(ListTile, 'Inbox'));
      await tester.pumpAndSettle();

      // Landed on the (empty) email list for the inbox mailbox.
      expect(find.text('No emails'), findsOneWidget);
    });

    testWidgets(
      'tapping Inbox with no synced inbox warns and opens Folders',
      (tester) async {
        await _pumpAccountHome(tester, const []);

        await tester.tap(find.widgetWithText(ListTile, 'Inbox'));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('No inbox found yet'),
          findsOneWidget,
        );
        // Fell back to the folder list screen.
        expect(find.text('Folders'), findsWidgets);
      },
    );
  });
}
