import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/di.dart';

import 'helpers.dart';

// Fixed-date emails so golden files don't change day to day.
final _kDate = DateTime(2024, 6);

Email _email({
  String id = 'acc-1:1',
  String subject = 'Hello world',
  bool isSeen = true,
  bool isFlagged = false,
}) =>
    Email(
      id: id,
      accountId: 'acc-1',
      mailboxPath: 'INBOX',
      uid: int.parse(id.split(':').last),
      subject: subject,
      receivedAt: _kDate,
      sentAt: _kDate,
      from: const [EmailAddress(name: 'Bob', email: 'bob@example.com')],
      to: const [EmailAddress(email: 'alice@example.com')],
      cc: const [],
      isSeen: isSeen,
      isFlagged: isFlagged,
      hasAttachment: false,
    );

List<Override> _overrides({
  List<Email> emails = const [],
  List<Email> searchResults = const [],
  String? syncError,
}) =>
    [
      accountRepositoryProvider.overrideWithValue(
        FakeAccountRepository([kTestAccount]),
      ),
      mailboxRepositoryProvider.overrideWithValue(
        FakeMailboxRepository([kTestMailbox]),
      ),
      emailRepositoryProvider.overrideWithValue(
        FakeEmailRepository(emails: emails, searchResults: searchResults),
      ),
      draftRepositoryProvider.overrideWithValue(FakeDraftRepository()),
      searchHistoryRepositoryProvider.overrideWithValue(
        FakeSearchHistoryRepository(),
      ),
      syncLastErrorProvider.overrideWith((ref, _) => Stream.value(syncError)),
    ];

void main() {
  group('EmailListScreen goldens', () {
    testWidgets('golden: empty state', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
          overrides: _overrides(),
        ),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/email_list_empty.png'),
      );
    });

    testWidgets('golden: list with emails', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
          overrides: _overrides(
            emails: [
              _email(subject: 'Team standup notes', isSeen: false),
              _email(id: 'acc-1:2', subject: 'Q3 review', isFlagged: true),
              _email(id: 'acc-1:3', subject: 'Welcome to the project'),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/email_list_with_emails.png'),
      );
    });

    testWidgets('golden: selection mode', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
          overrides: _overrides(
            emails: [
              _email(subject: 'Team standup notes', isSeen: false),
              _email(id: 'acc-1:2', subject: 'Q3 review'),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Team standup notes'));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/email_list_selection.png'),
      );
    });

    testWidgets('golden: search with results', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
          overrides: _overrides(
            searchResults: [_email(id: 'acc-1:5', subject: 'Project proposal')],
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(SearchBar), 'project');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/email_list_search_results.png'),
      );
    });

    testWidgets('golden: error banner', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
          overrides: _overrides(syncError: 'Connection refused'),
        ),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/email_list_error_banner.png'),
      );
    });
  });
}
