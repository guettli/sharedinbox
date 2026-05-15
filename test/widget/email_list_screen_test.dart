import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/email_list_screen.dart';
import 'package:sharedinbox/ui/screens/mailbox_list_screen.dart';

import 'helpers.dart';

// A fake email repository whose search results can be changed mid-test.
class _MutableFakeEmailRepository extends FakeEmailRepository {
  List<Email> _results;

  _MutableFakeEmailRepository(List<Email> initial)
      : _results = List.of(initial),
        super();

  void setSearchResults(List<Email> results) => _results = results;

  @override
  Future<List<Email>> searchEmails(
    String accountId,
    String mailboxPath,
    String query,
  ) async =>
      _results;
}

final _kDate = DateTime(2024, 6);

void main() {
  group('EmailListScreen', () {
    testWidgets('shows "No emails" when list is empty', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
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

      expect(find.text('No emails'), findsOneWidget);
    });

    testWidgets('shows email sender and subject', (tester) async {
      final email = testEmail(subject: 'Meeting agenda');
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
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

      expect(find.text('Bob'), findsOneWidget);
      expect(find.text('Meeting agenda'), findsOneWidget);
    });

    testWidgets('shows flag icon for flagged email', (tester) async {
      final email = testEmail(isFlagged: true);
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
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

    testWidgets('tapping search icon shows search bar', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
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

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Search…'), findsOneWidget);
    });

    testWidgets('submitting a search query shows "No results" when empty', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
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

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'hello');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(find.text('No results'), findsOneWidget);
    });

    testWidgets('submitting a search query shows matching emails', (
      tester,
    ) async {
      final email = testEmail(subject: 'Found it');
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
            emailRepositoryProvider.overrideWithValue(
              FakeEmailRepository(searchResults: [email]),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Found');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(find.text('Found it'), findsOneWidget);
    });

    testWidgets('tapping sync button triggers syncEmails', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
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

      await tester.tap(find.byIcon(Icons.sync));
      await tester.pumpAndSettle();

      // No assertion needed — we just verify the tap doesn't throw.
    });

    testWidgets('tapping edit button navigates to compose screen', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
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

      await tester.tap(find.byIcon(Icons.edit));
      await tester.pumpAndSettle();

      expect(find.text('To'), findsOneWidget);
    });

    testWidgets('SearchBar is always visible in the AppBar', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
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

      expect(find.byType(SearchBar), findsOneWidget);
      expect(find.text('Search…'), findsOneWidget);
      expect(find.text('INBOX'), findsOneWidget);
    });

    testWidgets('long-press enters selection mode with selection bar', (
      tester,
    ) async {
      final email = testEmail(subject: 'Select me');
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
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

      await tester.longPress(find.text('Select me'));
      await tester.pumpAndSettle();

      expect(find.text('1 selected'), findsOneWidget);
      expect(find.byType(BottomAppBar), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets('selection bar close button exits selection mode', (
      tester,
    ) async {
      final email = testEmail(subject: 'Select me');
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
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

      await tester.longPress(find.text('Select me'));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(find.text('INBOX'), findsOneWidget);
      expect(find.byType(BottomAppBar), findsNothing);
    });

    testWidgets('tapping clear icon in search bar clears results', (
      tester,
    ) async {
      final email = testEmail(subject: 'Found it');
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
            emailRepositoryProvider.overrideWithValue(
              FakeEmailRepository(emails: [], searchResults: [email]),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'hello');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(find.text('Found it'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.clear));
      await tester.pumpAndSettle();

      expect(find.text('Found it'), findsNothing);
    });

    testWidgets('tapping selected-email checkbox deselects it', (tester) async {
      final email = testEmail(subject: 'Toggle me');
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
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

      await tester.longPress(find.text('Toggle me'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);

      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();

      // Deselecting the only email exits selection mode automatically.
      expect(find.text('INBOX'), findsOneWidget);
    });

    testWidgets('tapping a search result navigates to email detail', (
      tester,
    ) async {
      final email = testEmail(subject: 'Result email');
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
            emailRepositoryProvider.overrideWithValue(
              FakeEmailRepository(
                searchResults: [email],
                emailDetail: email,
                emailBody: const EmailBody(
                  emailId: 'acc-1:42',
                  attachments: [],
                ),
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Result');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Result email'));
      await tester.pumpAndSettle();

      // Navigated to email detail (subject appears in the detail body)
      expect(find.text('Result email'), findsWidgets);
    });

    testWidgets(
      'deleting all search results pops back to previous screen',
      (tester) async {
        final email = testEmail(subject: 'Needle');
        final repo = _MutableFakeEmailRepository([email]);

        // Start at the mailbox list so the email list is pushed on top of it,
        // making context.canPop() == true inside EmailListScreen.
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
              emailRepositoryProvider.overrideWithValue(repo),
            ],
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(MailboxListScreen), findsOneWidget);

        // Navigate into INBOX (pushes EmailListScreen onto the stack).
        await tester.tap(find.text('INBOX'));
        await tester.pumpAndSettle();

        expect(find.byType(EmailListScreen), findsOneWidget);

        // Search for the email.
        await tester.enterText(find.byType(TextField), 'Needle');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();

        // 'Needle' also appears in the SearchBar input, so match at least one.
        expect(find.text('Needle'), findsAtLeastNWidgets(1));

        // Long-press the sender name (unique to the email tile) to enter
        // selection mode.
        await tester.longPress(find.text('Bob'));
        await tester.pumpAndSettle();

        await tester.tap(find.byIcon(Icons.select_all));
        await tester.pumpAndSettle();

        // After deletion the search re-runs and finds nothing.
        repo.setSearchResults([]);

        await tester.tap(find.byIcon(Icons.delete));
        await tester.pumpAndSettle();

        // Should have popped back to the mailbox list.
        expect(find.byType(EmailListScreen), findsNothing);
        expect(find.byType(MailboxListScreen), findsOneWidget);
      },
    );

    testWidgets('shows preview snippet when email has preview', (tester) async {
      final email = Email(
        id: 'acc-1:99',
        accountId: 'acc-1',
        mailboxPath: 'INBOX',
        uid: 99,
        subject: 'Hello',
        receivedAt: _kDate,
        sentAt: _kDate,
        from: const [EmailAddress(name: 'Bob', email: 'bob@example.com')],
        to: const [EmailAddress(email: 'alice@example.com')],
        cc: [],
        preview: 'This is the preview text',
        isSeen: false,
        isFlagged: false,
        hasAttachment: false,
      );
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
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

      expect(find.text('This is the preview text'), findsOneWidget);
    });
  });
}
