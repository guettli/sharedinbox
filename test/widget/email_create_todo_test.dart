import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/entry.dart';
import 'package:sharedinbox/core/models/linked_note.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/core/services/encrypted_key_service.dart';
import 'package:sharedinbox/di.dart';

import 'entries_fakes.dart';
import 'helpers.dart';

const _url = '/accounts/acc-2/mailboxes/INBOX/emails/acc-2%3A42';

/// Opens mail acc-2:42 ("Invoice", Message-ID `<inv@x>` unless [messageId]
/// says otherwise) and its menu.
Future<FakeEntryRepository> _openMenu(
  WidgetTester tester, {
  String? messageId = '<inv@x>',
  List<Entry> entries = const [],
  List<LinkedNote> notes = const [],
  bool openMenu = true,
}) async {
  final repo = FakeEntryRepository(entries);
  final email =
      testEmail(id: 'acc-2:42', accountId: 'acc-2', subject: 'Invoice')
          .copyWith(messageId: messageId);
  await tester.pumpWidget(
    buildApp(
      keyService: FixedStatusKeyService(PersonalDataStatus.unlocked),
      initialLocation: _url,
      userPreferences: FakeUserPreferencesRepository(),
      overrides: [
        accountRepositoryProvider.overrideWithValue(
          FakeAccountRepository([
            kTestAccount,
            kTestAccount.copyWith(id: 'acc-2', email: 'bob@example.com'),
          ]),
        ),
        mailboxRepositoryProvider.overrideWithValue(FakeMailboxRepository()),
        emailRepositoryProvider.overrideWithValue(
          FakeEmailRepository(
            emailDetail: email,
            emailBody: const EmailBody(
              emailId: 'acc-2:42',
              textBody: 'Pay',
              attachments: [],
            ),
          ),
        ),
        // A mail with a Message-ID shows its notes; no Drift stream here.
        conversationNotesProvider
            .overrideWith((ref, key) => Stream.value(notes)),
        entryRepositoryProvider.overrideWithValue(repo),
        mailObjectStoreProvider.overrideWithValue(FakeConflictStore({})),
      ],
    ),
  );
  await tester.pumpAndSettle();
  if (!openMenu) return repo;
  await tester.tap(find.byType(PopupMenuButton<String>));
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  testWidgets('"Create todo" adds a todo in the mail\'s account, linked',
      (tester) async {
    final repo = await _openMenu(tester);
    await tester.tap(find.byKey(const Key('emailCreateTodo')));
    await tester.pumpAndSettle();

    expect(repo.createdIn, ['acc-2']);
    final todo = repo.entries.single;
    expect(todo.title, 'Invoice');
    expect(todo.body, isEmpty);
    expect(todo.links, ['<inv@x>']);
    expect(todo.task!.done, isFalse);
    expect(find.text('Todo created'), findsOneWidget);

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('entryTodoSwitch')), findsOneWidget);
  });

  testWidgets('a linked todo shows its tick and due date; ticking saves',
      (tester) async {
    const task = EntryTask(due: '2026-11-27');
    final repo = await _openMenu(
      tester,
      openMenu: false,
      entries: [
        testEntry('t1', title: 'Invoice', task: task, accountId: 'acc-2'),
      ],
      notes: [
        LinkedNote(
          id: 't1',
          accountId: 'acc-2',
          messageId: '<inv@x>',
          text: 'Invoice',
          createdAt: DateTime(2026, 11, 24, 9),
          isEntry: true,
          task: task,
        ),
      ],
    );
    expect(find.textContaining('due 2026-11-27'), findsOneWidget);
    final tick = find.byKey(const Key('noteTodoDone-t1'));
    expect(tester.widget<Checkbox>(tick).value, isFalse);

    await tester.tap(tick);
    await tester.pumpAndSettle();
    expect(repo.taskUpdates.single.itemId, 't1');
    expect(repo.taskUpdates.single.accountId, 'acc-2');
    expect(repo.taskUpdates.single.task!.done, isTrue);
    expect(repo.taskUpdates.single.task!.due, '2026-11-27');
  });

  testWidgets('a done linked todo is ticked and struck through; delete asks',
      (tester) async {
    await _openMenu(
      tester,
      openMenu: false,
      entries: [testEntry('t1', title: 'Invoice', accountId: 'acc-2')],
      notes: [
        LinkedNote(
          id: 't1',
          accountId: 'acc-2',
          messageId: '<inv@x>',
          text: 'Invoice',
          createdAt: DateTime(2026, 11, 24, 9),
          isEntry: true,
          task: const EntryTask(done: true),
        ),
      ],
    );
    final tick = find.byKey(const Key('noteTodoDone-t1'));
    expect(tester.widget<Checkbox>(tick).value, isTrue);
    final title = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('note-t1')),
        matching: find.text('Invoice'),
      ),
    );
    expect(title.style?.decoration, TextDecoration.lineThrough);
    await tester.tap(find.byTooltip('Delete note'));
    await tester.pumpAndSettle();
    expect(find.text('Delete todo?'), findsOneWidget);
  });

  testWidgets('a linked note that is no todo has no tick', (tester) async {
    await _openMenu(
      tester,
      openMenu: false,
      notes: [
        LinkedNote(
          id: 'n1',
          accountId: 'acc-2',
          messageId: '<inv@x>',
          text: 'Paid',
          createdAt: DateTime(2026, 11, 24, 9),
          isEntry: true,
        ),
      ],
    );
    expect(find.text('Paid'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('deleting a linked entry asks first; Cancel keeps it',
      (tester) async {
    final repo = await _openMenu(
      tester,
      openMenu: false,
      entries: [testEntry('n1', body: 'Paid', accountId: 'acc-2')],
      notes: [
        LinkedNote(
          id: 'n1',
          accountId: 'acc-2',
          messageId: '<inv@x>',
          text: 'Paid\nby card',
          createdAt: DateTime(2026, 11, 24, 9),
          isEntry: true,
        ),
      ],
    );
    await tester.tap(find.byTooltip('Delete note'));
    await tester.pumpAndSettle();
    expect(find.text('Delete note?'), findsOneWidget);
    expect(find.text('Delete "Paid"?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(repo.entries, hasLength(1));

    await tester.tap(find.byTooltip('Delete note'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('noteDeleteConfirm')));
    await tester.pumpAndSettle();
    expect(repo.entries, isEmpty);
  });

  testWidgets('a locked account asks to unlock', (tester) async {
    final repo = await _openMenu(tester);
    repo.failCreateWith = const NoWriteKeyException('personal');
    await tester.tap(find.byKey(const Key('emailCreateTodo')));
    await tester.pumpAndSettle();
    expect(repo.entries, isEmpty);
    expect(find.text('Unlock personal data to add todos.'), findsOneWidget);
  });

  testWidgets('hidden for a mail without a Message-ID', (tester) async {
    await _openMenu(tester, messageId: null);
    expect(find.byKey(const Key('emailCreateTodo')), findsNothing);
  });
}
