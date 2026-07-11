import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/ui/widgets/folder_tree_picker.dart';

Widget _harness(
  List<Mailbox> mailboxes,
  void Function(Future<String?>) capture, {
  String? initialPath,
  FolderCreateCallback? onCreate,
  Stream<List<Mailbox>>? stream,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (ctx) => ElevatedButton(
          onPressed: () {
            capture(
              showFolderTreePicker(
                ctx,
                mailboxesStream: stream ?? Stream.value(mailboxes),
                initialPath: initialPath,
                onCreate: onCreate,
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

    testWidgets(
      'JMAP: renders human-readable displayPath, not opaque server IDs',
      (tester) async {
        // JMAP: `path` is a one-char server ID (`a`, `b`, `c`); the tree must
        // render the hierarchical `displayPath` labels and return that on
        // selection — not the opaque IDs.
        const jmap = [
          Mailbox(
            id: 'j1:a',
            accountId: 'j1',
            path: 'a',
            name: 'Archive',
            displayPath: 'Archive',
            unreadCount: 0,
            totalCount: 0,
          ),
          Mailbox(
            id: 'j1:b',
            accountId: 'j1',
            path: 'b',
            name: '2026',
            displayPath: 'Archive/2026',
            parentId: 'a',
            unreadCount: 0,
            totalCount: 0,
          ),
          Mailbox(
            id: 'j1:c',
            accountId: 'j1',
            path: 'c',
            name: 'Q1',
            displayPath: 'Archive/2026/Q1',
            parentId: 'b',
            unreadCount: 0,
            totalCount: 0,
          ),
        ];
        late Future<String?> result;
        await tester.pumpWidget(_harness(jmap, (f) => result = f));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        // Only the root is visible initially, labelled by the mailbox name.
        expect(find.text('Archive'), findsOneWidget);
        expect(find.text('a'), findsNothing);
        expect(find.text('2026'), findsNothing);

        // Expand two levels.
        await tester.tap(find.byIcon(Icons.chevron_right).first);
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.chevron_right).first);
        await tester.pumpAndSettle();
        expect(find.text('Q1'), findsOneWidget);

        // Tapping the leaf returns the hierarchical displayPath, so the
        // Sieve script fileinto stores something readable.
        await tester.tap(find.text('Q1'));
        await tester.pumpAndSettle();
        expect(await result, 'Archive/2026/Q1');
      },
    );

    testWidgets(
      'JMAP: accepts legacy opaque path as initialPath',
      (tester) async {
        // Sieve scripts written before v47 stored the opaque JMAP ID
        // ("a") as the fileinto folder. Opening the picker with that legacy
        // value should still highlight the correct mailbox.
        const jmap = [
          Mailbox(
            id: 'j1:a',
            accountId: 'j1',
            path: 'a',
            name: 'Archive',
            displayPath: 'Archive',
            unreadCount: 0,
            totalCount: 0,
          ),
        ];
        late Future<String?> result;
        await tester.pumpWidget(
          _harness(jmap, (f) => result = f, initialPath: 'a'),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        expect(find.text('Archive'), findsOneWidget);
        // Never render the opaque ID as a label.
        expect(find.text('a'), findsNothing);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(await result, isNull);
      },
    );

    testWidgets(
      'no create affordance when onCreate is null',
      (tester) async {
        late Future<String?> result;
        await tester.pumpWidget(_harness(mailboxes, (f) => result = f));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        expect(find.text('New folder…'), findsNothing);
        expect(find.byIcon(Icons.create_new_folder_outlined), findsNothing);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(await result, isNull);
      },
    );

    testWidgets(
      'creates a top-level folder via the action-bar button',
      (tester) async {
        // Stream we drive by hand: emit the initial list, then after
        // onCreate is called emit the list plus the new folder, so the
        // picker rebuilds with the new node visible.
        final controller =
            StreamController<List<Mailbox>>.broadcast(sync: true);
        addTearDown(controller.close);
        final captured = <String?>[];

        late Future<String?> result;
        await tester.pumpWidget(
          _harness(
            mailboxes,
            (f) => result = f,
            stream: controller.stream,
            onCreate: ({required name, parentDisplayPath}) async {
              captured.add(parentDisplayPath);
              final created = Mailbox(
                id: 'acc-1:$name',
                accountId: 'acc-1',
                path: name,
                name: name,
                displayPath: name,
                unreadCount: 0,
                totalCount: 0,
              );
              controller.add([...mailboxes, created]);
              return created;
            },
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pump();
        // Broadcast stream: emit only after the picker has subscribed.
        controller.add(mailboxes);
        await tester.pumpAndSettle();

        await tester.tap(find.text('New folder…'));
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextFormField), 'Later');
        await tester.tap(find.text('Create'));
        await tester.pumpAndSettle();

        expect(captured, [null]);
        expect(await result, 'Later');
      },
    );

    testWidgets(
      'creates a subfolder via the trailing "+" icon on a row',
      (tester) async {
        final controller =
            StreamController<List<Mailbox>>.broadcast(sync: true);
        addTearDown(controller.close);
        final captured = <String?>[];

        late Future<String?> result;
        await tester.pumpWidget(
          _harness(
            mailboxes,
            (f) => result = f,
            stream: controller.stream,
            onCreate: ({required name, parentDisplayPath}) async {
              captured.add(parentDisplayPath);
              final displayPath =
                  parentDisplayPath == null ? name : '$parentDisplayPath/$name';
              final created = Mailbox(
                id: 'acc-1:$displayPath',
                accountId: 'acc-1',
                path: displayPath,
                name: name,
                displayPath: displayPath,
                unreadCount: 0,
                totalCount: 0,
              );
              controller.add([...mailboxes, created]);
              return created;
            },
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pump();
        // Broadcast stream: emit only after the picker has subscribed.
        controller.add(mailboxes);
        await tester.pumpAndSettle();

        // Each real row exposes a trailing IconButton with the folder-plus
        // icon; the action-bar's "New folder…" is a TextButton.icon so it
        // does not match `widgetWithIcon(IconButton, …)`. INBOX and Sent
        // are the two visible real rows and INBOX sorts first (inbox role).
        final rowPlusButtons = find.widgetWithIcon(
          IconButton,
          Icons.create_new_folder_outlined,
        );
        expect(rowPlusButtons, findsNWidgets(2));
        await tester.tap(rowPlusButtons.at(1)); // Sent's row
        await tester.pumpAndSettle();

        // Parent hint is shown.
        expect(find.text('Under: Sent'), findsOneWidget);
        await tester.enterText(find.byType(TextFormField), 'Archive');
        await tester.tap(find.text('Create'));
        await tester.pumpAndSettle();

        expect(captured, ['Sent']);
        expect(await result, 'Sent/Archive');
      },
    );

    testWidgets(
      'rejects an empty or duplicate name and keeps the create dialog open',
      (tester) async {
        late Future<String?> result;
        await tester.pumpWidget(
          _harness(
            mailboxes,
            (f) => result = f,
            onCreate: ({required name, parentDisplayPath}) async =>
                throw StateError('should not be called'),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('New folder…'));
        await tester.pumpAndSettle();

        // Empty → rejected.
        await tester.tap(find.text('Create'));
        await tester.pumpAndSettle();
        expect(find.text('Enter a name'), findsOneWidget);

        // Duplicate top-level → rejected.
        await tester.enterText(find.byType(TextFormField), 'INBOX');
        await tester.tap(find.text('Create'));
        await tester.pumpAndSettle();
        expect(
          find.text('A folder with this name already exists here'),
          findsOneWidget,
        );

        // Contains "/" → rejected.
        await tester.enterText(find.byType(TextFormField), 'foo/bar');
        await tester.tap(find.text('Create'));
        await tester.pumpAndSettle();
        expect(find.text('Name cannot contain "/"'), findsOneWidget);

        // Close the create dialog (its Cancel is on top of the picker's).
        await tester.tap(find.text('Cancel').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(await result, isNull);
      },
    );

    testWidgets(
      'shows a SnackBar and keeps the picker open when onCreate throws',
      (tester) async {
        late Future<String?> result;
        await tester.pumpWidget(
          _harness(
            mailboxes,
            (f) => result = f,
            onCreate: ({required name, parentDisplayPath}) async {
              throw Exception('offline');
            },
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('New folder…'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextFormField), 'Later');
        await tester.tap(find.text('Create'));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('Could not create folder'),
          findsOneWidget,
        );
        // Picker still visible so the user can retry or cancel.
        expect(find.text('Pick folder'), findsOneWidget);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(await result, isNull);
      },
    );

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
