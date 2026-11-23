import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/email.dart';
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
  bool beta = true,
  String? messageId = '<inv@x>',
}) async {
  final repo = FakeEntryRepository();
  final email =
      testEmail(id: 'acc-2:42', accountId: 'acc-2', subject: 'Invoice')
          .copyWith(messageId: messageId);
  await tester.pumpWidget(
    buildApp(
      initialLocation: _url,
      userPreferences: FakeUserPreferencesRepository(personalDataBeta: beta),
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
        encryptedKeyServiceProvider.overrideWithValue(
          FixedStatusKeyService(PersonalDataStatus.unlocked),
        ),
        // A mail with a Message-ID shows its notes; no Drift stream here.
        conversationNotesProvider.overrideWith((ref, key) => Stream.value([])),
        entryRepositoryProvider.overrideWithValue(repo),
        mailObjectStoreProvider.overrideWithValue(FakeConflictStore({})),
      ],
    ),
  );
  await tester.pumpAndSettle();
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

  testWidgets('a locked account asks to unlock', (tester) async {
    final repo = await _openMenu(tester);
    repo.failCreateWith = const NoWriteKeyException('personal');
    await tester.tap(find.byKey(const Key('emailCreateTodo')));
    await tester.pumpAndSettle();
    expect(repo.entries, isEmpty);
    expect(find.text('Unlock personal data to add todos.'), findsOneWidget);
  });

  testWidgets('hidden without the beta switch', (tester) async {
    await _openMenu(tester, beta: false);
    expect(find.byKey(const Key('emailCreateTodo')), findsNothing);
  });

  testWidgets('hidden for a mail without a Message-ID', (tester) async {
    await _openMenu(tester, messageId: null);
    expect(find.byKey(const Key('emailCreateTodo')), findsNothing);
  });
}
