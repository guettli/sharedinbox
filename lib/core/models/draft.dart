import 'dart:convert';

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

  /// The files kept with the draft. Their paths point into the draft's own
  /// folder, except for files that were already gone when it was saved.
  final List<DraftAttachment> attachments;

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
    this.attachments = const [],
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
    this.attachments = const [],
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

  /// The files to keep with the draft (see [DraftRepository.saveDraft]).
  final List<DraftAttachment> attachments;
}

/// A file attached to a saved draft.
class DraftAttachment {
  const DraftAttachment({
    required this.path,
    required this.filename,
    required this.contentType,
    required this.size,
  });

  /// Local file holding the bytes.
  final String path;

  /// The name the recipient sees.
  final String filename;
  final String contentType;
  final int size;

  Map<String, Object> toJson() => {
        'path': path,
        'filename': filename,
        'contentType': contentType,
        'size': size,
      };

  /// Null when [json] is not an attachment entry.
  static DraftAttachment? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final path = json['path'];
    if (path is! String || path.isEmpty) return null;
    final filename = json['filename'];
    final contentType = json['contentType'];
    final size = json['size'];
    return DraftAttachment(
      path: path,
      filename: filename is String ? filename : '',
      contentType:
          contentType is String ? contentType : 'application/octet-stream',
      size: size is int ? size : 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DraftAttachment &&
      other.path == path &&
      other.filename == filename &&
      other.contentType == contentType &&
      other.size == size;

  @override
  int get hashCode => Object.hash(path, filename, contentType, size);

  @override
  String toString() => 'DraftAttachment($filename, $path)';
}

/// The `drafts.attachments_json` value for [attachments].
String encodeDraftAttachments(List<DraftAttachment> attachments) =>
    jsonEncode([for (final a in attachments) a.toJson()]);

/// Reads a `drafts.attachments_json` value; malformed input yields no
/// attachments rather than an error, so one bad row cannot break compose.
List<DraftAttachment> decodeDraftAttachments(String json) {
  try {
    final list = jsonDecode(json);
    if (list is! List) return const [];
    return [
      for (final e in list)
        if (DraftAttachment.fromJson(e) case final a?) a,
    ];
  } on FormatException {
    return const [];
  }
}
