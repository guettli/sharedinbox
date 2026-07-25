import 'package:sharedinbox/core/models/note.dart';

abstract class NoteRepository {
  /// Stream of notes for an email, keyed by [messageId] (stable across moves).
  Stream<List<EmailNote>> observeNotes(String accountId, String messageId);

  /// Pulls every note in the account's Notes folder into the local cache.
  ///
  /// Runs from the per-account sync loop and the OS-level WorkManager job so
  /// notes are already cached before the user opens the mail — offline
  /// readers see notes without a network round-trip.
  ///
  /// Uses a checkpoint under `SyncStates.resourceType = 'notes'`:
  /// `{uidValidity, lastUid}` for IMAP, `{queryState, emailState}` for JMAP,
  /// so only newly appended notes are fetched on subsequent cycles.
  Future<void> syncAllNotes(String accountId);

  /// Creates a new note on the server and caches it locally.
  Future<void> addNote(String accountId, String messageId, String text);

  /// Deletes a note from the server and removes it from the local cache.
  Future<void> deleteNote(String noteId);
}
