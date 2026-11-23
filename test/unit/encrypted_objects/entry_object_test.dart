import 'dart:convert';
import 'dart:typed_data';

import 'package:sharedinbox/core/encrypted_objects/entry_object.dart';
import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/merge.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:sharedinbox/core/models/entry.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  HlcClock clockAt(int ms, [String device = 'devA']) =>
      HlcClock(device, nowMs: () => ms);

  Future<MergeResult> mergeOf(List<InnerObject> objects) async => mergeItem(
        known: [for (final o in objects) await ObjectVersion.of(o)],
        incoming: const [],
        vv: const {},
      );

  ObjectPart imagePart() => ObjectPart(
        contentType: 'image/png',
        contentId: 'img1',
        bytes: Uint8List.fromList([1, 2, 3]),
      );

  test('a new entry round-trips through seal and open', () async {
    final object = newEntryObject(
      title: 'Groceries',
      body: 'milk\neggs',
      clock: clockAt(1700000000000),
    );
    expect(object.head.kind, entryKind);
    expect(object.head.collectionId, personalCollectionId);
    final sealed = await sealObject(key: testPersonalKey, object: object);
    final opened = await openObject(
      blob: sealed.blob,
      itemHmacFromHeader: sealed.itemHmac,
      keyLookup: (_) => testPersonalKey,
    );
    final entry = entryFromObject(
      opened.object,
      accountId: 'acc',
      itemHmac: b64url(sealed.itemHmac),
    )!;
    expect(entry.itemId, object.head.itemId);
    expect(entry.title, 'Groceries');
    expect(entry.body, 'milk\neggs');
    expect(entry.tags, isEmpty);
    expect(entry.links, isEmpty);
    expect(entry.task, isNull);
    expect(entry.hasConflict, isFalse);
    expect(entry.versionId, object.head.versionId.encode());
    expect(entry.updatedAt.millisecondsSinceEpoch, 1700000000000);
  });

  test('quick add: no title; the first line of the body is shown', () {
    final object = newEntryObject(
      title: '',
      body: '\n  Buy milk  \nat the shop\nsoon',
      clock: clockAt(1000),
    );
    expect(object.head.extra.containsKey('title'), isFalse);
    final entry = entryFromObject(object, accountId: 'a', itemHmac: 'h')!;
    expect(entry.title, isNull);
    expect(entry.displayTitle, 'Buy milk');
    expect(entry.preview, 'at the shop\nsoon');
  });

  test('an edit keeps unknown fields and other parts', () async {
    final base = InnerObject(
      head: ObjectHead(
        itemId: 'e1',
        collectionId: personalCollectionId,
        versionId: hlcAt(1000, 'devB'),
        kind: entryKind,
        extra: const {
          'title': 'Old',
          'tags': ['a'],
          'date': '2026-11-23',
          'task': {'done': false, 'due': '2026-12-01', 'priority': 2},
          'links': ['<m@x>'],
          'future': {'x': 1},
        },
      ),
      parts: [
        ObjectPart(
          contentType: 'text/markdown; charset=utf-8',
          bytes: Uint8List.fromList(utf8.encode('old')),
        ),
        imagePart(),
      ],
    );
    final next = editEntryObject(
      base: base,
      merge: await mergeOf([base]),
      clock: clockAt(2000),
      title: 'New',
      body: 'new body',
    );
    expect(next.head.parents, [base.head.versionId]);
    expect(next.head.extra['future'], {'x': 1});
    expect(next.head.extra['tags'], ['a']);
    expect(next.parts, hasLength(2));
    expect(next.parts[1].contentId, 'img1');
    final entry = entryFromObject(next, accountId: 'a', itemHmac: 'h')!;
    expect(entry.title, 'New');
    expect(entry.body, 'new body');
    expect(entry.date, '2026-11-23');
    expect(entry.task!.due, '2026-12-01');
    expect(entry.task!.priority, 2);
    expect(entry.task!.done, isFalse);
    expect(entry.links, ['<m@x>']);

    // Clearing the title drops the field.
    final cleared = editEntryObject(
      base: next,
      merge: await mergeOf([next]),
      clock: clockAt(3000),
      title: '',
      body: 'x',
    );
    expect(cleared.head.extra.containsKey('title'), isFalse);
    expect(cleared.head.extra['future'], {'x': 1});
  });

  test('an edit of two heads names both as parents', () async {
    final a = testObject(
      itemId: 'e1',
      collectionId: personalCollectionId,
      versionId: hlcAt(1000),
      body: 'a',
    );
    final b = testObject(
      itemId: 'e1',
      collectionId: personalCollectionId,
      versionId: hlcAt(1100, 'devB'),
      body: 'b',
    );
    final merge = await mergeOf([a, b]);
    expect(merge.state, MergeState.conflict);
    final next = editEntryObject(
      base: b,
      merge: merge,
      clock: clockAt(2000, 'devC'),
      body: 'resolved',
    );
    expect(next.head.parents, [a.head.versionId, b.head.versionId]);
  });

  test('fields of the wrong type read as empty', () {
    final object = InnerObject(
      head: ObjectHead(
        itemId: 'e1',
        collectionId: personalCollectionId,
        versionId: hlcAt(1000),
        kind: entryKind,
        extra: const {
          'title': 7,
          'tags': 'nope',
          'date': false,
          'task': 'x',
          'links': [1, '<ok@x>'],
        },
      ),
      parts: [imagePart()],
    );
    final entry = entryFromObject(object, accountId: 'a', itemHmac: 'h')!;
    expect(entry.title, isNull);
    expect(entry.body, '');
    expect(entry.tags, isEmpty);
    expect(entry.date, isNull);
    expect(entry.task, isNull);
    expect(entry.links, ['<ok@x>']);

    final task = EntryTask.fromJson({'done': 'yes', 'due': 3});
    expect(task!.done, isFalse);
    expect(task.due, isNull);
  });

  test('a tombstone and another kind give no entry', () {
    expect(
      entryFromObject(
        testObject(collectionId: personalCollectionId, deleted: true),
        accountId: 'a',
        itemHmac: 'h',
      ),
      isNull,
    );
    final card = InnerObject(
      head: ObjectHead(
        itemId: 'c1',
        collectionId: personalCollectionId,
        versionId: hlcAt(1000),
        kind: 'card',
      ),
    );
    expect(entryFromObject(card, accountId: 'a', itemHmac: 'h'), isNull);
  });
}
