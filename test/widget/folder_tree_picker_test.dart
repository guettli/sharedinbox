import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/ui/widgets/folder_tree_picker.dart';

Widget _harness(
  List<Mailbox> mailboxes,
  void Function(Future<String?>) capture, {
  String? initialPath,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (ctx) => ElevatedButton(
          onPressed: () {
            capture(
              showFolderTreePicker(
                ctx,
                mailboxes: mailboxes,
                initialPath: initialPath,
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
}

void main() {
  group('FolderTreePickerDialog', () {
    const mailboxes = [
      Mailbox(
        id: 'acc-1:INBOX',
        accountId: 'acc-1',
        path: 'INBOX',
        name: 'INBOX',
        unreadCount: 0,
        totalCount: 0,
        role: 'inbox',
      ),
      Mailbox(
        id: 'acc-1:INBOX/Work',
        accountId: 'acc-1',
        path: 'INBOX/Work',
        name: 'Work',
        unreadCount: 0,
        totalCount: 0,
      ),
      Mailbox(
        id: 'acc-1:INBOX/Work/Tasks',
        accountId: 'acc-1',
        path: 'INBOX/Work/Tasks',
        name: 'Tasks',
        unreadCount: 0,
        totalCount: 0,
      ),
      Mailbox(
        id: 'acc-1:Sent',
        accountId: 'acc-1',
        path: 'Sent',
        name: 'Sent',
        unreadCount: 0,
        totalCount: 0,
        role: 'sent',
      ),
    ];

    testWidgets('shows roots collapsed by default', (tester) async {
      late Future<String?> result;
      await tester.pumpWidget(_harness(mailboxes, (f) => result = f));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('INBOX'), findsOneWidget);
      expect(find.text('Sent'), findsOneWidget);
      // Children are collapsed.
      expect(find.text('Work'), findsNothing);
      expect(find.text('Tasks'), findsNothing);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await result, isNull);
    });

    testWidgets('expands a parent when its chevron is tapped', (tester) async {
      late Future<String?> result;
      await tester.pumpWidget(_harness(mailboxes, (f) => result = f));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.chevron_right).first);
      await tester.pumpAndSettle();

      expect(find.text('Work'), findsOneWidget);
      // Grandchild still hidden until "Work" is expanded.
      expect(find.text('Tasks'), findsNothing);

      await tester.tap(find.byIcon(Icons.chevron_right).first);
      await tester.pumpAndSettle();
      expect(find.text('Tasks'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await result, isNull);
    });

    testWidgets('returns the selected mailbox path', (tester) async {
      late Future<String?> result;
      await tester.pumpWidget(_harness(mailboxes, (f) => result = f));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sent'));
      await tester.pumpAndSettle();
      expect(await result, 'Sent');
    });

    testWidgets('returns null on cancel', (tester) async {
      late Future<String?> result;
      await tester.pumpWidget(_harness(mailboxes, (f) => result = f));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await result, isNull);
    });

    testWidgets('expands ancestors of initialPath so it is visible',
        (tester) async {
      late Future<String?> result;
      await tester.pumpWidget(
        _harness(
          mailboxes,
          (f) => result = f,
          initialPath: 'INBOX/Work/Tasks',
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Both ancestors should be open, so the leaf is rendered.
      expect(find.text('Work'), findsOneWidget);
      expect(find.text('Tasks'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await result, isNull);
    });

    testWidgets('tapping a non-leaf row toggles its expansion', (tester) async {
      // A path with intermediate components that don't exist as mailboxes
      // becomes a phantom parent. Tapping such a row should expand it (not
      // attempt to return a value).
      const phantom = [
        Mailbox(
          id: 'acc-1:A/B',
          accountId: 'acc-1',
          path: 'A/B',
          name: 'B',
          unreadCount: 0,
          totalCount: 0,
        ),
      ];
      late Future<String?> result;
      await tester.pumpWidget(_harness(phantom, (f) => result = f));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsNothing);

      await tester.tap(find.text('A'));
      await tester.pumpAndSettle();
      expect(find.text('B'), findsOneWidget);

      await tester.tap(find.text('B'));
      await tester.pumpAndSettle();
      expect(await result, 'A/B');
    });
  });
}
