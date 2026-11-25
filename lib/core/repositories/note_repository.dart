import 'package:sharedinbox/core/models/note.dart';

/// How notes on mails work for an account (ENCRYPTED-OBJECTS.md §6, #1375).
/// An account with a key mail is an encrypted account: this device never
/// writes a new plaintext note for it.
enum NotesMode {
  /// No key mail: plaintext notes in the `Notes` folder, as before.
  legacy,

  /// A key mail exists, but this device has no key: no new notes, and notes
  /// still pending upload stay on this device.
  locked,

  /// Unlocked: new notes are encrypted entries and the legacy notes are
  /// migrated into entries.
  entries,
}

/// The [NotesMode] of an account.
typedef NotesModeLookup = Future<NotesMode> Function(String accountId);

Future<NotesMode> alwaysLegacyNotes(String _) async => NotesMode.legacy;

/// Thrown by [NoteRepository.addNote] for an account that is not in
/// [NotesMode.legacy]: its notes are encrypted entries.
class NotesEncryptedException implements Exception {
  const NotesEncryptedException(this.accountId);

  final String accountId;

  @override
  String toString() =>
      'NotesEncryptedException: notes of $accountId are encrypted entries';
}

abstract class NoteRepository {
  /// Stream of notes for an email, keyed by [messageId] (stable across moves).
  Stream<List<EmailNote>> observeNotes(String accountId, String messageId);

  /// Stream of notes attached to any of [messageIds], oldest first. Backs the
  /// detail view so notes on related mails of the conversation (e.g. the Sent
  /// copy of the mail being replied to) show up too (#870).
  Stream<List<EmailNote>> observeNotesForMessages(
    String accountId,
    Iterable<String> messageIds,
  );

  /// Pushes notes added or deleted on this device, then pulls every note in
  /// the account's Notes folder into the local cache. Outside
  /// [NotesMode.legacy] no note is uploaded; deletes still run.
  ///
  /// Runs from the per-account sync loop and the OS-level WorkManager job so
  /// notes are already cached before the user opens the mail — offline
  /// readers see notes without a network round-trip.
  ///
  /// Uses a checkpoint under `SyncStates.resourceType = 'notes'`:
  /// `{uidValidity, lastUid}` for IMAP, `{queryState, emailState}` for JMAP,
  /// so only newly appended notes are fetched on subsequent cycles.
  Future<void> syncAllNotes(String accountId);

  /// Stores a new note locally (works offline) and pushes it to the server
  /// in the background; a failed push is retried by [syncAllNotes]. Throws
  /// [NotesEncryptedException] outside [NotesMode.legacy].
  Future<void> addNote(String accountId, String messageId, String text);

  /// Hides the note at once (works offline) and removes the server copy in
  /// the background; a failed delete is retried by [syncAllNotes].
  Future<void> deleteNote(String noteId);
}
