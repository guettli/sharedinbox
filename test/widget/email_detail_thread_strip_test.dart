import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/di.dart';

import 'helpers.dart';

// The inline thread strip shown below the date in the mail detail view (#618):
// one small line per message in the thread, hidden when there is no thread,
// with the current mail highlighted and each other line tappable.
void main() {
  Email threadEmail({
    required String id,
    required String subject,
    required String fromEmail,
    required DateTime sentAt,
    String? threadId,
  }) =>
      Email(
        id: id,
        accountId: 'acc-1',
        mailboxPath: 'INBOX',
        uid: 1,
        subject: subject,
        receivedAt: sentAt,
        sentAt: sentAt,
        from: [EmailAddress(email: fromEmail)],
        to: const [EmailAddress(email: 'alice@example.com')],
        cc: const [],
        isSeen: true,
        isFlagged: false,
        hasAttachment: false,
        threadId: threadId,
      );

  const body = EmailBody(emailId: '', attachments: []);

  // Matches only [Text] widgets (not the inner RichText) so counts are exact.
  Finder textLine(String needle) => find.byWidgetPredicate(
        (w) => w is Text && (w.data ?? '').contains(needle),
      );

  Future<void> pumpWith(
    WidgetTester tester, {
    required List<Email> emails,
    required String openId,
  }) async {
    await tester.pumpWidget(
      buildApp(
        initialLocation:
            '/accounts/acc-1/mailboxes/INBOX/emails/${Uri.encodeComponent(openId)}',
        overrides: [
          accountRepositoryProvider.overrideWithValue(
            FakeAccountRepository([kTestAccount]),
          ),
          mailboxRepositoryProvider.overrideWithValue(FakeMailboxRepository()),
          emailRepositoryProvider.overrideWithValue(
            FakeEmailRepository(emails: emails, emailBody: body),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  group('EmailDetailScreen thread strip', () {
    testWidgets('is hidden when the mail is not part of a thread',
        (tester) async {
      final solo = threadEmail(
        id: 'acc-1:1',
        subject: 'Solo',
        fromEmail: 'bob@example.com',
        sentAt: DateTime(2024, 6, 1, 9),
        threadId: 'solo',
      );
      await pumpWith(tester, emails: [solo], openId: solo.id);

      expect(textLine('To me'), findsNothing);
      expect(textLine('From me'), findsNothing);
    });

    testWidgets('lists one line per message with direction and date',
        (tester) async {
      final incoming = threadEmail(
        id: 'acc-1:1',
        subject: 'Question',
        fromEmail: 'bob@example.com',
        sentAt: DateTime(2024, 6, 1, 9),
        threadId: 'thread-x',
      );
      final reply = threadEmail(
        id: 'acc-1:2',
        subject: 'Re: Question',
        fromEmail: 'alice@example.com',
        sentAt: DateTime(2024, 6, 2, 10),
        threadId: 'thread-x',
      );
      await pumpWith(tester, emails: [incoming, reply], openId: incoming.id);

      // Bob -> Alice is incoming, Alice (own address) -> Bob is outgoing.
      expect(textLine('To me'), findsOneWidget);
      expect(textLine('From me'), findsOneWidget);
      // Date is rendered without year (2024) and without seconds (:00 twice).
      final incomingLine = tester.widget<Text>(textLine('To me')).data!;
      expect(incomingLine, contains('Jun 1'));
      expect(incomingLine, isNot(contains('2024')));
      expect(incomingLine, isNot(contains(':00:')));
    });

    testWidgets('highlights the current mail in the list', (tester) async {
      final incoming = threadEmail(
        id: 'acc-1:1',
        subject: 'Question',
        fromEmail: 'bob@example.com',
        sentAt: DateTime(2024, 6, 1, 9),
        threadId: 'thread-x',
      );
      final reply = threadEmail(
        id: 'acc-1:2',
        subject: 'Re: Question',
        fromEmail: 'alice@example.com',
        sentAt: DateTime(2024, 6, 2, 10),
        threadId: 'thread-x',
      );
      await pumpWith(tester, emails: [incoming, reply], openId: incoming.id);

      final currentLine = tester.widget<Text>(textLine('To me'));
      final otherLine = tester.widget<Text>(textLine('From me'));
      expect(currentLine.style?.fontWeight, FontWeight.bold);
      expect(otherLine.style?.fontWeight, FontWeight.normal);
    });

    testWidgets('tapping another line opens that message', (tester) async {
      final incoming = threadEmail(
        id: 'acc-1:1',
        subject: 'Question',
        fromEmail: 'bob@example.com',
        sentAt: DateTime(2024, 6, 1, 9),
        threadId: 'thread-x',
      );
      final reply = threadEmail(
        id: 'acc-1:2',
        subject: 'Re: Question',
        fromEmail: 'alice@example.com',
        sentAt: DateTime(2024, 6, 2, 10),
        threadId: 'thread-x',
      );
      await pumpWith(tester, emails: [incoming, reply], openId: incoming.id);

      // Opening the incoming mail shows its subject in the header.
      expect(find.text('Question'), findsOneWidget);

      await tester.tap(textLine('From me'));
      await tester.pumpAndSettle();

      // The reply is now the open mail.
      expect(find.text('Re: Question'), findsOneWidget);
    });
  });
}
