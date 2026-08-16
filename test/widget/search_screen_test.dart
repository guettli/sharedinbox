import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/search_screen.dart';

import 'helpers.dart';

/// Pumps [SearchScreen] at the account-scoped search route with the standard
/// fakes, letting a test supply just the history and (optionally) email
/// repositories.
Future<void> pumpSearchScreen(
  WidgetTester tester, {
  required FakeSearchHistoryRepository history,
  FakeEmailRepository? emails,
}) async {
  await tester.pumpWidget(
    buildApp(
      initialLocation: '/accounts/acc-1/search',
      overrides: [
        accountRepositoryProvider.overrideWithValue(
          FakeAccountRepository([kTestAccount]),
        ),
        mailboxRepositoryProvider.overrideWithValue(FakeMailboxRepository()),
        emailRepositoryProvider.overrideWithValue(
          emails ?? FakeEmailRepository(),
        ),
        searchHistoryRepositoryProvider.overrideWithValue(history),
      ],
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('SearchScreen', () {
    testWidgets('shows placeholder hint text when empty', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/search',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
            searchHistoryRepositoryProvider.overrideWithValue(
              FakeSearchHistoryRepository(),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Type 3+ characters to search'), findsOneWidget);
    });

    testWidgets('typing fewer than 3 characters does not trigger search', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/search',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
            searchHistoryRepositoryProvider.overrideWithValue(
              FakeSearchHistoryRepository(),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'hi');
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Type 3+ characters to search'), findsOneWidget);
      expect(find.text('No results'), findsNothing);
    });

    testWidgets('shows "No results" when search returns nothing', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/search',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
            searchHistoryRepositoryProvider.overrideWithValue(
              FakeSearchHistoryRepository(),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'xyz');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.text('No results'), findsOneWidget);
    });

    testWidgets('shows email results in the unified message list', (
      tester,
    ) async {
      final email = testEmail(subject: 'Invoice Q3');
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/search',
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
            searchHistoryRepositoryProvider.overrideWithValue(
              FakeSearchHistoryRepository(),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'inv');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.text('Invoice Q3'), findsOneWidget);
    });

    testWidgets(
      'merges searchEmailsGlobal + getEmailsByAddress into one message list, '
      'de-duplicated by id and with no folder/address sections',
      (tester) async {
        // `email_fts` covers subject/preview/from_json only. Recipient-side
        // matches (To/Cc) reach the UI only through getEmailsByAddress, so
        // the two streams must be merged. Overlap must appear once.
        final overlap = testEmail(id: 'acc-1:1', subject: 'Sender + recipient');
        final globalOnly = testEmail(id: 'acc-1:2', subject: 'From-side only');
        final addressOnly = testEmail(id: 'acc-1:3', subject: 'To-side only');
        await tester.pumpWidget(
          buildApp(
            initialLocation: '/accounts/acc-1/search',
            overrides: [
              accountRepositoryProvider.overrideWithValue(
                FakeAccountRepository([kTestAccount]),
              ),
              mailboxRepositoryProvider.overrideWithValue(
                FakeMailboxRepository(),
              ),
              emailRepositoryProvider.overrideWithValue(
                FakeEmailRepository(
                  searchResults: [overlap, globalOnly],
                  byAddressResults: [overlap, addressOnly],
                ),
              ),
              searchHistoryRepositoryProvider.overrideWithValue(
                FakeSearchHistoryRepository(),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextField), 'bob');
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();

        // Every match surfaces, including the address-only recipient hit.
        expect(find.text('Sender + recipient'), findsOneWidget);
        expect(find.text('From-side only'), findsOneWidget);
        expect(find.text('To-side only'), findsOneWidget);

        // No section headers — search now renders a single message list,
        // same as combined-inbox and folder views.
        expect(find.text('Folders'), findsNothing);
        expect(find.text('Addresses'), findsNothing);
        expect(find.text('Messages'), findsNothing);
      },
    );

    testWidgets('tapping clear button resets results to placeholder', (
      tester,
    ) async {
      final email = testEmail(subject: 'Found email');
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/search',
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
            searchHistoryRepositoryProvider.overrideWithValue(
              FakeSearchHistoryRepository(),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'found');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Found email'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.clear));
      await tester.pumpAndSettle();

      // Results are gone. The term was only typed (never submitted), so it is
      // not in history and the empty placeholder is shown instead of a chip.
      expect(find.text('Found email'), findsNothing);
      expect(find.text('found'), findsNothing);
      expect(find.text('Type 3+ characters to search'), findsOneWidget);
    });

    testWidgets('live-search typing does not add the term to history', (
      tester,
    ) async {
      // Regression for #560: typing "foob" on the way to "foobar" pauses long
      // enough to fire the live search, but the partial term must not be saved.
      final history = FakeSearchHistoryRepository();
      await pumpSearchScreen(
        tester,
        history: history,
        emails: FakeEmailRepository(
          searchResults: [testEmail(subject: 'Foobar mail')],
        ),
      );

      // Partial term: pause past the 300ms debounce so the live search runs.
      await tester.enterText(find.byType(TextField), 'foob');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Foobar mail'), findsOneWidget);

      // Continue typing the real term; it also runs as a live search.
      await tester.enterText(find.byType(TextField), 'foobar');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      // Nothing was submitted, so history stays empty — neither the partial
      // nor the full term was persisted.
      expect(await history.getRecentSearches(), isEmpty);
    });

    testWidgets('submitting the field adds the term to history', (
      tester,
    ) async {
      final history = FakeSearchHistoryRepository();
      await pumpSearchScreen(
        tester,
        history: history,
        emails: FakeEmailRepository(
          searchResults: [testEmail(subject: 'Foobar mail')],
        ),
      );

      await tester.enterText(find.byType(TextField), 'foobar');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(find.text('Foobar mail'), findsOneWidget);
      expect(await history.getRecentSearches(), ['foobar']);
    });
  });

  group('SearchScreen recent searches', () {
    testWidgets('shows seeded recent searches when input is empty', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/search',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
            searchHistoryRepositoryProvider.overrideWithValue(
              FakeSearchHistoryRepository(['alpha', 'beta']),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Recent searches'), findsOneWidget);
      expect(find.text('alpha'), findsOneWidget);
      expect(find.text('beta'), findsOneWidget);
    });

    testWidgets('tapping a recent-search chip re-runs the query', (
      tester,
    ) async {
      final email = testEmail(subject: 'Quarterly Report');
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/search',
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
            searchHistoryRepositoryProvider.overrideWithValue(
              FakeSearchHistoryRepository(['quarterly']),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('quarterly'));
      await tester.pumpAndSettle();

      expect(find.text('Quarterly Report'), findsOneWidget);
    });

    testWidgets('tapping the chip delete icon removes that entry', (
      tester,
    ) async {
      final history = FakeSearchHistoryRepository(['alpha', 'beta']);
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/search',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
            searchHistoryRepositoryProvider.overrideWithValue(history),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // The delete icon lives inside the InputChip for "alpha".
      final alphaChip = find.ancestor(
        of: find.text('alpha'),
        matching: find.byType(InputChip),
      );
      final deleteIcon = find.descendant(
        of: alphaChip,
        matching: find.byIcon(Icons.close),
      );
      expect(deleteIcon, findsOneWidget);

      await tester.tap(deleteIcon);
      await tester.pumpAndSettle();

      expect(find.text('alpha'), findsNothing);
      expect(find.text('beta'), findsOneWidget);
      expect(await history.getRecentSearches(), ['beta']);
    });

    testWidgets(
      'initialFilter opens advanced mode and auto-runs structured search',
      (tester) async {
        final hit = testEmail(subject: 'You won a prize!');
        final filter = FilterGroup(
          operator: FilterOperator.and_,
          children: [
            FilterLeaf(
              field: FilterField.from_,
              comparison: FilterComparison.is_,
              value: 'spam@bad.com',
            ),
          ],
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              accountRepositoryProvider.overrideWithValue(
                FakeAccountRepository([kTestAccount]),
              ),
              mailboxRepositoryProvider.overrideWithValue(
                FakeMailboxRepository(),
              ),
              emailRepositoryProvider.overrideWithValue(
                FakeEmailRepository(structuredSearchResults: [hit]),
              ),
              searchHistoryRepositoryProvider.overrideWithValue(
                FakeSearchHistoryRepository(),
              ),
            ],
            child: MaterialApp(
              home: SearchScreen(initialFilter: filter),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Advanced-mode AppBar title and result are visible.
        expect(find.text('Advanced Search'), findsOneWidget);
        expect(find.text('You won a prize!'), findsOneWidget);
      },
    );

    testWidgets(
      'advanced-search result location label shows JMAP folder display path, '
      'never the opaque server id',
      (tester) async {
        // Simulates a JMAP mailbox whose path is the opaque server id "a"
        // and whose displayPath is the human-readable "Archive/2026" — the
        // exact shape that regressed in #288 (the screenshot showed "a").
        const jmapMailbox = Mailbox(
          id: 'acc-1:a',
          accountId: 'acc-1',
          path: 'a',
          name: '2026',
          displayPath: 'Archive/2026',
          unreadCount: 0,
          totalCount: 1,
        );
        final hit = Email(
          id: 'acc-1:1',
          accountId: 'acc-1',
          mailboxPath: 'a',
          uid: 1,
          subject: 'Test message',
          receivedAt: DateTime(2024, 6),
          sentAt: DateTime(2024, 6),
          from: const [EmailAddress(name: 'Bob', email: 'bob@example.com')],
          to: const [EmailAddress(email: 'alice@example.com')],
          cc: const [],
          isSeen: false,
          isFlagged: false,
          hasAttachment: false,
        );
        final filter = FilterGroup(
          operator: FilterOperator.and_,
          children: [
            FilterLeaf(
              field: FilterField.from_,
              comparison: FilterComparison.is_,
              value: 'bob@example.com',
            ),
          ],
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              accountRepositoryProvider.overrideWithValue(
                FakeAccountRepository([kTestAccount]),
              ),
              mailboxRepositoryProvider.overrideWithValue(
                FakeMailboxRepository([jmapMailbox]),
              ),
              emailRepositoryProvider.overrideWithValue(
                FakeEmailRepository(structuredSearchResults: [hit]),
              ),
              searchHistoryRepositoryProvider.overrideWithValue(
                FakeSearchHistoryRepository(),
              ),
            ],
            child: MaterialApp(
              home: SearchScreen(initialFilter: filter),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // The location label must render the account's display name and the
        // human-readable folder display path — never the account id or the
        // opaque JMAP mailbox id.
        expect(find.text('Alice • Archive/2026'), findsOneWidget);
        expect(find.text('acc-1 • Archive/2026'), findsNothing);
        expect(find.text('acc-1 • a'), findsNothing);
      },
    );

    testWidgets(
      'long-press on advanced-search result enters selection mode with batch bar',
      (tester) async {
        final hit1 = testEmail(id: 'acc-1:1', subject: 'First similar mail');
        final hit2 = testEmail(id: 'acc-1:2', subject: 'Second similar mail');
        final filter = FilterGroup(
          operator: FilterOperator.and_,
          children: [
            FilterLeaf(
              field: FilterField.from_,
              comparison: FilterComparison.is_,
              value: 'bob@example.com',
            ),
          ],
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              accountRepositoryProvider.overrideWithValue(
                FakeAccountRepository([kTestAccount]),
              ),
              mailboxRepositoryProvider.overrideWithValue(
                FakeMailboxRepository(),
              ),
              emailRepositoryProvider.overrideWithValue(
                FakeEmailRepository(structuredSearchResults: [hit1, hit2]),
              ),
              searchHistoryRepositoryProvider.overrideWithValue(
                FakeSearchHistoryRepository(),
              ),
            ],
            child: MaterialApp(
              home: SearchScreen(initialFilter: filter),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('First similar mail'), findsOneWidget);
        expect(find.text('Second similar mail'), findsOneWidget);

        await tester.longPress(find.text('First similar mail'));
        await tester.pumpAndSettle();

        // Selection-mode AppBar and batch action BottomBar appear — same as
        // every other message list in the app.
        expect(find.text('1 selected'), findsOneWidget);
        expect(find.byIcon(Icons.select_all), findsOneWidget);
        expect(find.byIcon(Icons.archive), findsOneWidget);
        expect(find.byIcon(Icons.delete), findsOneWidget);
        expect(find.byIcon(Icons.report), findsOneWidget);
        expect(find.byIcon(Icons.drive_file_move), findsOneWidget);
        expect(find.byIcon(Icons.access_time), findsOneWidget);

        // "Select all" grows the selection to every visible result.
        await tester.tap(find.byIcon(Icons.select_all));
        await tester.pumpAndSettle();
        expect(find.text('2 selected'), findsOneWidget);

        // The "..." overflow surfaces the per-message debug entry point.
        expect(find.byTooltip('More actions'), findsOneWidget);
        await tester.tap(find.byTooltip('More actions'));
        await tester.pumpAndSettle();
        expect(find.text('Debug messages'), findsOneWidget);
      },
    );

    testWidgets(
      'folder condition uses a picker and filters by the picked mailbox path',
      (tester) async {
        // JMAP-shaped mailbox: opaque server path "a", human-readable
        // displayPath "Archive". The picker must show the display path to the
        // user but the resulting FilterLeaf must carry the raw path so it
        // matches `emails.mailbox_path` when the search runs.
        const jmapArchive = Mailbox(
          id: 'acc-1:a',
          accountId: 'acc-1',
          path: 'a',
          name: 'Archive',
          displayPath: 'Archive',
          unreadCount: 0,
          totalCount: 1,
        );
        final hit = testEmail(subject: 'Old invoice');
        final fakeEmails = FakeEmailRepository(structuredSearchResults: [hit]);
        await tester.pumpWidget(
          buildApp(
            initialLocation: '/accounts/acc-1/search',
            overrides: [
              accountRepositoryProvider.overrideWithValue(
                FakeAccountRepository([kTestAccount]),
              ),
              mailboxRepositoryProvider.overrideWithValue(
                FakeMailboxRepository([jmapArchive]),
              ),
              emailRepositoryProvider.overrideWithValue(fakeEmails),
              searchHistoryRepositoryProvider.overrideWithValue(
                FakeSearchHistoryRepository(),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        // Enter advanced mode and add one condition (default: From).
        await tester.tap(find.byIcon(Icons.tune));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add condition'));
        await tester.pumpAndSettle();

        // Switch the field dropdown from "From" to "Folder".
        await tester.tap(find.byType(DropdownButton<FilterField>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Folder').last);
        await tester.pumpAndSettle();

        // No text input and no comparison dropdown for Folder — just the
        // picker button with a "Select folder…" placeholder.
        expect(find.text('Select folder…'), findsOneWidget);
        expect(
          find.byType(DropdownButton<FilterComparison>),
          findsNothing,
        );

        // Tap the picker button, choose the JMAP-shaped mailbox by its
        // human-readable displayPath.
        await tester.tap(find.text('Select folder…'));
        await tester.pumpAndSettle();
        expect(find.text('Pick folder'), findsOneWidget);
        await tester.tap(find.text('Archive'));
        await tester.pumpAndSettle();

        // Picker dialog is gone; the button now reflects the folder's
        // displayPath (not the raw opaque JMAP id "a").
        expect(find.text('Pick folder'), findsNothing);
        expect(find.text('Archive'), findsOneWidget);

        // Run the search and verify the repository was called with a
        // FilterLeaf whose value is the mailbox's raw `path` ("a"), so the
        // LIKE against emails.mailbox_path matches on JMAP accounts.
        await tester.tap(find.widgetWithText(FilledButton, 'Search'));
        await tester.pumpAndSettle();

        expect(fakeEmails.structuredSearchCalls, hasLength(1));
        final children = fakeEmails.structuredSearchCalls.first.children;
        expect(children, hasLength(1));
        final leaf = children.first as FilterLeaf;
        expect(leaf.field, FilterField.folder);
        expect(leaf.comparison, FilterComparison.is_);
        expect(leaf.value, 'a');

        // Result flows through to the message list.
        expect(find.text('Old invoice'), findsOneWidget);
      },
    );

    testWidgets('tapping Clear empties the recent searches panel', (
      tester,
    ) async {
      final history = FakeSearchHistoryRepository(['alpha', 'beta']);
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/search',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(
              FakeMailboxRepository(),
            ),
            emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
            searchHistoryRepositoryProvider.overrideWithValue(history),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();

      expect(find.text('alpha'), findsNothing);
      expect(find.text('beta'), findsNothing);
      expect(find.text('Recent searches'), findsNothing);
      expect(find.text('Type 3+ characters to search'), findsOneWidget);
      expect(await history.getRecentSearches(), isEmpty);
    });
  });
}
