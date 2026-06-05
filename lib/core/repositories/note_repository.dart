import 'package:sharedinbox/core/models/note.dart';

abstract class NoteRepository {
  /// Stream of notes for an email, keyed by [messageId] (stable across moves).
  Stream<List<EmailNote>> observeNotes(String accountId, String messageId);

  /// Fetches notes from the server into the local cache.
  Future<void> syncNotes(String accountId, String messageId);

  /// Creates a new note on the server and caches it locally.
  Future<void> addNote(String accountId, String messageId, String text);

  /// Deletes a note from the server and removes it from the local cache.
  Future<void> deleteNote(String noteId);
}
