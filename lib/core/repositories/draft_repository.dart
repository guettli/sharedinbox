import 'package:sharedinbox/core/models/draft.dart';

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

  /// Syncs local drafts with the server IMAP Drafts folder for [accountId].
  /// Uploads local drafts that have no [SavedDraft.imapServerId]; imports
  /// server drafts that are not already tracked locally.
  /// No-op when the implementation has no IMAP connection configured.
  Future<void> syncDrafts(String accountId, String password);
}
