import 'dart:convert';
import 'dart:typed_data';

import 'package:sharedinbox/core/encrypted_objects/envelope.dart';
import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/merge.dart';
import 'package:sharedinbox/core/models/entry.dart';

/// The kind of an entry (ENCRYPTED-OBJECTS.md §6): a note, todo or journal
/// entry. Fields `title`, `tags`, `date`, `task`, `links` in the head, the
/// body as a `text/markdown` part.
const entryKind = 'entry';

const _markdownType = 'text/markdown; charset=utf-8';

bool _isMarkdown(ObjectPart p) =>
    p.contentType.split(';').first.trim().toLowerCase() == 'text/markdown';

ObjectPart _markdownPart(String body) => ObjectPart(
      contentType: _markdownType,
      bytes: Uint8List.fromList(utf8.encode(body)),
    );

/// A new entry in the personal collection; an empty [title] is left out.
InnerObject newEntryObject({
  String? title,
  required String body,
  required HlcClock clock,
}) =>
    InnerObject(
      head: ObjectHead(
        itemId: newItemId(),
        collectionId: personalCollectionId,
        versionId: clock.send(),
        kind: entryKind,
        extra: {
          if (title != null && title.trim().isNotEmpty) 'title': title,
          'tags': const <String>[],
          'links': const <String>[],
        },
      ),
      parts: [_markdownPart(body)],
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
  if (hasTitle || !next.head.extra.containsKey('title')) return next;
  final head = next.head;
  return InnerObject(
    head: ObjectHead(
      v: head.v,
      itemId: head.itemId,
      collectionId: head.collectionId,
      versionId: head.versionId,
      parents: head.parents,
      kind: head.kind,
      extra: {...head.extra}..remove('title'),
    ),
    parts: next.parts,
  );
}
