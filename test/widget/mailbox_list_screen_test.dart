import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/di.dart';

import 'helpers.dart';

void main() {
  group('MailboxListScreen', () {
    testWidgets('shows mailbox name', (tester) async {
      await tester.pumpWidget(buildApp(
        initialLocation: '/accounts/acc-1/mailboxes',
        overrides: [
          accountRepositoryProvider
              .overrideWithValue(FakeAccountRepository([kTestAccount])),
          mailboxRepositoryProvider
              .overrideWithValue(FakeMailboxRepository([kTestMailbox])),
          emailRepositoryProvider
              .overrideWithValue(FakeEmailRepository()),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.text('INBOX'), findsWidgets);
    });

    testWidgets('shows unread badge when unreadCount > 0', (tester) async {
      await tester.pumpWidget(buildApp(
        initialLocation: '/accounts/acc-1/mailboxes',
        overrides: [
          accountRepositoryProvider
              .overrideWithValue(FakeAccountRepository([kTestAccount])),
          mailboxRepositoryProvider
              .overrideWithValue(FakeMailboxRepository([kTestMailbox])),
          emailRepositoryProvider
              .overrideWithValue(FakeEmailRepository()),
        ],
      ));
      await tester.pumpAndSettle();

      // kTestMailbox has unreadCount = 3
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('shows no badge when unreadCount is zero', (tester) async {
      const emptyMailbox = Mailbox(
        id: 'acc-1:Sent',
        accountId: 'acc-1',
        path: 'Sent',
        name: 'Sent',
        unreadCount: 0,
        totalCount: 5,
      );
      await tester.pumpWidget(buildApp(
        initialLocation: '/accounts/acc-1/mailboxes',
        overrides: [
          accountRepositoryProvider
              .overrideWithValue(FakeAccountRepository([kTestAccount])),
          mailboxRepositoryProvider
              .overrideWithValue(FakeMailboxRepository([emptyMailbox])),
          emailRepositoryProvider
              .overrideWithValue(FakeEmailRepository()),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.text('Sent'), findsOneWidget);
      expect(find.byType(Badge), findsNothing);
    });
  });
}
