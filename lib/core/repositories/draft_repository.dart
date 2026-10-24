import 'package:sharedinbox/core/models/draft.dart';
import 'package:sharedinbox/core/models/email.dart';

abstract class DraftRepository {
  /// Inserts or updates a draft.  Pass [id] to update; omit to create new.
  /// Marks the row as dirty so the next sync cycle pushes it to the server.
  ///
  /// [attachments] replace the draft's files. The implementation keeps its
  /// own copy of each, so the draft survives the originals being removed;
  /// the returned [SavedDraft.attachments] carry the paths of those copies,
  /// which callers should use from then on. A file that no longer exists is
  /// kept as given, so whoever opens the draft can say it is gone.
  ///
  /// Implementations override [writeDraft]; this only bundles the fields.
  Future<SavedDraft> saveDraft({
    int? id,
    String? accountId,
    String? replyToEmailId,
    required String toText,
    required String ccText,
    String bccText = '',
    required String subjectText,
    required String bodyText,
    List<DraftAttachment> attachments = const [],
  }) =>
      writeDraft(
        DraftInput(
          id: id,
          accountId: accountId,
          replyToEmailId: replyToEmailId,
          toText: toText,
          ccText: ccText,
          bccText: bccText,
          subjectText: subjectText,
          bodyText: bodyText,
          attachments: attachments,
        ),
      );

  /// Stores [input] as [saveDraft] describes.
  Future<SavedDraft> writeDraft(DraftInput input);

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

  /// Returns the local draft whose server copy is [email], or null.
  ///
  /// [email] is a message row synced from the server's Drafts mailbox. Draft
  /// sync pulls every server draft into the local drafts table and remembers
  /// its server id (IMAP UID in the drafts mailbox in use, or JMAP email id),
  /// so opening that message can resume the draft in compose instead of
  /// showing it read-only. Null when the draft has not been pulled yet, or
  /// [email] is not a draft's server copy.
  Future<SavedDraft?> findDraftForEmail(Email email);

  /// Permanently removes the draft with [id] and its attachment files. If
  /// the row had been synced to the server, writes a tombstone so the next
  /// sync cycle deletes the server-side copy too.
  Future<void> deleteDraft(int id);

  /// Removes attachment files left behind by drafts that no longer exist
  /// (e.g. the app stopped between deleting a draft and its files). Run once
  /// at startup; never throws.
  Future<void> deleteOrphanedAttachments();

  /// Two-way sync between the local drafts table and the server-side Drafts
  /// folder for [accountId]:
  ///
  /// 1. Push tombstones (delete server-side copies of locally-deleted drafts).
  /// 2. Push dirty rows (replace server-side copy for edits; append for new).
  /// 3. Pull server-side drafts not already tracked locally.
  /// 4. Remove local rows whose server counterpart has disappeared.
  ///
  /// Attachments travel both ways: a pushed copy carries the draft's files,
  /// and a pulled draft's attachment parts are stored as its files.
  ///
  /// No-op for accounts whose protocol the implementation cannot reach
  /// (e.g. JMAP without a configured `jmapUrl`).
  Future<void> syncDrafts(String accountId);
}
