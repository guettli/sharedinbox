/// The `task` field of an [Entry] (ENCRYPTED-OBJECTS.md §6): makes it a
/// todo.
class EntryTask {
  const EntryTask({
    this.due,
    this.priority,
    this.done = false,
    this.doneAt,
  });

  /// `YYYY-MM-DD`.
  final String? due;
  final int? priority;
  final bool done;

  /// ISO 8601.
  final String? doneAt;

  /// Reads a `task` field; null when it is not an object. Fields of the
  /// wrong type are left out.
  static EntryTask? fromJson(Object? json) {
    if (json is! Map) return null;
    final due = json['due'];
    final priority = json['priority'];
    final done = json['done'];
    final doneAt = json['doneAt'];
    return EntryTask(
      due: due is String ? due : null,
      priority: priority is int ? priority : null,
      done: done is bool && done,
      doneAt: doneAt is String ? doneAt : null,
    );
  }

  Map<String, Object?> toJson() => {
        if (due != null) 'due': due,
        if (priority != null) 'priority': priority,
        'done': done,
        if (doneAt != null) 'doneAt': doneAt,
      };
}

/// One entry (note, todo, journal entry) of the encrypted personal data
/// (ENCRYPTED-OBJECTS.md §6), as its projection shows it.
class Entry {
  const Entry({
    required this.accountId,
    required this.itemId,
    required this.itemHmac,
    this.title,
    this.body = '',
    this.tags = const [],
    this.date,
    this.task,
    this.links = const [],
    required this.versionId,
    required this.updatedAt,
    this.hasConflict = false,
  });

  final String accountId;
  final String itemId;

  /// The item HMAC (base64url): the store's handle of the item.
  final String itemHmac;
  final String? title;

  /// Plain Markdown text.
  final String body;
  final List<String> tags;

  /// `YYYY-MM-DD`: makes it a journal entry.
  final String? date;
  final EntryTask? task;

  /// RFC 2822 Message-IDs of the mails it belongs to.
  final List<String> links;

  /// The encoded HLC of the version shown.
  final String versionId;

  /// The wall clock of [versionId].
  final DateTime updatedAt;

  /// Several heads with different content.
  final bool hasConflict;

  /// What a list shows for it: the title, or else the first line of the
  /// body.
  String get displayTitle {
    final t = title?.trim() ?? '';
    if (t.isNotEmpty) return t;
    return body.trimLeft().split('\n').first.trim();
  }

  /// The body without the line [displayTitle] took from it.
  String get preview {
    final t = title?.trim() ?? '';
    if (t.isNotEmpty) return body.trim();
    final lines = body.trimLeft().split('\n');
    return lines.skip(1).join('\n').trim();
  }
}
