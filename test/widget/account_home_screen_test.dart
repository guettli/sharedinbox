import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/data/db/database.dart' show SyncHealthRow;
import 'package:sharedinbox/ui/screens/account_list_screen.dart';

import 'helpers.dart';

/// Pumps [AccountHomeScreen] for [kTestAccount], backed by [mailboxes].
Future<void> _pumpAccountHome(
  WidgetTester tester,
  List<Mailbox> mailboxes, {
  AccountRepository? accounts,
  SyncHealthRow? syncHealth,
}) async {
  await tester.pumpWidget(
    buildApp(
      initialLocation: '/accounts/acc-1',
      overrides: baseOverrides(
        accounts: [kTestAccount],
        mailboxes: mailboxes,
        accountRepository: accounts,
        syncHealth: syncHealth,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Like the real repository, re-emits the account list after a removal, so
/// the screen sees its account disappear.
class _LiveAccountRepository extends FakeAccountRepository {
  _LiveAccountRepository(super.accounts);

  final _changes = StreamController<List<Account>>.broadcast();

  @override
  Stream<List<Account>> observeAccounts() async* {
    yield accounts;
    yield* _changes.stream;
  }

  @override
  Future<void> removeAccount(String id) async {
    await super.removeAccount(id);
    _changes.add(accounts);
  }
}

const _inbox = Mailbox(
  id: 'acc-1:INBOX',
  accountId: 'acc-1',
  path: 'INBOX',
  name: 'INBOX',
  unreadCount: 0,
  totalCount: 0,
  role: 'inbox',
);

void main() {
  group('AccountHomeScreen', () {
    testWidgets('shows an Inbox tile above the Folders tile', (tester) async {
      await _pumpAccountHome(tester, [_inbox]);

      final inboxTile = find.widgetWithText(ListTile, 'Inbox');
      final foldersTile = find.widgetWithText(ListTile, 'Folders');
      expect(inboxTile, findsOneWidget);
      expect(foldersTile, findsOneWidget);

      final inboxY = tester.getTopLeft(inboxTile).dy;
      final foldersY = tester.getTopLeft(foldersTile).dy;
      expect(inboxY, lessThan(foldersY));
    });

    testWidgets('deleting the account leaves its page for the account list', (
      tester,
    ) async {
      // Tall enough that the Delete tile at the end of the list is built.
      tester.view.physicalSize = const Size(1080, 4000);
      addTearDown(tester.view.reset);
      await _pumpAccountHome(
        tester,
        [_inbox],
        accounts: _LiveAccountRepository([kTestAccount]),
      );

      final delete = find.text('Delete account');
      await tester.tap(delete);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      // It used to stay here and say "Account not found".
      expect(find.text('Account not found'), findsNothing);
      expect(find.byType(AccountListScreen), findsOneWidget);
    });

    testWidgets('cancelling the deletion stays on the account', (tester) async {
      // Tall enough that the Delete tile at the end of the list is built.
      tester.view.physicalSize = const Size(1080, 4000);
      addTearDown(tester.view.reset);
      await _pumpAccountHome(tester, [_inbox]);

      final delete = find.text('Delete account');
      await tester.tap(delete);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.byType(AccountListScreen), findsNothing);
      expect(delete, findsOneWidget);
    });

    testWidgets('tapping Inbox opens the inbox mailbox email list', (
      tester,
    ) async {
      await _pumpAccountHome(tester, [_inbox]);

      await tester.tap(find.widgetWithText(ListTile, 'Inbox'));
      await tester.pumpAndSettle();

      // Landed on the (empty) email list for the inbox mailbox.
      expect(find.text('No emails'), findsOneWidget);
    });

    testWidgets('tapping Inbox with no synced inbox warns and opens Folders', (
      tester,
    ) async {
      await _pumpAccountHome(tester, const []);

      await tester.tap(find.widgetWithText(ListTile, 'Inbox'));
      await tester.pumpAndSettle();

      expect(find.textContaining('No inbox found yet'), findsOneWidget);
      // Fell back to the folder list screen.
      expect(find.text('Folders'), findsWidgets);
    });

    testWidgets('Verify sync health reports the result in a snackbar', (
      tester,
    ) async {
      await _pumpAccountHome(tester, [_inbox]);

      await tester.tap(find.text('Verify sync health'));
      // runAsync: the probe writes to and reads from the (real, in-memory)
      // database, which needs real async I/O.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pumpAndSettle();

      // It used to only say "Starting sync verification..." and never
      // report the outcome on this screen.
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text('Sync health: Healthy'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('Verify sync health tile shows the current status', (
      tester,
    ) async {
      await _pumpAccountHome(
        tester,
        [_inbox],
        syncHealth: SyncHealthRow(
          accountId: 'acc-1',
          lastVerifiedAt: DateTime(2024, 6),
          isHealthy: true,
        ),
      );

      final tile = find.widgetWithText(ListTile, 'Verify sync health');
      expect(
        find.descendant(of: tile, matching: find.textContaining('Healthy')),
        findsOneWidget,
      );
    });
  });
}
