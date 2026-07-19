// Regression test for #319:
// EmailDetailScreen.build fired NoteRepository.syncNotes via unawaited(...)
// when a message with a Message-ID first arrived. On flaky networks
// connectImap timed out after 20 s, and the resulting TimeoutException
// propagated as an unhandled asynchronous error to
// runZonedGuarded → FlutterError.onError → CrashScreen — killing the whole
// app while the user was reading the message.
//
// The fix routes the fire-and-forget sync through _syncNotesQuietly, which
// wraps the call in try/catch and logs failures. This test overrides
// noteRepositoryProvider with a stub that throws TimeoutException on
// syncNotes and asserts that no error reaches FlutterError.onError.
//
// Mirrors the pattern in test/unit/email_detail_prefetch_test.dart (#232).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/note.dart';
import 'package:sharedinbox/core/repositories/note_repository.dart';
import 'package:sharedinbox/di.dart';

import 'helpers.dart';

class _ThrowingNoteRepository implements NoteRepository {
  _ThrowingNoteRepository(this.error);

  final Object error;
  int syncCalls = 0;

  @override
  Stream<List<EmailNote>> observeNotes(String accountId, String messageId) =>
      const Stream.empty();

  @override
  Future<void> syncNotes(String accountId, String messageId) async {
    syncCalls++;
    throw error;
  }

  @override
  Future<void> addNote(String accountId, String messageId, String text) async =>
      throw UnimplementedError();

  @override
  Future<void> deleteNote(String noteId) async => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'syncNotes TimeoutException does not escape EmailDetailScreen (#319)',
    (tester) async {
      // testEmail() doesn't set messageId, but syncNotes is only invoked when
      // messageId is non-null. Build the fixture directly.
      final email = Email(
        id: 'acc-1:42',
        accountId: 'acc-1',
        mailboxPath: 'INBOX',
        uid: 42,
        subject: 'Hello world',
        receivedAt: DateTime(2024, 6),
        sentAt: DateTime(2024, 6),
        from: const [EmailAddress(name: 'Bob', email: 'bob@example.com')],
        to: const [EmailAddress(email: 'alice@example.com')],
        cc: const [],
        isSeen: false,
        isFlagged: false,
        hasAttachment: false,
        messageId: '<abc@example.com>',
      );

      final noteRepo = _ThrowingNoteRepository(
        // Same shape as the crash reported in #319: TimeoutException from
        // ClientBase.connectToServer after 20 s.
        TimeoutException(
          'Future not completed',
          const Duration(seconds: 20),
        ),
      );

      final capturedErrors = <Object>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        capturedErrors.add(details.exception);
      };
      addTearDown(() {
        FlutterError.onError = previousOnError;
      });

      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42',
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([kTestAccount]),
            ),
            mailboxRepositoryProvider.overrideWithValue(FakeMailboxRepository()),
            emailRepositoryProvider.overrideWithValue(
              FakeEmailRepository(
                emailDetail: email,
                emailBody: const EmailBody(
                  emailId: 'acc-1:42',
                  attachments: [],
                ),
              ),
            ),
            noteRepositoryProvider.overrideWithValue(noteRepo),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // Drain any lingering microtasks so the unawaited _syncNotesQuietly
      // future runs to completion. Without the try/catch inside
      // _syncNotesQuietly, the TimeoutException would surface here as an
      // unhandled asynchronous error.
      await tester.pump();
      await tester.pump();

      expect(
        noteRepo.syncCalls,
        greaterThanOrEqualTo(1),
        reason: 'the widget must invoke syncNotes when messageId is present',
      );
      expect(
        capturedErrors,
        isEmpty,
        reason:
            'a TimeoutException from syncNotes must be swallowed by '
            '_syncNotesQuietly, not delivered to FlutterError.onError',
      );
    },
  );
}
