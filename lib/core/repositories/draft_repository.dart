import '../models/draft.dart';

abstract class DraftRepository {
  /// Inserts or updates a draft.  Pass [id] to update; omit to create new.
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

  /// Permanently removes the draft with [id].
  Future<void> deleteDraft(int id);
}
