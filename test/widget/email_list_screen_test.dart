import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/email_detail_screen.dart';
import 'package:sharedinbox/ui/screens/email_list_screen.dart';
import 'package:sharedinbox/ui/screens/mailbox_list_screen.dart';

import 'helpers.dart';

// A fake email repository whose search results can be changed mid-test.
class _MutableFakeEmailRepository extends FakeEmailRepository {
  List<Email> _results;

  _MutableFakeEmailRepository(
    List<Email> initial, {
    super.emailDetail,
    super.emailBody,
  }) : _results = List.of(initial);

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
      expect(find.byIcon(Icons.close), findsNothing);
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
      'tapping first of multiple search results opens the first email',
      (tester) async {
        final email1 = testEmail(id: 'acc-1:1', subject: 'Alpha Match');
        final email2 = testEmail(id: 'acc-1:2', subject: 'Beta Match');
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
                  searchResults: [email1, email2],
                  emailBody: const EmailBody(emailId: '', attachments: []),
                ),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextField), 'Match');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();

        expect(find.text('Alpha Match'), findsOneWidget);
        expect(find.text('Beta Match'), findsOneWidget);

        // Tap the first result.
        await tester.tap(find.text('Alpha Match'));
        await tester.pumpAndSettle();

        expect(find.byType(EmailDetailScreen), findsOneWidget);
        // The detail AppBar title shows the first email's subject.
        expect(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.text('Alpha Match'),
          ),
          findsOneWidget,
        );
        // The second email's subject must not appear in the detail view.
        expect(
          find.descendant(
            of: find.byType(EmailDetailScreen),
            matching: find.text('Beta Match'),
          ),
          findsNothing,
        );
      },
    );

    testWidgets(
      'stale search results from a slower concurrent search are discarded',
      (tester) async {
        // Reproduces: user types quickly, triggering multiple concurrent IMAP
        // searches. An older, slower search must not overwrite the results for
        // the user's current query (issue #467).
        final staleEmail = testEmail(id: 'acc-1:1', subject: 'Stale Result');
        final freshEmail = testEmail(id: 'acc-1:2', subject: 'Fresh Result');

        // The first search call is held open by a Completer; all subsequent
        // calls resolve immediately with freshEmail.
        final staleCompleter = Completer<List<Email>>();
        var firstCall = true;

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
                  onSearch: (_) {
                    if (firstCall) {
                      firstCall = false;
                      return staleCompleter.future;
                    }
                    return Future.value([freshEmail]);
                  },
                  emailBody: const EmailBody(emailId: '', attachments: []),
                ),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        // Trigger the first (slow) search.
        await tester.enterText(find.byType(TextField), 'slow');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        // Do not pumpAndSettle yet — the slow search is still in flight.

        // Trigger the second (fast) search by changing the query.
        await tester.enterText(find.byType(TextField), 'fast');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle(); // fast searches settle immediately

        // The fresh results must be shown.
        expect(find.text('Fresh Result'), findsOneWidget);
        expect(find.text('Stale Result'), findsNothing);

        // Now let the stale search complete.
        staleCompleter.complete([staleEmail]);
        await tester.pumpAndSettle();

        // The stale results must NOT replace the fresh ones.
        expect(find.text('Fresh Result'), findsOneWidget);
        expect(find.text('Stale Result'), findsNothing);
      },
    );

    testWidgets(
      'pressing Enter on already-settled search does not re-run search (issue #473)',
      (tester) async {
        final email1 = testEmail(id: 'acc-1:1', subject: 'Alpha Match');
        final email2 = testEmail(id: 'acc-1:2', subject: 'Beta Match');

        var searchCallCount = 0;

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
                  onSearch: (_) async {
                    searchCallCount++;
                    return [email1, email2];
                  },
                  emailBody: const EmailBody(emailId: '', attachments: []),
                ),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        // Run the initial search.
        await tester.enterText(find.byType(TextField), 'Match');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();

        expect(find.text('Alpha Match'), findsOneWidget);
        expect(find.text('Beta Match'), findsOneWidget);

        final countAfterFirstSearch = searchCallCount;

        // Re-focus the search bar (simulates user tapping back into the field
        // with the keyboard still visible) and press Enter again on the same,
        // already-settled query.
        await tester.tap(find.byType(TextField));
        await tester.pump();
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();

        // The search must NOT re-run; call count must not increase.
        expect(
          searchCallCount,
          countAfterFirstSearch,
          reason:
              'Enter on settled results must not re-run the search (issue #473)',
        );
        // Results must still be visible — no loading spinner.
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.text('Alpha Match'), findsOneWidget);
      },
    );

    testWidgets('deleting all search results pops back to previous screen', (
      tester,
    ) async {
      final email = testEmail(subject: 'Needle');

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
            emailRepositoryProvider.overrideWithValue(
              FakeEmailRepository(searchResults: [email]),
            ),
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

      await tester.tap(find.byIcon(Icons.delete));
      await tester.pumpAndSettle();

      // Should have popped back to the mailbox list.
      expect(find.byType(EmailListScreen), findsNothing);
      expect(find.byType(MailboxListScreen), findsOneWidget);
    });

    testWidgets(
      'deleting some search results updates the list without popping',
      (tester) async {
        final email1 = testEmail(subject: 'Needle One');
        final email2 = testEmail(subject: 'Needle Two', id: 'acc-1:2');

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
              emailRepositoryProvider.overrideWithValue(
                FakeEmailRepository(searchResults: [email1, email2]),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('INBOX'));
        await tester.pumpAndSettle();

        // Search returns both emails.
        await tester.enterText(find.byType(TextField), 'Needle');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();

        expect(find.text('Needle One'), findsOneWidget);
        expect(find.text('Needle Two'), findsOneWidget);

        // Select only the first email and delete it.
        await tester.longPress(find.text('Needle One'));
        await tester.pumpAndSettle();

        await tester.tap(find.byIcon(Icons.delete));
        await tester.pumpAndSettle();

        // EmailListScreen stays open but the deleted email is gone.
        expect(find.byType(EmailListScreen), findsOneWidget);
        expect(find.text('Needle One'), findsNothing);
        expect(find.text('Needle Two'), findsOneWidget);
      },
    );

    testWidgets(
      'opening and deleting a single search result pops back to previous screen',
      (tester) async {
        final email = testEmail(subject: 'Needle');
        final repo = _MutableFakeEmailRepository(
          [email],
          emailDetail: email,
          emailBody: const EmailBody(emailId: 'acc-1:42', attachments: []),
        );

        // Start at the mailbox list so context.canPop() is true in EmailListScreen.
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

        // Navigate into INBOX.
        await tester.tap(find.text('INBOX'));
        await tester.pumpAndSettle();

        expect(find.byType(EmailListScreen), findsOneWidget);

        // Search for the email.
        await tester.enterText(find.byType(TextField), 'Needle');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();

        // Tap the email to open it in EmailDetailScreen (not long-press / selection).
        await tester.tap(find.text('Bob'));
        await tester.pumpAndSettle();

        expect(find.byType(EmailDetailScreen), findsOneWidget);

        // The search will return empty results after the email is deleted.
        repo.setSearchResults([]);

        // Delete the email from the detail screen.
        await tester.tap(find.byIcon(Icons.delete));
        await tester.pumpAndSettle();
        await tester.pump();
        await tester.pumpAndSettle();

        // Should have popped all the way back to the mailbox list.
        expect(find.byType(EmailDetailScreen), findsNothing);
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

    group('archive with missing folder', () {
      testWidgets('shows dialog when archive folder is not found', (
        tester,
      ) async {
        final email = testEmail(subject: 'To archive');
        await tester.pumpWidget(
          buildApp(
            initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
            overrides: [
              accountRepositoryProvider.overrideWithValue(
                FakeAccountRepository([kTestAccount]),
              ),
              // No archive folder in the repo.
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

        // Enter selection mode and tap archive.
        await tester.longPress(find.text('To archive'));
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.archive));
        await tester.pumpAndSettle();

        expect(find.text('No archive folder found'), findsOneWidget);
        expect(find.text('Choose existing folder'), findsOneWidget);
        expect(find.text('Create "Archive"'), findsOneWidget);
      });

      testWidgets('tapping Create creates the folder and moves emails', (
        tester,
      ) async {
        final email = testEmail(subject: 'To archive');
        final movedTo = <String>[];

        final fakeEmailRepo = _SpyEmailRepository(
          emails: [email],
          onMove: (id, path) => movedTo.add(path),
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
              emailRepositoryProvider.overrideWithValue(fakeEmailRepo),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.longPress(find.text('To archive'));
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.archive));
        await tester.pumpAndSettle();

        // Tap "Create Archive".
        await tester.tap(find.text('Create "Archive"'));
        await tester.pumpAndSettle();

        expect(movedTo, contains('Archive'));
      });

      testWidgets(
        'tapping Choose existing opens folder picker and moves emails',
        (tester) async {
          final email = testEmail(subject: 'To archive');
          final movedTo = <String>[];

          final fakeEmailRepo = _SpyEmailRepository(
            emails: [email],
            onMove: (id, path) => movedTo.add(path),
          );
          const archiveFolder = Mailbox(
            id: 'acc-1:OldArchive',
            accountId: 'acc-1',
            path: 'OldArchive',
            name: 'OldArchive',
            unreadCount: 0,
            totalCount: 0,
          );

          await tester.pumpWidget(
            buildApp(
              initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
              overrides: [
                accountRepositoryProvider.overrideWithValue(
                  FakeAccountRepository([kTestAccount]),
                ),
                // Repo has a folder but it has no 'archive' role.
                mailboxRepositoryProvider.overrideWithValue(
                  FakeMailboxRepository([archiveFolder]),
                ),
                emailRepositoryProvider.overrideWithValue(fakeEmailRepo),
              ],
            ),
          );
          await tester.pumpAndSettle();

          await tester.longPress(find.text('To archive'));
          await tester.pumpAndSettle();
          await tester.tap(find.byIcon(Icons.archive));
          await tester.pumpAndSettle();

          // Tap "Choose existing folder".
          await tester.tap(find.text('Choose existing folder'));
          await tester.pumpAndSettle();

          // Bottom sheet with folder list appears.
          expect(find.text('OldArchive'), findsOneWidget);

          await tester.tap(find.text('OldArchive'));
          await tester.pumpAndSettle();

          expect(movedTo, contains('OldArchive'));
        },
      );
    });
  });
}

/// Email repository spy that records [moveEmail] calls.
class _SpyEmailRepository extends FakeEmailRepository {
  _SpyEmailRepository({
    super.emails,
    required void Function(String emailId, String path) onMove,
  }) : _onMove = onMove;

  final void Function(String emailId, String path) _onMove;

  @override
  Future<void> moveEmail(String emailId, String destMailboxPath) async {
    _onMove(emailId, destMailboxPath);
  }
}
