import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/widgets/mailbox_count_label.dart';

import 'helpers.dart';

/// Builds a folder [Mailbox] from a `/`-joined [displayPath]. When [path] is
/// omitted it mirrors the display path (IMAP-style); pass an opaque [path] to
/// mimic a JMAP mailbox whose id differs from its human-readable tree.
Mailbox _folder(String displayPath, {String? path, int totalCount = 1}) {
  return Mailbox(
    id: 'acc-1:${path ?? displayPath}',
    accountId: 'acc-1',
    path: path ?? displayPath,
    name: displayPath.split('/').last,
    displayPath: displayPath,
    unreadCount: 0,
    totalCount: totalCount,
  );
}

/// Pumps [MailboxListScreen] and settles the frame. Backed by [repo] when
/// given (so the test can inspect its recorded calls), otherwise by a fresh
/// [FakeMailboxRepository] over [mailboxes].
Future<void> _pumpMailboxList(
  WidgetTester tester,
  List<Mailbox> mailboxes, {
  FakeMailboxRepository? repo,
}) async {
  await tester.pumpWidget(
    buildApp(
      initialLocation: '/accounts/acc-1/mailboxes',
      overrides: [
        accountRepositoryProvider.overrideWithValue(
          FakeAccountRepository([kTestAccount]),
        ),
        mailboxRepositoryProvider.overrideWithValue(
          repo ?? FakeMailboxRepository(mailboxes),
        ),
        emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
      ],
    ),
  );
  await tester.pumpAndSettle();
}

