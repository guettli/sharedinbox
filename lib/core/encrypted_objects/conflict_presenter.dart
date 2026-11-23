import 'dart:convert';

import 'package:sharedinbox/core/encrypted_objects/entry_object.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';

/// How the conflict view (#1374) shows the versions of one document kind:
/// a title for the list, and a text the versions are diffed by. Every field
/// a user can change should show in [diffText], so a difference in a field
/// alone also shows in the diff.
abstract interface class ConflictPresenter {
  /// The kind it presents; null for the fallback.
  String? get kind;

  String title(InnerObject object);

  String diffText(InnerObject object);
}

/// The presenter of [kind]: the kind's own, else [GenericConflictPresenter].
ConflictPresenter presenterFor(String? kind) {
  if (kind == entryKind) return const EntryConflictPresenter();
  return const GenericConflictPresenter();
}

/// Any kind: the canonical JSON of the head without `versionId` and
/// `parents`, then the text parts.
class GenericConflictPresenter implements ConflictPresenter {
  const GenericConflictPresenter();

  @override
  String? get kind => null;

  @override
  String title(InnerObject object) =>
      '${object.head.kind ?? 'object'} ${object.head.itemId}';

  @override
  String diffText(InnerObject object) {
    final head = {...object.head.toJson()}
      ..remove('versionId')
      ..remove('parents');
    return [
      canonicalJson(head),
      for (final p in object.parts)
        if (p.contentType.trim().toLowerCase().startsWith('text/'))
          utf8.decode(p.bytes, allowMalformed: true),
    ].join('\n\n');
  }
}

/// An entry: the title, one line per field, a blank line, the Markdown
/// body.
class EntryConflictPresenter implements ConflictPresenter {
  const EntryConflictPresenter();

  @override
  String get kind => entryKind;

  @override
  String title(InnerObject object) {
    final entry = entryFromObject(object, accountId: '', itemHmac: '');
    if (entry == null) return '(deleted)';
    final title = entry.displayTitle;
    return title.isEmpty ? '(empty)' : title;
  }

  @override
  String diffText(InnerObject object) {
    final entry = entryFromObject(object, accountId: '', itemHmac: '');
    if (entry == null) return '';
    final task = object.head.extra['task'];
    return [
      entry.title ?? '',
      'tags: ${entry.tags.join(', ')}',
      'date: ${entry.date ?? ''}',
      'task: ${task == null ? '' : canonicalJson(task)}',
      'links: ${entry.links.join(', ')}',
      '',
      entry.body,
    ].join('\n');
  }
}
