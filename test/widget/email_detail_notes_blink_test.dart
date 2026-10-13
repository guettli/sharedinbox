// Regression test for #1053.
//
// The single-mail view blinked its HTML body while a sync was running. The
// Notes section (rendered above the body) is fed by conversationNotesProvider,
// which watches threadEmailsProvider — a drift .watch() that re-emits on every
// write to the emails table, so it resubscribes and passes through
// AsyncLoading constantly during a sync. With the default
// skipLoadingOnReload: false the section collapsed to zero height and back on
// every emit, shifting the WebView below it up and down.
//
// This test drives that exact reload: it shows a note, then makes
// threadEmailsProvider re-emit (as a sync write would). It asserts the notes
// stream really does resubscribe AND that the note stays on screen through the
// reload — i.e. the section no longer collapses.

import 'dart:async';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/note.dart';
import 'package:sharedinbox/core/repositories/note_repository.dart';
import 'package:sharedinbox/di.dart';

import 'helpers.dart';

/// A [NoteRepository] whose observe streams are driven by the test, with a
/// counter so the test can prove a resubscription (reload) actually happened.
class _FakeNoteRepository implements NoteRepository {
  _FakeNoteRepository(this._stream);

  final Stream<List<EmailNote>> _stream;
  int observeForMessagesCalls = 0;

  @override
  Stream<List<EmailNote>> observeNotesForMessages(
    String accountId,
    Iterable<String> messageIds,
  ) {
    observeForMessagesCalls++;
    return _stream;
  }

  @override
  Stream<List<EmailNote>> observeNotes(String accountId, String messageId) =>
      _stream;

  @override
  Future<void> syncAllNotes(String accountId) async {}

  @override
  Future<void> addNote(String accountId, String messageId, String text) async {}

  @override
  Future<void> deleteNote(String noteId) async {}
}

void main() {
  testWidgets(
    'notes stay on screen while threadEmailsProvider churns during sync '
    '(#1053)',
    (tester) async {
      const route = '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42';

      final email = Email(
        id: 'acc-1:42',
        accountId: 'acc-1',
        mailboxPath: 'INBOX',
        uid: 42,
        subject: 'Threaded mail',
        receivedAt: DateTime(2024, 6),
        sentAt: DateTime(2024, 6),
        from: const [EmailAddress(name: 'Bob', email: 'bob@example.com')],
        to: const [EmailAddress(email: 'alice@example.com')],
        cc: const [],
        isSeen: true,
        isFlagged: false,
        hasAttachment: false,
        messageId: 'msg-1',
        threadId: 'thread-1',
      );
      const body = EmailBody(
        emailId: 'acc-1:42',
        textBody: 'Body text',
        attachments: [],
      );
      final note = EmailNote(
        id: 'n1',
        accountId: 'acc-1',
        messageId: 'msg-1',
        noteText: 'Remember to reply',
        serverId: '7',
        createdAt: DateTime(2024, 6, 2, 10, 15),
      );

      // Broadcast so each resubscription gets its own listener but only
      // receives events added *after* it subscribes — modelling the async
      // drift re-query that leaves the provider in AsyncLoading on reload.
      final notesCtrl = StreamController<List<EmailNote>>.broadcast();
      final threadCtrl = StreamController<List<Email>>.broadcast();
      addTearDown(notesCtrl.close);
      addTearDown(threadCtrl.close);

      final noteRepo = _FakeNoteRepository(notesCtrl.stream);

      final overrides = <Override>[
        accountRepositoryProvider.overrideWithValue(
          FakeAccountRepository([kTestAccount]),
        ),
        mailboxRepositoryProvider.overrideWithValue(FakeMailboxRepository()),
        emailRepositoryProvider.overrideWithValue(
          FakeEmailRepository(emailDetail: email, emailBody: body),
        ),
        noteRepositoryProvider.overrideWithValue(noteRepo),
        threadEmailsProvider.overrideWith((ref, key) => threadCtrl.stream),
      ];

      await tester.pumpWidget(
        buildApp(initialLocation: route, overrides: overrides),
      );
      await tester.pumpAndSettle();

      // Notes stream subscribed once; no note emitted yet.
      expect(noteRepo.observeForMessagesCalls, 1);
      expect(find.text('Remember to reply'), findsNothing);

      // The note arrives.
      notesCtrl.add([note]);
      await tester.pumpAndSettle();
      expect(find.text('Remember to reply'), findsOneWidget);

      // A sync write makes threadEmailsProvider re-emit, forcing
      // conversationNotesProvider to resubscribe the notes stream. The new
      // subscription has no buffered event, so the provider sits in
      // AsyncLoading — exactly the state that used to blank the section.
      threadCtrl.add(const <Email>[]);
      await tester.pumpAndSettle();

      expect(
        noteRepo.observeForMessagesCalls,
        greaterThanOrEqualTo(2),
        reason: 'the reload path must actually be exercised',
      );
      // The fix: the note must remain visible through that reload.
      expect(find.text('Remember to reply'), findsOneWidget);
    },
  );
}