/// Long-presses [folder] to open its action sheet and taps "Delete".
Future<void> _tapDeleteAction(WidgetTester tester, String folder) async {
  await tester.longPress(find.text(folder).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Delete'));
  await tester.pumpAndSettle();
}

void main() {
  group('MailboxListScreen', () {
    testWidgets('shows mailbox name', (tester) async {
      await _pumpMailboxList(tester, [kTestMailbox]);

      expect(find.text('INBOX'), findsWidgets);
    });

    testWidgets('shows "unread / total" label when totalCount > 0', (
      tester,
    ) async {
      await _pumpMailboxList(tester, [kTestMailbox]);

      // kTestMailbox has unreadCount = 3, totalCount = 10.
      expect(find.text('3 / 10', findRichText: true), findsOneWidget);
    });

    testWidgets('shows the role label and role icon for a roled mailbox', (
      tester,
    ) async {
      const inbox = Mailbox(
        id: 'acc-1:INBOX',
        accountId: 'acc-1',
        path: 'INBOX',
        name: 'INBOX',
        unreadCount: 0,
        totalCount: 1,
        role: 'inbox',
      );
      await _pumpMailboxList(tester, [inbox]);

      expect(find.text('Inbox'), findsOneWidget);
      expect(find.byIcon(Icons.inbox), findsOneWidget);
      expect(find.byIcon(Icons.folder), findsNothing);
    });

    testWidgets(
        'shows the generic folder icon and no role label for a '
        'user-created mailbox', (tester) async {
      const custom = Mailbox(
        id: 'acc-1:Work',
        accountId: 'acc-1',
        path: 'Work',
        name: 'Work',
        unreadCount: 0,
        totalCount: 1,
      );
      await _pumpMailboxList(tester, [custom]);

      expect(find.byIcon(Icons.folder), findsOneWidget);
      expect(find.text('Work'), findsOneWidget);
      // No role sub-label for user folders.
      expect(find.text('Inbox'), findsNothing);
    });

    testWidgets('tapping a mailbox tile navigates to its email list', (
      tester,
    ) async {
      await _pumpMailboxList(tester, [kTestMailbox]);

      await tester.tap(find.text('INBOX').first);
      await tester.pumpAndSettle();

      expect(find.text('No emails'), findsOneWidget);
    });

    testWidgets(
      'shows "0 / total" label when unreadCount is zero but totalCount > 0',
      (tester) async {
        const mailbox = Mailbox(
          id: 'acc-1:Sent',
          accountId: 'acc-1',
          path: 'Sent',
          name: 'Sent',
          unreadCount: 0,
          totalCount: 5,
        );
        await _pumpMailboxList(tester, [mailbox]);

        expect(find.text('Sent'), findsOneWidget);
        expect(find.byType(Badge), findsNothing);
        expect(find.text('0 / 5', findRichText: true), findsOneWidget);
      },
    );

    testWidgets('long-press on a mailbox opens the folder actions sheet', (
      tester,
    ) async {
      await _pumpMailboxList(tester, [kTestMailbox]);

      await tester.longPress(find.text('INBOX').first);
      await tester.pumpAndSettle();

      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Move'), findsOneWidget);
      expect(find.text('Diagnose'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets(
      'choosing Diagnose navigates to the folder diagnostics screen',
      (tester) async {
        await _pumpMailboxList(tester, [kTestMailbox]);

        await tester.longPress(find.text('INBOX').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Diagnose'));
        await tester.pumpAndSettle();

        expect(find.text('Folder diagnostics'), findsOneWidget);
      },
    );

    testWidgets('choosing Delete → confirming calls repo.deleteMailbox', (
      tester,
    ) async {
      final repo = FakeMailboxRepository([kTestMailbox]);
      await _pumpMailboxList(tester, const [], repo: repo);

      await _tapDeleteAction(tester, 'INBOX');
      expect(find.text('Delete folder?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(repo.deleteCalls, ['INBOX']);
    });

    testWidgets(
      'delete confirmation shows the number of mails the folder contains',
      (tester) async {
        await _pumpMailboxList(tester, [_folder('Archive', totalCount: 3)]);

        await _tapDeleteAction(tester, 'Archive');

        expect(find.text('Delete folder?'), findsOneWidget);
        expect(find.textContaining('It contains 3 mails'), findsOneWidget);
      },
    );

    testWidgets('delete confirmation calls out an empty folder', (
      tester,
    ) async {
      await _pumpMailboxList(tester, [_folder('Archive', totalCount: 0)]);

      await _tapDeleteAction(tester, 'Archive');

      expect(find.textContaining('Delete the empty folder'), findsOneWidget);
    });

    testWidgets('deleting a folder with subfolders is blocked', (tester) async {
      final repo = FakeMailboxRepository([
        _folder('Archive'),
        _folder('Archive/2026'),
      ]);
      await _pumpMailboxList(tester, const [], repo: repo);

      await _tapDeleteAction(tester, 'Archive');

      expect(find.text('Delete subfolders first'), findsOneWidget);
      expect(find.text('Delete folder?'), findsNothing);

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(repo.deleteCalls, isEmpty);
    });

    testWidgets('choosing Rename → submitting calls repo.renameMailbox', (
      tester,
    ) async {
      final repo = FakeMailboxRepository([kTestMailbox]);
      await _pumpMailboxList(tester, const [], repo: repo);

      await tester.longPress(find.text('INBOX').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      expect(find.text('Rename folder'), findsOneWidget);

      await tester.enterText(find.byType(TextFormField), 'Renamed');
      await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
      await tester.pumpAndSettle();

      expect(repo.renameCalls, [(path: 'INBOX', newName: 'Renamed')]);
    });

    testWidgets('renders sub-folders indented deeper than their parent', (
      tester,
    ) async {
      await _pumpMailboxList(tester, [
        _folder('Archive/2026'),
        _folder('Archive'),
      ]);

      // Both rows show their leaf name.
      expect(find.text('Archive'), findsOneWidget);
      expect(find.text('2026'), findsOneWidget);

      double startIndent(String label) {
        final tile = tester.widget<ListTile>(
          find.ancestor(of: find.text(label), matching: find.byType(ListTile)),
        );
        return (tile.contentPadding! as EdgeInsetsDirectional).start;
      }

      // The child is indented one level deeper than its parent.
      expect(startIndent('2026'), greaterThan(startIndent('Archive')));
    });

    testWidgets('nested folder tap navigates via its real (opaque) path', (
      tester,
    ) async {
      // JMAP-style: path is an opaque id, displayPath is hierarchical.
      await _pumpMailboxList(tester, [
        _folder('Parent', path: 'a'),
        _folder('Parent/Child', path: 'b'),
      ]);

      await tester.tap(find.text('Child'));
      await tester.pumpAndSettle();

      // Navigated into an (empty) email list rather than staying on Folders.
      expect(find.text('No emails'), findsOneWidget);
    });

    testWidgets(
      'renders a non-tappable header for an inferred phantom parent',
      (tester) async {
        // Only the leaf exists as a real mailbox; "Archive" is inferred.
        await _pumpMailboxList(tester, [_folder('Archive/2026')]);

        expect(find.text('Archive'), findsOneWidget);
        expect(find.text('2026'), findsOneWidget);
        expect(find.byIcon(Icons.folder_open), findsOneWidget);

        // Tapping the phantom header does nothing (stays on Folders).
        await tester.tap(find.text('Archive'));
        await tester.pumpAndSettle();
        expect(find.text('Folders'), findsOneWidget);
      },
    );

    testWidgets(
      'failed-mutation banner links to the Pending Changes view (#622)',
      (tester) async {
        final emailRepo = FakeEmailRepository(
          failedMutations: [
            FailedMutation(
              id: 1,
              accountId: 'acc-1',
              changeType: 'move',
              resourceId: 'acc-1:42',
              lastError: 'server said no',
              attempts: 3,
              createdAt: DateTime.utc(2026, 3, 4, 9),
            ),
          ],
        );
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
              emailRepositoryProvider.overrideWithValue(emailRepo),
              syncNowProvider.overrideWithValue((_) => false),
            ],
          ),
        );
        await tester.pumpAndSettle();

        // The red banner surfaces the failed change and offers a View link.
        expect(find.text('1 pending move failed'), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'View'), findsOneWidget);

        await tester.tap(find.widgetWithText(TextButton, 'View'));
        await tester.pumpAndSettle();

        // Lands on the Pending Changes screen, where the details live.
        expect(find.text('Pending Changes'), findsOneWidget);
      },
    );

    testWidgets('shows a bare 0 when totalCount is zero', (tester) async {
      const emptyMailbox = Mailbox(
        id: 'acc-1:Empty',
        accountId: 'acc-1',
        path: 'Empty',
        name: 'Empty',
        unreadCount: 0,
        totalCount: 0,
      );
      await _pumpMailboxList(tester, [emptyMailbox]);

      expect(find.text('Empty'), findsOneWidget);
      // An empty folder shows "0" (not a blank), so it is distinct from a
      // folder whose count could not be computed (#498).
      final label = tester.widget<MailboxCountLabel>(
        find.byType(MailboxCountLabel),
      );
      expect(label.total, 0);
      expect(find.text('0'), findsOneWidget);
      expect(find.textContaining('/', findRichText: true), findsNothing);
    });
  });
}
