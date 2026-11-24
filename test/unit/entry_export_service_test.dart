import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/encrypted_objects/entry_export.dart';
import 'package:sharedinbox/core/encrypted_objects/entry_object.dart';
import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/merge.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/entry.dart';
import 'package:sharedinbox/core/repositories/entry_repository.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/data/repositories/entry_export_service.dart';
import 'package:sharedinbox/data/repositories/mail_object_blobs.dart';

const _account = Account(
  id: 'acc-1',
  displayName: 'Alice',
  email: 'alice@example.com',
  imapHost: 'imap.example.com',
  smtpHost: 'smtp.example.com',
);

class _Entries implements EntryRepository {
  _Entries(this.entries);

  final List<Entry> entries;

  @override
  Future<List<Entry>> allEntries(String accountId) async => entries;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Store implements MailObjectStore {
  _Store(this.items);

  final Map<String, MailObjectItem> items;

  @override
  Future<MailObjectItem?> item(String accountId, String itemHmac) async =>
      items[itemHmac];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Blobs implements MailObjectBlobStore {
  _Blobs(this.blobs);

  final Map<String, ({String contentType, Uint8List bytes})> blobs;
  final asked = <String>[];

  @override
  Future<({String contentType, Uint8List bytes})?> blob(
    String accountId,
    String collectionId,
    String itemId,
  ) async {
    expect(collectionId, personalCollectionId);
    asked.add(itemId);
    return blobs[itemId];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

InnerObject _version(
  String itemId,
  String device,
  int minute, {
  String body = '',
  bool deleted = false,
}) =>
    InnerObject(
      head: ObjectHead(
        itemId: itemId,
        collectionId: personalCollectionId,
        versionId: Hlc(
          DateTime.utc(2026, 11, 23, 10, minute).millisecondsSinceEpoch,
          0,
          device,
        ),
        deleted: deleted,
        kind: entryKind,
      ),
      parts: [
        if (!deleted)
          ObjectPart(
            contentType: 'text/markdown; charset=utf-8',
            bytes: Uint8List.fromList(utf8.encode(body)),
          ),
      ],
    );

MailObjectItem _item(List<InnerObject> versions) {
  final merge = mergeItem(
    known: [
      for (final (i, v) in versions.indexed)
        ObjectVersion(
          versionId: v.head.versionId,
          deleted: v.head.deleted,
          contentDigest: 'digest-$i',
          ref: i,
        ),
    ],
    incoming: const [],
    vv: const {},
  );
  return MailObjectItem(
    merge: merge,
    display: versions[merge.display!.ref! as int],
    versions: [for (final h in merge.distinctHeads) versions[h.ref! as int]],
  );
}

Entry _entryOf(InnerObject v, {bool conflict = false}) => entryFromObject(
      v,
      accountId: _account.id,
      itemHmac: 'hmac-${v.head.itemId}',
      conflict: conflict,
    )!;

void main() {
  test('collects conflict heads, tombstones and images', () async {
    final plain = _version('plain', 'devA', 1, body: '![x](si-img:have)');
    final live = _version('conf', 'devA', 3, body: 'mine ![y](si-img:gone)');
    final other = _version('conf', 'devB', 2, body: 'theirs ![x](si-img:have)');
    final tomb = _version('conf', 'devC', 1, deleted: true);
    final png = Uint8List.fromList([1, 2, 3]);
    final blobs = _Blobs({'have': (contentType: 'image/png', bytes: png)});
    final service = EntryExportServiceImpl(
      _Entries([_entryOf(plain), _entryOf(live, conflict: true)]),
      _Store({
        'hmac-conf': _item([tomb, other, live]),
      }),
      blobs,
      now: () => DateTime(2026, 11, 23, 11, 12, 13),
    );

    final result = await service.export(_account);

    expect(result.entries, 2);
    expect(result.conflictVersions, 2);
    expect(result.images, 1);
    expect(result.missingImages, ['gone']);
    expect(blobs.asked.toSet(), {'have', 'gone'});
    expect(blobs.asked, hasLength(2));
    expect(
      result.fileName,
      'sharedinbox-export-alice@example.com-20261123-111213.zip',
    );
    final files = {
      for (final f in ZipDecoder().decodeBytes(result.zip).files)
        f.name: utf8.decode(f.readBytes()!, allowMalformed: true),
    };
    final tombPath = 'entries/conf.conflict-'
        '${exportSafeName(tomb.head.versionId.encode())}.md';
    final otherPath = 'entries/conf.conflict-'
        '${exportSafeName(other.head.versionId.encode())}.md';
    expect(files.keys, containsAll(['entries/plain.md', 'entries/conf.md']));
    final t = parseExportedEntry(files[tombPath]!);
    expect(t.deleted, isTrue);
    expect(t.conflict, isTrue);
    expect(t.versionId, tomb.head.versionId.encode());
    final o = parseExportedEntry(files[otherPath]!);
    expect(o.deleted, isFalse);
    expect(o.body, 'theirs ![x](si-img:have)');
    expect(files[otherPath], contains('../images/have.png'));
    expect(
      parseExportedEntry(files['entries/conf.md']!).body,
      contains('mine'),
    );
    expect(files['entries/conf.md'], contains('si-img:gone'));
  });

  test('an entry whose item is gone exports its displayed head only', () async {
    final live = _version('conf', 'devA', 3, body: 'mine');
    final service = EntryExportServiceImpl(
      _Entries([_entryOf(live, conflict: true)]),
      _Store(const {}),
      _Blobs(const {}),
    );
    final result = await service.export(_account);
    expect(result.entries, 1);
    expect(result.conflictVersions, 0);
    expect(result.missingImages, isEmpty);
  });
}
