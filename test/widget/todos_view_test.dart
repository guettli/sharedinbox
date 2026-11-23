import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/entry.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/core/services/encrypted_key_service.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/widgets/journal_view.dart';

import 'entries_fakes.dart';
import 'helpers.dart';

final _bob = kTestAccount.copyWith(id: 'acc-2', email: 'bob@example.com');

/// Opens the Todos tab of the entries home of acc-1 on 2026-11-23.
Future<FakeEntryRepository> _pump(
  WidgetTester tester, {
  List<Entry> entries = const [],
  List<Account> accounts = const [kTestAccount],
  Map<String, PersonalDataStatus> status = const {},
  String? defaultAccount,
}) async {
  final repo = FakeEntryRepository(entries);
  await tester.pumpWidget(
    buildApp(
      initialLocation: '/accounts/acc-1/entries',
      userPreferences: FakeUserPreferencesRepository(
        personalDataBeta: true,
        defaultItemsAccountId: defaultAccount,
      ),
      overrides: [
        ...baseOverrides(accounts: accounts),
        encryptedKeyServiceProvider.overrideWithValue(
          FixedStatusKeyService(
            PersonalDataStatus.unlocked,
            byAccount: status,
          ),
        ),
        entryRepositoryProvider.overrideWithValue(repo),
        mailObjectStoreProvider.overrideWithValue(FakeConflictStore({})),
        todayProvider.overrideWithValue(() => DateTime(2026, 11, 23, 9)),
      ],
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('entriesTab_todos')));
  await tester.pumpAndSettle();
  return repo;
}

List<Entry> _todos() => [
      testEntry('note', body: 'Just a note', minute: 5),
      testEntry(
        'overdue',
        body: 'Pay the bill',
        task: const EntryTask(due: '2026-11-20'),
        minute: 1,
      ),
      testEntry(
        'today',
        body: 'Call Bob',
        task: const EntryTask(due: '2026-11-23'),
        minute: 2,
      ),
      testEntry(
        'later',
        body: 'Book flights',
        task: const EntryTask(due: '2026-12-01'),
        minute: 3,
      ),
      testEntry('nodue', body: 'Read a book', task: const EntryTask()),
      testEntry(
        'done',
        body: 'Buy milk',
        task: const EntryTask(done: true),
        minute: 4,
      ),
    ];

