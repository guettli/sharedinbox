import 'dart:async';

import 'package:drift/drift.dart';

import 'package:sharedinbox/core/encrypted_objects/entry_object.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/repositories/legacy_note_migration.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/core/repositories/note_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/note_repository_impl.dart';

/// [LegacyNoteMigration] over the `EmailNotes` cache, the encrypted-object
/// store and the note push (ENCRYPTED-OBJECTS.md §6, #1375). Runs only in
/// [NotesMode.entries], in three passes:
///
/// - **A0** (no confirmation needed): a note still pending upload never
///   reached the server, so no other device knows it. It becomes an entry
///   and its row goes; the plaintext is never uploaded.
/// - **A** (once confirmed): each synced note becomes an entry, unless any
///   version of its item exists here (a tombstone too: a delete by the user
///   is never undone).
/// - **B** (once confirmed): a synced note whose entry has a version on the
///   server is marked deleted; the note push then removes the server copy,
///   found by its `X-SharedInbox-Note-Id` header, and drops the row.
///
/// The itemId is derived from the note id ([legacyNoteItemId]) and the
/// content from the note only, so two devices migrating the same note write
/// the same item with the same content: one head, no conflict, no
/// duplicate. An interrupted migration resumes with no state of its own.
///
/// Only notes are touched: the pull reads only mails with
/// `X-SharedInbox-Note-Id` and a delete looks mail up only by that header,
/// so other mail in `Notes` (e.g. Apple Notes) stays, and so does the
/// folder. Note text is never logged.
class LegacyNoteMigrator implements LegacyNoteMigration {
  LegacyNoteMigrator(
    this._db,
    this._store,
    this._notes, {
    required NotesModeLookup notesMode,
    AppLogger? appLogger,
    DateTime Function()? now,
  })  : _notesMode = notesMode,
        _appLogger = appLogger,
        _now = now ?? DateTime.now;

  final AppDatabase _db;
  final MailObjectStore _store;
  final NoteRepositoryImpl _notes;
  final NotesModeLookup _notesMode;
  final AppLogger? _appLogger;
  final DateTime Function() _now;

  @override
  Future<void> beforeObjectSync(String accountId) async {
    if (await _notesMode(accountId) != NotesMode.entries) return;
    final local = await _migrate(accountId, pending: true);
    _log(
      accountId,
      'notes.migrate.local',
      'Local notes moved into entries',
      local,
    );
    if (!await _confirmed(accountId)) return;
    final put = await _migrate(accountId, pending: false);
    _log(accountId, 'notes.migrate.put', 'Notes moved into entries', put);
  }

  @override
  Future<void> afterObjectSync(String accountId) async {
    if (await _notesMode(accountId) != NotesMode.entries) return;
    if (!await _confirmed(accountId)) return;
    final retired = await _retire(accountId);
    _log(
      accountId,
      'notes.migrate.retired',
      'Plaintext copies of migrated notes queued for deletion',
      retired,
    );
    if (retired == 0) return;
    await _notes.pushPendingNow(accountId);
  }

  @override
  Stream<int> watchAwaitingConfirmation(String accountId) => _db
      .customSelect(
        'SELECT COUNT(*) AS n FROM email_notes n '
        'JOIN accounts a ON a.id = n.account_id '
        'WHERE n.account_id = ? AND n.pending_upload = 0 '
        'AND n.pending_delete = 0 '
        'AND a.legacy_notes_migration_confirmed_at IS NULL',
        variables: [Variable<String>(accountId)],
        readsFrom: {_db.emailNotes, _db.accounts},
      )
      .watchSingle()
      .map((r) => r.read<int>('n'));

  @override
  Future<void> confirm(String accountId) async {
    await (_db.update(_db.accounts)..where((t) => t.id.equals(accountId)))
        .write(
      AccountsCompanion(legacyNotesMigrationConfirmedAt: Value(_now())),
    );
  }

  Future<bool> _confirmed(String accountId) async {
    final row = await (_db.select(_db.accounts)
          ..where((t) => t.id.equals(accountId)))
        .getSingleOrNull();
    return row?.legacyNotesMigrationConfirmedAt != null;
  }

  /// Pass A0 ([pending]) or A: writes the entry of each note that has no
  /// version yet; in A0 the note's row goes right after. Returns the number
  /// of notes changed: rows gone (A0), entries written (A).
  Future<int> _migrate(String accountId, {required bool pending}) async {
    var n = 0;
    for (final row in await _rows(accountId, pending: pending)) {
      final hmac = await _hmacOf(accountId, row.id);
      // No write key (any more): try again on a later sync.
      if (hmac == null) return n;
      final exists = await _hasVersion(accountId, hmac);
      if (!exists) {
        await _store.put(
          accountId,
          await legacyNoteEntryObject(
            noteId: row.id,
            messageId: row.messageId,
            text: row.noteText,
            createdAt: row.createdAt,
            clock: await _store.clockFor(accountId),
          ),
        );
      }
      if (pending) {
        // Only if it is still pending: an upload that got through in the
        // meantime is a synced note now, for the passes A and B.
        await (_db.delete(_db.emailNotes)
              ..where(
                (t) =>
                    t.id.equals(row.id) &
                    t.pendingUpload.equals(true) &
                    t.pendingDelete.equals(false),
              ))
            .go();
      }
      if (pending || !exists) n++;
    }
    return n;
  }

  /// Pass B: marks each synced note whose entry has a version on the server
  /// deleted. Returns their number.
  Future<int> _retire(String accountId) async {
    var n = 0;
    for (final row in await _rows(accountId, pending: false)) {
      final hmac = await _hmacOf(accountId, row.id);
      if (hmac == null) return n;
      if (!await _hasVersion(accountId, hmac, onServer: true)) continue;
      await (_db.update(_db.emailNotes)
            ..where((t) => t.id.equals(row.id) & t.pendingDelete.equals(false)))
          .write(const EmailNotesCompanion(pendingDelete: Value(true)));
      n++;
    }
    return n;
  }

  /// The notes of [accountId] not deleted here: those still to upload
  /// ([pending]) or the synced ones.
  Future<List<EmailNoteRow>> _rows(
    String accountId, {
    required bool pending,
  }) =>
      (_db.select(_db.emailNotes)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.pendingUpload.equals(pending) &
                  t.pendingDelete.equals(false),
            )
            ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
          .get();

  Future<String?> _hmacOf(String accountId, String noteId) async =>
      _store.itemHmacOf(
        accountId,
        personalCollectionId,
        await legacyNoteItemId(noteId),
      );

  /// Whether item [itemHmac] has a version here, a tombstone too; with
  /// [onServer] one the server confirmed.
  Future<bool> _hasVersion(
    String accountId,
    String itemHmac, {
    bool onServer = false,
  }) async {
    final q = _db.select(_db.mailObjects)
      ..where(
        (t) => t.accountId.equals(accountId) & t.itemHmac.equals(itemHmac),
      )
      ..limit(1);
    if (onServer) {
      q.where((t) => t.pendingUpload.equals(false) & t.serverId.isNotNull());
    }
    return await q.getSingleOrNull() != null;
  }

  /// One App Log line per pass that changed something.
  void _log(String accountId, String event, String message, int count) {
    if (count == 0) return;
    unawaited(
      _appLogger?.info(
        event,
        message,
        accountId: accountId,
        data: {'count': count},
      ),
    );
  }
}
