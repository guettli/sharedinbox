import 'package:sharedinbox/core/encrypted_objects/entry_object.dart';
import 'package:sharedinbox/core/models/entry.dart';
import 'package:sharedinbox/core/models/note.dart';

/// A note shown on a mail (#1375): a legacy plaintext note, or an encrypted
/// entry linked to the mail by its Message-ID.
class LinkedNote {
  const LinkedNote({
    required this.id,
    required this.accountId,
    required this.messageId,
    required this.text,
    required this.createdAt,
    this.isEntry = false,
    this.hasConflict = false,
    this.pendingUpload = false,
  });

  /// The note id, or the entry's itemId when [isEntry].
  final String id;
  final String accountId;

  /// The Message-ID of the mail it is on.
  final String messageId;
  final String text;
  final DateTime createdAt;

  /// An encrypted entry rather than a legacy plaintext note.
  final bool isEntry;

  /// An entry with several heads of different content.
  final bool hasConflict;

  /// A legacy note saved on this device only so far.
  final bool pendingUpload;
}

LinkedNote linkedNoteOf(EmailNote n) => LinkedNote(
      id: n.id,
      accountId: n.accountId,
      messageId: n.messageId,
      text: n.noteText,
      createdAt: n.createdAt,
      pendingUpload: n.pendingUpload,
    );

/// The [entries] and the legacy [notes] on the mails [messageIds] of the
/// mail [messageId], oldest first (#1375). A note whose entry exists
/// ([legacyNoteItemId]) is left out, so a migration never shows a note
/// twice or makes it blink.
Future<List<LinkedNote>> mergeLinkedNotes(
  String messageId,
  List<String> messageIds,
  List<Entry> entries,
  List<EmailNote> notes,
) async {
  final entryIds = {for (final e in entries) e.itemId};
  final merged = [
    for (final e in entries)
      LinkedNote(
        id: e.itemId,
        accountId: e.accountId,
        messageId: e.links.contains(messageId)
            ? messageId
            : e.links.where(messageIds.contains).firstOrNull ?? messageId,
        text: [
          if ((e.title ?? '').trim().isNotEmpty) e.title!.trim(),
          if (e.body.trim().isNotEmpty) e.body.trim(),
        ].join('\n'),
        createdAt: e.sortDate.toLocal(),
        isEntry: true,
        hasConflict: e.hasConflict,
      ),
  ];
  for (final n in notes) {
    if (entryIds.contains(await _legacyItemId(n.id))) continue;
    merged.add(linkedNoteOf(n));
  }
  return merged..sort((a, b) => a.createdAt.compareTo(b.createdAt));
}

final _legacyItemIds = <String, String>{};

Future<String> _legacyItemId(String noteId) async =>
    _legacyItemIds[noteId] ??= await legacyNoteItemId(noteId);
