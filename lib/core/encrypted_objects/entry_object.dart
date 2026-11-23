import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:sharedinbox/core/encrypted_objects/envelope.dart';
import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/merge.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:sharedinbox/core/models/entry.dart';

/// The kind of an entry (ENCRYPTED-OBJECTS.md §6): a note, todo or journal
/// entry. Fields `title`, `tags`, `date`, `task`, `links`, `createdAt` in
/// the head, the body as a `text/markdown` part.
const entryKind = 'entry';

const _markdownType = 'text/markdown; charset=utf-8';

bool _isMarkdown(ObjectPart p) =>
    p.contentType.split(';').first.trim().toLowerCase() == 'text/markdown';

ObjectPart _markdownPart(String body) => ObjectPart(
      contentType: _markdownType,
      bytes: Uint8List.fromList(utf8.encode(body)),
    );

/// A new entry in the personal collection; an empty [title] is left out.
/// A [task] makes it a todo; [links] are the Message-IDs of its mails.
/// [itemId] defaults to a random one; [createdAt] (e.g. of a migrated
/// note) is written as the `createdAt` field.
InnerObject newEntryObject({
  String? title,
  required String body,
  required HlcClock clock,
  EntryTask? task,
  List<String> links = const [],
  String? itemId,
  DateTime? createdAt,
}) =>
    InnerObject(
      head: ObjectHead(
        itemId: itemId ?? newItemId(),
        collectionId: personalCollectionId,
        versionId: clock.send(),
        kind: entryKind,
        extra: {
          if (title != null && title.trim().isNotEmpty) 'title': title,
          'tags': const <String>[],
          'links': links,
          if (task != null) 'task': task.toJson(),
          if (createdAt != null) 'createdAt': createdAt.toUtc().toIso8601String(),
        },
      ),
      parts: [_markdownPart(body)],
    );

/// The itemId of the entry a legacy plaintext note [noteId] migrates into
/// (#1375): base64url of the first 16 bytes of
/// `SHA-256("sharedinbox-legacy-note:" + noteId)`. Two devices migrating
/// the same note write the same item with the same content.
Future<String> legacyNoteItemId(String noteId) async {
  final hash = await Sha256().hash(utf8.encode('$_legacyNotePrefix$noteId'));
  return b64url(hash.bytes.sublist(0, idLength));
}

const _legacyNotePrefix = 'sharedinbox-legacy-note:';

/// The entry a legacy plaintext note migrates into (#1375): its text as the
/// body, linked to its mail, its date as `createdAt`, no title and no tags.
/// The content depends on the note only, so two devices migrating it at
/// once write versions with the same content digest: one head, no conflict.
Future<InnerObject> legacyNoteEntryObject({
  required String noteId,
  required String messageId,
  required String text,
  required DateTime createdAt,
  required HlcClock clock,
}) async =>
    newEntryObject(
      body: text,
      clock: clock,
      links: [messageId],
      itemId: await legacyNoteItemId(noteId),
      createdAt: createdAt,
    );

/// The entry [object] shows, or null for a tombstone or another kind.
/// Fields missing or of the wrong type read as empty.
Entry? entryFromObject(
  InnerObject object, {
  required String accountId,
  required String itemHmac,
  bool conflict = false,
}) {
  final head = object.head;
  if (head.deleted || head.kind != entryKind) return null;
  final extra = head.extra;
  final title = extra['title'];
  final date = extra['date'];
  final createdAt = extra['createdAt'];
  final body = object.parts.where(_isMarkdown).firstOrNull;
  return Entry(
    accountId: accountId,
    itemId: head.itemId,
    itemHmac: itemHmac,
    title: title is String ? title : null,
    body: body == null ? '' : utf8.decode(body.bytes, allowMalformed: true),
    tags: _strings(extra['tags']),
    date: date is String ? date : null,
    task: EntryTask.fromJson(extra['task']),
    links: _strings(extra['links']),
    createdAt: createdAt is String ? DateTime.tryParse(createdAt)?.toUtc() : null,
    versionId: head.versionId.encode(),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(
      head.versionId.wallMs,
      isUtc: true,
    ),
    hasConflict: conflict,
  );
}

List<String> _strings(Object? json) => [
      if (json is List)
        for (final s in json)
          if (s is String) s,
    ];

/// An edit of [base] (a head of [merge]) setting [title] (empty: none) and
/// [body]. Other fields and parts are kept; `parents = all heads`, so it
/// also resolves a conflict.
InnerObject editEntryObject({
  required InnerObject base,
  required MergeResult merge,
  required HlcClock clock,
  String? title,
  required String body,
}) {
  final parts = [...base.parts];
  final markdown = parts.indexWhere(_isMarkdown);
  if (markdown < 0) parts.insert(0, _markdownPart(body));
  if (markdown >= 0) parts[markdown] = _markdownPart(body);
  final hasTitle = title != null && title.trim().isNotEmpty;
  final next = edit(
    base: base,
    merge: merge,
    clock: clock,
    fields: {if (hasTitle) 'title': title},
    parts: parts,
  );
  if (hasTitle) return next;
  return _withoutField(next, 'title');
}

/// The `task` keys this app knows; others are kept on an edit (§5.2).
const _taskKeys = {'due', 'priority', 'done', 'doneAt'};

/// An edit of [base] (a head of [merge]) setting its `task` (null: none,
/// so no longer a todo). Title, body, parts, other fields and unknown `task`
/// keys are kept. A tick writes no `doneAt`, so two devices ticking the same
/// version write identical content, which merges as one head.
InnerObject editEntryTask({
  required InnerObject base,
  required MergeResult merge,
  required HlcClock clock,
  required EntryTask? task,
}) {
  if (task == null) {
    return _withoutField(
      edit(base: base, merge: merge, clock: clock),
      'task',
    );
  }
  final old = base.head.extra['task'];
  return edit(
    base: base,
    merge: merge,
    clock: clock,
    fields: {
      'task': {
        if (old is Map)
          for (final MapEntry(:key, :value) in old.entries)
            if (key is String && !_taskKeys.contains(key)) key: value,
        ...task.toJson(),
      },
    },
  );
}

/// [object] without the head field [key].
InnerObject _withoutField(InnerObject object, String key) {
  if (!object.head.extra.containsKey(key)) return object;
  final head = object.head;
  return InnerObject(
    head: ObjectHead(
      v: head.v,
      itemId: head.itemId,
      collectionId: head.collectionId,
      versionId: head.versionId,
      parents: head.parents,
      kind: head.kind,
      extra: {...head.extra}..remove(key),
    ),
    parts: object.parts,
  );
}
