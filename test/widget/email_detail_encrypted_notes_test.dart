// The notes of a mail on an encrypted account (#1375): entries linked to
// the mail show next to the legacy notes not migrated yet, a migration
// neither blinks nor doubles a note, a locked device adds no note, an
// unlocked one adds an entry.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/encrypted_objects/entry_object.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/entry.dart';
import 'package:sharedinbox/core/models/note.dart';
import 'package:sharedinbox/core/repositories/note_repository.dart';
import 'package:sharedinbox/core/services/encrypted_key_service.dart';
import 'package:sharedinbox/di.dart';

import 'entries_fakes.dart';
import 'helpers.dart';

const _url = '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42';

/// Legacy notes as the test feeds them; adding one is a mistake here.
class _Notes implements NoteRepository {
  final ctrl = StreamController<List<EmailNote>>.broadcast();
  List<EmailNote> current = const [];

  void emit(List<EmailNote> notes) => ctrl.add(current = notes);

  @override
  Stream<List<EmailNote>> observeNotesForMessages(
    String accountId,
    Iterable<String> messageIds,
  ) async* {
    yield current;
    yield* ctrl.stream;
  }

  @override
  Stream<List<EmailNote>> observeNotes(String accountId, String messageId) =>
      observeNotesForMessages(accountId, [messageId]);

  @override
  Future<void> syncAllNotes(String accountId) async {}

  @override
  Future<void> addNote(String accountId, String messageId, String text) =>
      throw const NotesEncryptedException('acc-1');

  @override
  Future<void> deleteNote(String noteId) async {}
}

Future<(_Notes, FakeEntryRepository)> _open(
  WidgetTester tester,
  PersonalDataStatus status,
) async {
  final notes = _Notes();
  addTearDown(notes.ctrl.close);
  final entries = FakeEntryRepository();
  await tester.pumpWidget(
    buildApp(
      initialLocation: _url,
      userPreferences: FakeUserPreferencesRepository(personalDataBeta: true),
      overrides: [
        accountRepositoryProvider.overrideWithValue(
          FakeAccountRepository([kTestAccount]),
        ),
        mailboxRepositoryProvider.overrideWithValue(FakeMailboxRepository()),
        emailRepositoryProvider.overrideWithValue(
          FakeEmailRepository(
            emailDetail: testEmail().copyWith(messageId: '<m1@x>'),
            emailBody: const EmailBody(
              emailId: 'acc-1:42',
              textBody: 'Body',
              attachments: [],
            ),
          ),
        ),
        encryptedKeyServiceProvider.overrideWithValue(
          FixedStatusKeyService(status),
        ),
        noteRepositoryProvider.overrideWithValue(notes),
        entryRepositoryProvider.overrideWithValue(entries),
      ],
    ),
  );
  await tester.pumpAndSettle();
  return (notes, entries);
}

void main() {
  testWidgets('a migration neither blinks nor doubles the note',
      (tester) async {
    final (notes, entries) = await _open(tester, PersonalDataStatus.unlocked);
    notes.emit([
      EmailNote(
        id: 'n1',
        accountId: 'acc-1',
        messageId: '<m1@x>',
        noteText: 'call back',
        serverId: '7',
        createdAt: DateTime(2024, 6, 2, 10, 15),
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('call back'), findsOneWidget);

    // The migration writes the entry; the plaintext note is still there.
    entries.add(
      Entry(
        accountId: 'acc-1',
        itemId: await tester.runAsync(() => legacyNoteItemId('n1')) ?? '',
        itemHmac: 'h1',
        body: 'call back',
        links: const ['<m1@x>'],
        createdAt: DateTime.utc(2024, 6, 2, 8, 15),
        versionId: 'v1',
        updatedAt: DateTime.utc(2026, 11, 23),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.text('call back'), findsOneWidget);

    // The plaintext note goes.
    notes.emit(const []);
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.text('call back'), findsOneWidget);
  });

  testWidgets('locked: no new note, a hint to unlock', (tester) async {
    await _open(tester, PersonalDataStatus.locked);
    expect(find.byKey(const Key('notesLockedHint')), findsOneWidget);
    expect(find.text('Unlock personal data to add notes'), findsOneWidget);
    final add = tester.widget<TextButton>(find.byKey(const Key('notesAdd')));
    expect(add.onPressed, isNull);
  });

  testWidgets('not set up: the add dialog says the note is unencrypted',
      (tester) async {
    await _open(tester, PersonalDataStatus.notSetUp);
    await tester.tap(find.byKey(const Key('notesAdd')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Stored unencrypted'), findsOneWidget);
  });

  testWidgets('unlocked: a new note is an entry linked to the mail',
      (tester) async {
    final (_, entries) = await _open(tester, PersonalDataStatus.unlocked);
    expect(find.byKey(const Key('notesLockedHint')), findsNothing);
    await tester.tap(find.byKey(const Key('notesAdd')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Stored unencrypted'), findsNothing);
    await tester.enterText(find.byType(TextField).last, 'remember');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final entry = entries.entries.single;
    expect(entry.body, 'remember');
    expect(entry.links, ['<m1@x>']);
    expect(find.text('remember'), findsOneWidget);
  });
}
