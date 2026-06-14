class SavedDraft {
  final int id;
  final String? accountId;
  final String? replyToEmailId;
  final String toText;
  final String ccText;
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
    required this.subjectText,
    required this.bodyText,
    required this.updatedAt,
    this.imapServerId,
    this.jmapServerId,
    this.dirty = true,
  });
}
