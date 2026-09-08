import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/email_detail_nav.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/conversation_tree.dart';

import 'helpers.dart';

// The cross-folder reply tree (#754): messages of one conversation gathered
// across folders, nested under the message they answer, each tagged with its
// folder and tappable to open.
void main() {
  Email mail({
    required String id,
    required String fromEmail,
    required DateTime sentAt,
    String mailboxPath = 'INBOX',
    String? messageId,
    String? inReplyTo,
  }) =>
      Email(
        id: id,
        accountId: 'acc-1',
        mailboxPath: mailboxPath,
        uid: 1,
        subject: 'Subject',
        receivedAt: sentAt,
        sentAt: sentAt,
        from: [EmailAddress(email: fromEmail)],
        to: const [EmailAddress(email: 'alice@example.com')],
        cc: const [],
        isSeen: true,
        isFlagged: false,
        hasAttachment: false,
        threadId: 'thread-x',
        messageId: messageId,
        inReplyTo: inReplyTo,
      );

  final incoming = mail(
    id: 'acc-1:1',
    fromEmail: 'bob@example.com',
    sentAt: DateTime(2024, 6, 1, 9),
    messageId: 'msg-a',
  );
  final reply = mail(
    id: 'acc-1:2',
    fromEmail: 'alice@example.com',
    sentAt: DateTime(2024, 6, 2, 10),
    mailboxPath: 'Sent',
    messageId: 'msg-b',
    inReplyTo: 'msg-a',
  );

  final mailboxes = [
    const Mailbox(
      id: 'acc-1:INBOX',
      accountId: 'acc-1',
      path: 'INBOX',
      name: 'Inbox',
      displayPath: 'Inbox',
      unreadCount: 0,
      totalCount: 0,
      role: 'inbox',
    ),
    const Mailbox(
      id: 'acc-1:Sent',
      accountId: 'acc-1',
      path: 'Sent',
      name: 'Sent',
      displayPath: 'Sent',
      unreadCount: 0,
      totalCount: 0,
      role: 'sent',
    ),
  ];

  Finder textLine(String needle) => find.byWidgetPredicate(
        (w) => w is Text && (w.data ?? '').contains(needle),
      );

  Future<EmailDetailNavItem?> pumpTree(
    WidgetTester tester, {
    required List<Email> emails,
    required Email open,
  }) async {
    EmailDetailNavItem? tapped;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountRepositoryProvider
              .overrideWithValue(FakeAccountRepository([kTestAccount])),
          mailboxRepositoryProvider
              .overrideWithValue(FakeMailboxRepository(mailboxes)),
          emailRepositoryProvider
              .overrideWithValue(FakeEmailRepository(emails: emails)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ConversationTree(
              email: open,
              onTapEmail: (item) => tapped = item,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tapped;
  }

  testWidgets('hidden when the conversation has a single message',
      (tester) async {
    await pumpTree(tester, emails: [incoming], open: incoming);
    expect(textLine('To me'), findsNothing);
    expect(textLine('From me'), findsNothing);
  });

  testWidgets('lists one line per message with direction and date',
      (tester) async {
    await pumpTree(tester, emails: [incoming, reply], open: incoming);

    expect(textLine('To me'), findsOneWidget);
    expect(textLine('From me'), findsOneWidget);
    final incomingLine = tester.widget<Text>(textLine('To me')).data!;
    expect(incomingLine, contains('Jun 1'));
    expect(incomingLine, isNot(contains('2024')));
  });

  testWidgets('tags each message with its folder', (tester) async {
    await pumpTree(tester, emails: [incoming, reply], open: incoming);
    expect(textLine('Sent'), findsOneWidget);
    expect(textLine('Inbox'), findsOneWidget);
  });

  testWidgets('nests the reply under the message it answers', (tester) async {
    await pumpTree(tester, emails: [incoming, reply], open: incoming);

    double lineIndent(String needle) => tester
        .widgetList<Padding>(
          find.ancestor(of: textLine(needle), matching: find.byType(Padding)),
        )
        .map((p) => p.padding as EdgeInsets)
        .firstWhere((e) => e.top == AppSpacing.xs && e.bottom == AppSpacing.xs)
        .left;

    expect(lineIndent('To me'), 0);
    expect(lineIndent('From me'), AppSpacing.md);
  });

  testWidgets('highlights the open message', (tester) async {
    await pumpTree(tester, emails: [incoming, reply], open: incoming);

    final currentLine = tester.widget<Text>(textLine('To me'));
    final otherLine = tester.widget<Text>(textLine('From me'));
    expect(currentLine.style?.fontWeight, FontWeight.bold);
    expect(otherLine.style?.fontWeight, FontWeight.normal);
  });

  testWidgets('tapping another message reports it to the callback',
      (tester) async {
    EmailDetailNavItem? tapped;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountRepositoryProvider
              .overrideWithValue(FakeAccountRepository([kTestAccount])),
          mailboxRepositoryProvider
              .overrideWithValue(FakeMailboxRepository(mailboxes)),
          emailRepositoryProvider.overrideWithValue(
            FakeEmailRepository(emails: [incoming, reply]),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ConversationTree(
              email: incoming,
              onTapEmail: (item) => tapped = item,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(textLine('From me'));
    expect(tapped?.emailId, reply.id);
    expect(tapped?.mailboxPath, 'Sent');
  });
}