void main() {
  testWidgets('the entries home has the Notes, Todos and Journal tabs',
      (tester) async {
    await _pump(tester);
    for (final key in ['notes', 'todos', 'journal']) {
      expect(find.byKey(Key('entriesTab_$key')), findsOneWidget);
    }
    await tester.tap(find.byKey(const Key('entriesTab_journal')));
    await tester.pumpAndSettle();
    expect(find.byType(JournalView), findsOneWidget);
  });

  testWidgets('the filters show open, due today or overdue, and done todos',
      (tester) async {
    await _pump(tester, entries: _todos());
    // Open is the default; a note without a task is never a todo.
    for (final t in [
      'Pay the bill',
      'Call Bob',
      'Book flights',
      'Read a book',
    ]) {
      expect(find.text(t), findsOneWidget);
    }
    expect(find.text('Buy milk'), findsNothing);
    expect(find.text('Just a note'), findsNothing);
    // Overdue shows in red.
    final overdue =
        tester.widget<Text>(find.byKey(const Key('todoDue_overdue')));
    final today = tester.widget<Text>(find.byKey(const Key('todoDue_today')));
    expect(overdue.style?.color, isNotNull);
    expect(today.style?.color, isNull);

    await tester.tap(find.byKey(const Key('todosFilter_today')));
    await tester.pumpAndSettle();
    expect(find.text('Pay the bill'), findsOneWidget);
    expect(find.text('Call Bob'), findsOneWidget);
    expect(find.text('Book flights'), findsNothing);
    expect(find.text('Read a book'), findsNothing);
    expect(find.text('Buy milk'), findsNothing);

    await tester.tap(find.byKey(const Key('todosFilter_done')));
    await tester.pumpAndSettle();
    expect(find.text('Buy milk'), findsOneWidget);
    expect(find.text('Call Bob'), findsNothing);
  });

  testWidgets('empty filters say so', (tester) async {
    await _pump(tester);
    expect(find.text('No open todos.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('todosFilter_today')));
    await tester.pumpAndSettle();
    expect(find.text('Nothing due today.'), findsOneWidget);
  });

  testWidgets('the tick marks a todo done and it leaves the open list',
      (tester) async {
    final repo = await _pump(tester, entries: _todos());
    await tester.tap(find.byKey(const Key('todoTick_today')));
    await tester.pumpAndSettle();
    final update = repo.taskUpdates.single;
    expect(update.itemId, 'today');
    expect(update.task!.done, isTrue);
    expect(update.task!.due, '2026-11-23');
    expect(find.text('Call Bob'), findsNothing);

    await tester.tap(find.byKey(const Key('todosFilter_done')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('todoTick_done')));
    await tester.pumpAndSettle();
    expect(repo.taskUpdates.last.task!.done, isFalse);
    expect(find.text('Buy milk'), findsNothing);
  });

  testWidgets('quick add creates an open todo in the open account',
      (tester) async {
    final repo = await _pump(tester);
    await tester.enterText(find.byKey(const Key('todosQuickAdd')), 'Fix bike');
    await tester.tap(find.byKey(const Key('todosQuickAddSend')));
    await tester.pumpAndSettle();
    expect(repo.createdIn, ['acc-1']);
    final todo = repo.entries.single;
    expect(todo.body, 'Fix bike');
    expect(todo.task!.done, isFalse);
    expect(find.text('Fix bike'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('todosQuickAdd')))
          .controller!
          .text,
      isEmpty,
    );
  });

  testWidgets('quick add goes to the default account for new items',
      (tester) async {
    final repo = await _pump(
      tester,
      accounts: [kTestAccount, _bob],
      defaultAccount: 'acc-2',
    );
    await tester.enterText(find.byKey(const Key('todosQuickAdd')), 'Fix bike');
    await tester.tap(find.byKey(const Key('todosQuickAddSend')));
    await tester.pumpAndSettle();
    expect(repo.createdIn, ['acc-2']);
    // Several unlocked accounts: the row names its account.
    expect(find.byKey(const Key('todoAccount_new-0')), findsOneWidget);
    expect(find.text('bob@example.com'), findsOneWidget);
  });

  testWidgets('a locked default account falls back to the open one',
      (tester) async {
    final repo = await _pump(
      tester,
      accounts: [kTestAccount, _bob],
      status: {'acc-2': PersonalDataStatus.locked},
      defaultAccount: 'acc-2',
    );
    await tester.enterText(find.byKey(const Key('todosQuickAdd')), 'Fix bike');
    await tester.tap(find.byKey(const Key('todosQuickAddSend')));
    await tester.pumpAndSettle();
    expect(repo.createdIn, ['acc-1']);
    // Only one unlocked account: no account chip.
    expect(find.byKey(const Key('todoAccount_new-0')), findsNothing);
  });

  testWidgets('quick add while locked keeps the text and says so',
      (tester) async {
    final repo = await _pump(tester);
    repo.failCreateWith = const NoWriteKeyException('personal');
    await tester.enterText(find.byKey(const Key('todosQuickAdd')), 'Fix bike');
    await tester.tap(find.byKey(const Key('todosQuickAddSend')));
    await tester.pumpAndSettle();
    expect(find.text('Unlock personal data to add todos.'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('todosQuickAdd')))
          .controller!
          .text,
      'Fix bike',
    );
    expect(repo.entries, isEmpty);
  });

  testWidgets('todos of every unlocked account are listed', (tester) async {
    await _pump(
      tester,
      accounts: [kTestAccount, _bob],
      entries: [
        testEntry('a', body: 'Alice todo', task: const EntryTask()),
        testEntry(
          'b',
          body: 'Bob todo',
          task: const EntryTask(),
          accountId: 'acc-2',
        ),
      ],
    );
    expect(find.text('Alice todo'), findsOneWidget);
    expect(find.text('Bob todo'), findsOneWidget);
    expect(find.byKey(const Key('todoAccount_a')), findsOneWidget);
    expect(find.byKey(const Key('todoAccount_b')), findsOneWidget);
  });

  testWidgets('tapping a todo opens it', (tester) async {
    await _pump(tester, entries: _todos());
    await tester.tap(find.text('Call Bob'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('entryEditTitle')), findsOneWidget);
    expect(find.byKey(const Key('entryTodoSwitch')), findsOneWidget);
  });
}
