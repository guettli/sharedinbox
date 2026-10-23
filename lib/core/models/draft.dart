class SavedDraft {
  final int id;
  final String? accountId;
  final String? replyToEmailId;
  final String toText;
  final String ccText;
  final String bccText;
  final String subjectText;
  final String bodyText;
  final DateTime updatedAt;
  final String? imapServerId;
  final String? jmapServerId;
  final bool dirty;

  const SavedDraft({
    required this.id,
    this.accountId,
    this.replyToEmailId,
    required this.toText,
    required this.ccText,
    this.bccText = '',
    required this.subjectText,
    required this.bodyText,
    required this.updatedAt,
    this.imapServerId,
    this.jmapServerId,
    this.dirty = true,
  });
}

/// What compose hands [DraftRepository.saveDraft] to store.
class DraftInput {
  const DraftInput({
    this.id,
    this.accountId,
    this.replyToEmailId,
    required this.toText,
    required this.ccText,
    this.bccText = '',
    required this.subjectText,
    required this.bodyText,
  });

  /// The row to update; null creates a new one.
  final int? id;
  final String? accountId;
  final String? replyToEmailId;
  final String toText;
  final String ccText;
  final String bccText;
  final String subjectText;
  final String bodyText;
}
