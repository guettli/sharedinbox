import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/di.dart';

import 'helpers.dart';

/// The Compose action never silently resumes a draft: with drafts saved it
/// asks whether to open one or create a new message (#1047).
void main() {
  const otherAccount = Account(
    id: 'acc-2',
    displayName: 'Bob',
    email: 'bob@example.com',
    imapHost: 'imap.example.com',
    smtpHost: 'smtp.example.com',
  );

  List<Override> overrides(FakeDraftRepository drafts) => [
        accountRepositoryProvider.overrideWithValue(
          FakeAccountRepository([kTestAccount, otherAccount]),
        ),
        mailboxRepositoryProvider.overrideWithValue(FakeMailboxRepository()),
        emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
        draftRepositoryProvider.overrideWithValue(drafts),
      ];

  Future<FakeDraftRepository> seededDrafts() async {
    final drafts = FakeDraftRepository();
    await drafts.saveDraft(
      accountId: kTestAccount.id,
      toText: 'carol@example.com',
      ccText: '',
      subjectText: 'Old draft',
      bodyText: 'Draft body',
    );
    return drafts;
  }

  Future<void> tapCompose(
    WidgetTester tester,
    FakeDraftRepository drafts,
  ) async {
    await tester.pumpWidget(
      buildApp(initialLocation: '/inbox', overrides: overrides(drafts)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
  }

  group('Compose action (#1047)', () {
    testWidgets('opens a blank compose directly when no draft exists', (
      tester,
    ) async {
      await tapCompose(tester, FakeDraftRepository());

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Subject'), findsOneWidget);
    });

    testWidgets('lists the draft with account, To and Subject', (
      tester,
    ) async {
      await tapCompose(tester, await seededDrafts());

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Old draft'), findsOneWidget);
      expect(
        find.textContaining('From: Alice <alice@example.com>'),
        findsOneWidget,
      );
      expect(find.textContaining('To: carol@example.com'), findsOneWidget);
      expect(find.text('Open draft'), findsOneWidget);
      expect(find.text('Create new message'), findsOneWidget);
    });

    testWidgets('"Create new message" opens a blank compose', (tester) async {
      await tapCompose(tester, await seededDrafts());

      await tester.tap(find.text('Create new message'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Subject'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Old draft'), findsNothing);
      expect(
        find.widgetWithText(TextFormField, 'carol@example.com'),
        findsNothing,
      );
    });

    testWidgets('"Open draft" resumes the chosen draft', (tester) async {
      final drafts = await seededDrafts();
      await drafts.saveDraft(
        accountId: otherAccount.id,
        toText: 'dave@example.com',
        ccText: '',
        subjectText: 'Other draft',
        bodyText: '',
      );
      await tapCompose(tester, drafts);

      expect(find.text('You have 2 unsent drafts'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.ancestor(
            of: find.text('Old draft'),
            matching: find.byType(ListTile),
          ),
          matching: find.text('Open draft'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.widgetWithText(TextFormField, 'Old draft'), findsOneWidget);
      expect(
        find.widgetWithText(TextFormField, 'carol@example.com'),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextFormField, 'Other draft'), findsNothing);
    });

    testWidgets("an account inbox only offers that account's drafts", (
      tester,
    ) async {
      final drafts = FakeDraftRepository();
      await drafts.saveDraft(
        accountId: otherAccount.id,
        toText: 'dave@example.com',
        ccText: '',
        subjectText: 'Other draft',
        bodyText: '',
      );
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails',
          overrides: overrides(drafts),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Compose'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Subject'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Other draft'), findsNothing);
    });
  });
}
