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

  /// Returns the saved new-message drafts (those not tied to a reply),
  /// newest first.
  ///
  /// When [accountId] is non-null, only drafts belonging to that account are
  /// returned — composing from a specific inbox never offers another account's
  /// draft (#753). The Compose action uses this to let the user choose between
  /// resuming a draft and starting a blank message (#1047).
  Future<List<SavedDraft>> listNewMessageDrafts({String? accountId});

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
