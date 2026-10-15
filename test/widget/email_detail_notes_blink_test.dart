// Regression tests for #1053 (the blink) and #1056 (the memoization).
//
// The single-mail view blinked its HTML body while a sync was running. The
// Notes section (above the body) is fed by conversationNotesProvider, which
// watches threadEmailsProvider — a drift .watch() that re-emits on every write
// to the emails table, constantly during a sync.
//
// Two guarantees are locked in here:
//  - #1056: an emails-table write that does NOT change the thread's set of
//    message IDs must not resubscribe the notes stream (no redundant query).
//  - #1053: when membership *does* change, the stream resubscribes (passing
//    through AsyncLoading), and skipLoadingOnReload keeps the current notes on
//    screen through that reload so the section doesn't collapse and shift the
//    body below it.

import 'dart:async';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/note.dart';
import 'package:sharedinbox/core/repositories/note_repository.dart';
import 'package:sharedinbox/di.dart';

import 'helpers.dart';

/// A [NoteRepository] whose observe streams are driven by the test, with a
/// counter so the test can prove whether a resubscription happened.
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

Email _mail({
  required String id,
  required String messageId,
  String mailboxPath = 'INBOX',
}) =>
    Email(
      id: id,
      accountId: 'acc-1',
      mailboxPath: mailboxPath,
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
      messageId: messageId,
      threadId: 'thread-1',
    );

void main() {
  testWidgets(
    'notes survive sync churn: unchanged membership does not resubscribe, '
    'a membership change keeps notes visible through the reload (#1053, #1056)',
    (tester) async {
      const route = '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42';

      final email = _mail(id: 'acc-1:42', messageId: 'msg-1');
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

      // #1056: a sync write re-emits threadEmailsProvider but the message-ID
      // set is unchanged (still {msg-1}), so the notes stream must NOT
      // resubscribe — no redundant query — and the note stays on screen.
      threadCtrl.add(const <Email>[]);
      await tester.pumpAndSettle();
      expect(
        noteRepo.observeForMessagesCalls,
        1,
        reason: 'unchanged membership must not resubscribe (#1056)',
      );
      expect(find.text('Remember to reply'), findsOneWidget);

      // #1053: now the thread gains a mail (a new message ID), so membership
      // changes and the stream legitimately resubscribes — passing through
      // AsyncLoading. skipLoadingOnReload must keep the note visible.
      threadCtrl.add([_mail(id: 'acc-1:43', messageId: 'msg-2')]);
      await tester.pumpAndSettle();
      expect(
        noteRepo.observeForMessagesCalls,
        2,
        reason: 'a membership change resubscribes exactly once (#1056)',
      );
      expect(
        find.text('Remember to reply'),
        findsOneWidget,
        reason: 'note stays visible through the reload (#1053)',
      );
    },
  );
}
