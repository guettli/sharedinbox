import 'package:sharedinbox/core/models/draft.dart';

abstract class DraftRepository {
  /// Inserts or updates a draft.  Pass [id] to update; omit to create new.
  /// Marks the row as dirty so the next sync cycle pushes it to the server.
  Future<SavedDraft> saveDraft({
    int? id,
    String? accountId,
    String? replyToEmailId,
    required String toText,
    required String ccText,
    required String subjectText,
    required String bodyText,
  });

  /// Returns the most recent draft for the given reply context (null = new
  /// message), or null if none exists.
  Future<SavedDraft?> findDraft({String? replyToEmailId});

  /// Returns the draft with [id], or null.
  Future<SavedDraft?> getDraft(int id);

  /// Permanently removes the draft with [id]. If the row had been synced to
  /// the server, writes a tombstone so the next sync cycle deletes the
  /// server-side copy too.
  Future<void> deleteDraft(int id);

  /// Two-way sync between the local drafts table and the server-side Drafts
  /// folder for [accountId]:
  ///
  /// 1. Push tombstones (delete server-side copies of locally-deleted drafts).
  /// 2. Push dirty rows (replace server-side copy for edits; append for new).
  /// 3. Pull server-side drafts not already tracked locally.
  /// 4. Remove local rows whose server counterpart has disappeared.
  ///
  /// No-op for accounts whose protocol the implementation cannot reach
  /// (e.g. JMAP without a configured `jmapUrl`).
  Future<void> syncDrafts(String accountId);
}
