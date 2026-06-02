import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/user_preferences.dart';
import 'package:sharedinbox/di.dart';

import 'helpers.dart';

Email _threadEmail({
  String id = 'acc-1:10',
  bool isFlagged = false,
  bool isSeen = true,
}) => Email(
  id: id,
  accountId: 'acc-1',
  mailboxPath: 'INBOX',
  uid: 10,
  threadId: 'thread-1',
  subject: 'Project update',
  receivedAt: DateTime(2024, 6),
  sentAt: DateTime(2024, 6, 1, 9),
  from: const [EmailAddress(name: 'Bob', email: 'bob@example.com')],
  to: const [EmailAddress(email: 'alice@example.com')],
  cc: const [],
  isSeen: isSeen,
  isFlagged: isFlagged,
  hasAttachment: false,
);

void main() {
  group('ThreadDetailScreen', () {
    testWidgets('shows "Thread not found or empty" when thread is empty', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/threads/thread-1',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Thread not found or empty'), findsOneWidget);
    });

    testWidgets('shows sender name for email in thread', (tester) async {
      final email = _threadEmail();
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/threads/thread-1',
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

      expect(find.textContaining('Bob'), findsOneWidget);
    });

    testWidgets('last email in thread is expanded by default', (tester) async {
      final email = _threadEmail();
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/threads/thread-1',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
            emailRepositoryProvider.overrideWithValue(
              FakeEmailRepository(
                emails: [email],
                emailBody: const EmailBody(
                  emailId: 'acc-1:10',
                  textBody: 'Hello body text',
                  attachments: [],
                ),
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // Reply and delete buttons are visible for the expanded card.
      expect(find.byIcon(Icons.reply), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    });

    testWidgets('tapping an expanded card collapses it', (tester) async {
      final email = _threadEmail();
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/threads/thread-1',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
            emailRepositoryProvider.overrideWithValue(
              FakeEmailRepository(
                emails: [email],
                emailBody: const EmailBody(
                  emailId: 'acc-1:10',
                  textBody: 'Hello body text',
                  attachments: [],
                ),
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // Tap the expand_less icon to collapse.
      await tester.tap(find.byIcon(Icons.expand_less));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.reply), findsNothing);
      expect(find.byIcon(Icons.expand_more), findsOneWidget);
    });

    testWidgets('shows bottom app bar with back button by default', (
      tester,
    ) async {
      final email = _threadEmail();
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/threads/thread-1',
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

      expect(find.byType(BottomAppBar), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    });

    testWidgets('hides bottom app bar when button position is top', (
      tester,
    ) async {
      final email = _threadEmail();
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/threads/thread-1',
          userPreferences: FakeUserPreferencesRepository(
            mailViewButtonPosition: MenuPosition.top,
          ),
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

      expect(find.byType(BottomAppBar), findsNothing);
    });

    testWidgets('flagged email shows star icon', (tester) async {
      final email = _threadEmail(isFlagged: true);
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/threads/thread-1',
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

      expect(find.byIcon(Icons.star), findsOneWidget);
    });

    testWidgets('expanded card shows plain text body', (tester) async {
      final email = _threadEmail();
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/threads/thread-1',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
            emailRepositoryProvider.overrideWithValue(
              FakeEmailRepository(
                emails: [email],
                emailBody: const EmailBody(
                  emailId: 'acc-1:10',
                  textBody: 'Body content here',
                  attachments: [],
                ),
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Body content here'), findsOneWidget);
    });
  });
}
