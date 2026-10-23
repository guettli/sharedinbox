import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/di.dart';

import 'helpers.dart';

/// Mailboxes kept per account, like the real repository: the old fake matched
/// a role across all accounts, which hid that one account's new Archive
/// folder must not satisfy another account's lookup.
class _PerAccountMailboxRepository extends FakeMailboxRepository {
  final List<Mailbox> created = [];

  @override
  Future<Mailbox?> findMailboxByRole(String accountId, String role) async =>
      created
          .where((m) => m.accountId == accountId && m.role == role)
          .firstOrNull;

  @override
  Future<Mailbox> createMailboxWithRole(
    String accountId,
    String name,
    String role, {
    String? parentDisplayPath,
  }) async {
    final mailbox = Mailbox(
      id: '$accountId:$name',
      accountId: accountId,
      path: '$accountId-$name',
      name: name,
      displayPath: name,
      role: role,
      unreadCount: 0,
      totalCount: 0,
    );
    created.add(mailbox);
    return mailbox;
  }
}

/// Combined-inbox source whose rows leave the inbox once moved, so the test
/// sees the list change while later prompts are still open.
class _MovingEmailRepository extends FakeEmailRepository {
  _MovingEmailRepository(this._emails) : super(emails: _emails);

  final List<Email> _emails;
  final Map<String, String> moves = {};
  final _changed = StreamController<void>.broadcast();

  List<EmailThread> _inbox() => [
        for (final e in _emails)
          if (!moves.containsKey(e.id))
            EmailThread(
              threadId: e.id,
              subject: e.subject,
              participants: e.from,
              latestDate: e.receivedAt,
              messageCount: 1,
              hasUnread: true,
              isFlagged: false,
              latestEmailId: e.id,
              emailIds: [e.id],
              accountId: e.accountId,
              mailboxPath: e.mailboxPath,
            ),
      ];

  @override
  Stream<List<EmailThread>> observeAllInboxThreads({int limit = 50}) async* {
    yield _inbox();
    yield* _changed.stream.map((_) => _inbox());
  }

  @override
  Future<void> moveEmail(String emailId, String destMailboxPath) async {
    moves[emailId] = destMailboxPath;
    _changed.add(null);
  }
}

const _bob = Account(
  id: 'bob',
  displayName: 'Bob',
  email: 'bob@example.com',
  imapHost: 'localhost',
  smtpHost: 'localhost',
);

const _alice = Account(
  id: 'alice',
  displayName: 'Alice',
  email: 'alice@example.com',
  type: AccountType.jmap,
  jmapUrl: 'http://localhost:8080/.well-known/jmap',
);

void main() {
  late _PerAccountMailboxRepository mailboxes;
  late _MovingEmailRepository emails;

  // Selects Bob's and Alice's inbox mail in the Combined Inbox and taps the
  // selection bar's Archive. Neither account has an archive folder.
  Future<void> archiveBoth(WidgetTester tester) async {
    mailboxes = _PerAccountMailboxRepository();
    emails = _MovingEmailRepository([
      testEmail(id: 'bob:1', accountId: 'bob', subject: 'Team sync'),
      testEmail(id: 'alice:1', accountId: 'alice', subject: 'For Alice B'),
    ]);
    await tester.pumpWidget(
      buildApp(
        initialLocation: '/inbox',
        overrides: [
          accountRepositoryProvider.overrideWithValue(
            FakeAccountRepository([_bob, _alice]),
          ),
          mailboxRepositoryProvider.overrideWithValue(mailboxes),
          emailRepositoryProvider.overrideWithValue(emails),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Team sync'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('For Alice B'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.archive));
    await tester.pumpAndSettle();
  }

  Future<void> answer(WidgetTester tester, String button) async {
    await tester.tap(find.text(button));
    await tester.pumpAndSettle();
  }

  testWidgets('prompts once per account and archives both', (tester) async {
    await archiveBoth(tester);

    expect(find.text('No archive folder for bob@example.com'), findsOneWidget);
    // Nothing moves before the user has decided.
    expect(find.text('For Alice B', skipOffstage: false), findsOneWidget);
    expect(find.text('Team sync', skipOffstage: false), findsOneWidget);
    await answer(tester, 'Create "Archive"');

    expect(
      find.text('No archive folder for alice@example.com'),
      findsOneWidget,
    );
    await answer(tester, 'Create "Archive"');

    expect(mailboxes.created.map((m) => m.accountId), ['bob', 'alice']);
    expect(emails.moves, {
      'bob:1': 'bob-Archive',
      'alice:1': 'alice-Archive',
    });
    expect(find.text('Team sync'), findsNothing);
    expect(find.text('For Alice B'), findsNothing);
  });

  testWidgets('Cancel for one account leaves its mail in place', (
    tester,
  ) async {
    await archiveBoth(tester);

    await answer(tester, 'Create "Archive"');
    expect(
      find.text('No archive folder for alice@example.com'),
      findsOneWidget,
    );
    await answer(tester, 'Cancel');

    expect(mailboxes.created.map((m) => m.accountId), ['bob']);
    expect(emails.moves, {'bob:1': 'bob-Archive'});
    expect(find.text('Team sync'), findsNothing);
    expect(find.text('For Alice B'), findsOneWidget);
  });
}
