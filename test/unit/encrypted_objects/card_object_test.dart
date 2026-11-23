import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:sharedinbox/core/encrypted_objects/card_object.dart';
import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/encrypted_objects/log_segment.dart';
import 'package:sharedinbox/core/encrypted_objects/merge.dart';
import 'package:sharedinbox/core/models/card.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

const _deck = 'deck-1';

HlcClock _clockAt(int ms, [String device = 'devA']) =>
    HlcClock(device, nowMs: () => ms);

Future<MergeResult> _mergeOf(List<InnerObject> objects) async => mergeItem(
      known: [for (final o in objects) await ObjectVersion.of(o)],
      incoming: const [],
      vv: const {},
    );

/// [length] characters of base64 noise: barely compresses.
String _noise(Random random, int length) {
  final bytes = [for (var i = 0; i < length; i++) random.nextInt(256)];
  return base64.encode(bytes).substring(0, length);
}

List<NewCard> _small(int n) => [
      for (var i = 0; i < n; i++)
        NewCard(
          CardContent(front: 'Q$i', back: 'A$i', tags: const ['t']),
          cardId: 'c${i.toString().padLeft(4, '0')}',
        ),
    ];

List<NewCard> _noisy(int n, int bytes, {int seed = 1, String prefix = 'n'}) {
  final random = Random(seed);
  return [
    for (var i = 0; i < n; i++)
      NewCard(
        CardContent(front: _noise(random, bytes), back: 'b$i'),
        cardId: '$prefix${i.toString().padLeft(4, '0')}',
      ),
  ];
}

int _bodySize(InnerObject batch) => batch.parts
    .singleWhere((p) => p.contentType == cardBatchContentType)
    .bytes
    .length;

void main() {
  test('a card doc round-trips through seal and open', () async {
    final object = newCardObject(
      deckId: _deck,
      content: const CardContent(
        front: '# Hund',
        back: 'dog',
        tags: ['de', 'en'],
      ),
      clock: _clockAt(1700000000000),
    );
    expect(object.head.kind, cardKind);
    expect(object.head.collectionId, _deck);
    expect(
      [for (final p in object.parts) p.contentId],
      ['front', 'back'],
    );
    final sealed = await sealObject(key: testDeckKey, object: object);
    final opened = await openObject(
      blob: sealed.blob,
      itemHmacFromHeader: sealed.itemHmac,
      keyLookup: (_) => testDeckKey,
    );
    expect(
      cardContentOf(opened.object),
      const CardContent(front: '# Hund', back: 'dog', tags: ['de', 'en']),
    );
  });

  test('an edit keeps unknown fields and other parts; parents = all heads',
      () async {
    final image = ObjectPart(
      contentType: 'image/png',
      contentId: 'img1',
      bytes: Uint8List.fromList([1, 2, 3]),
    );
    final base = newCardObject(
      deckId: _deck,
      cardId: 'c1',
      content: const CardContent(front: 'f', back: 'b'),
      clock: _clockAt(1000, 'devB'),
    );
    final withExtra = InnerObject(
      head: ObjectHead(
        itemId: base.head.itemId,
        collectionId: _deck,
        versionId: base.head.versionId,
        kind: cardKind,
        extra: {'tags': const <String>[], 'future': 42},
      ),
      parts: [...base.parts, image],
    );
    final next = editCardObject(
      deckId: _deck,
      cardId: 'c1',
      content: const CardContent(front: 'F', back: 'B', tags: ['x']),
      clock: _clockAt(2000),
      base: withExtra,
      merge: await _mergeOf([withExtra]),
    );
    expect(next.head.itemId, 'c1');
    expect(next.head.parents, [withExtra.head.versionId]);
    expect(next.head.extra['future'], 42);
    expect(
      cardContentOf(next),
      const CardContent(front: 'F', back: 'B', tags: ['x']),
    );
    expect(next.parts.last.contentId, 'img1');
  });

  test(
      'the first doc of a batch member has no parents and an h above the '
      "member's, even from a clock far ahead", () {
    final ahead = Hlc(1700000000000 + 60 * 60 * 1000, 3, 'devB');
    final clock = _clockAt(1700000000000);
    final edited = editCardObject(
      deckId: _deck,
      cardId: 'c7',
      content: const CardContent(front: 'f', back: 'b'),
      clock: clock,
      above: ahead,
    );
    expect(edited.head.itemId, 'c7');
    expect(edited.head.parents, isEmpty);
    expect(edited.head.versionId > ahead, isTrue);

    final deleted = deleteCardObject(
      deckId: _deck,
      cardId: 'c8',
      clock: clock,
      above: ahead,
    );
    expect(deleted.head.deleted, isTrue);
    expect(deleted.head.kind, cardKind);
    expect(deleted.head.parents, isEmpty);
    expect(deleted.head.versionId > ahead, isTrue);
    expect(cardContentOf(deleted), isNull);
  });

  test('a delete of a doc is a tombstone over all its heads', () async {
    final a = newCardObject(
      deckId: _deck,
      cardId: 'c1',
      content: const CardContent(front: 'a', back: 'a'),
      clock: _clockAt(1000, 'devA'),
    );
    final b = newCardObject(
      deckId: _deck,
      cardId: 'c1',
      content: const CardContent(front: 'b', back: 'b'),
      clock: _clockAt(1001, 'devB'),
    );
    final gone = deleteCardObject(
      deckId: _deck,
      cardId: 'c1',
      clock: _clockAt(3000),
      base: b,
      merge: await _mergeOf([a, b]),
    );
    expect(gone.head.deleted, isTrue);
    expect(gone.head.parents, [a.head.versionId, b.head.versionId]);
  });

  test('batch members round-trip; unknown member fields are kept', () {
    final batch = cardBatchObjects(
      deckId: _deck,
      cards: _small(3),
      clock: _clockAt(1000),
    ).single;
    expect(batch.head.kind, cardBatchKind);
    expect(batch.head.extra['count'], 3);
    final members = readBatchMembers(batch);
    expect([for (final m in members) m.cardId], ['c0000', 'c0001', 'c0002']);
    expect(
      members[1].content,
      const CardContent(front: 'Q1', back: 'A1', tags: ['t']),
    );

    final line = {...members.first.toJson(), 'ease': 2.5};
    final read = CardBatchMember.fromJson(line);
    expect(read.extra, {'ease': 2.5});
    expect(read.copyWith(h: hlcAt(9000)).toJson()['ease'], 2.5);
    expect(
      () => CardBatchMember.fromJson({'f': 'x'}),
      throwsFormatException,
    );
  });

  test('1 000 small cards are 2 batches; every card has its own h', () {
    final objects = cardBatchObjects(
      deckId: _deck,
      cards: _small(1000),
      clock: _clockAt(1700000000000),
    );
    expect(objects, hasLength(2));
    expect(objects.every((o) => o.head.kind == cardBatchKind), isTrue);
    expect([for (final o in objects) o.head.extra['count']], [500, 500]);
    final members = [for (final o in objects) ...readBatchMembers(o)];
    expect(members, hasLength(1000));
    expect({for (final m in members) m.h}, hasLength(1000));
    expect(
      [for (final m in members) m.cardId],
      [for (final c in _small(1000)) c.cardId],
    );
    expect(objects.map(_bodySize), everyElement(lessThan(maxBatchBodyBytes)));
  });

  test('cards of about 1 KiB split by the body limit, each body ≤ 200 KiB',
      () {
    final cards = _noisy(600, 1000);
    final objects = cardBatchObjects(
      deckId: _deck,
      cards: cards,
      clock: _clockAt(1000),
    );
    expect(objects.length, greaterThan(2));
    expect(objects.every((o) => o.head.kind == cardBatchKind), isTrue);
    for (final o in objects) {
      expect(_bodySize(o), lessThanOrEqualTo(maxBatchBodyBytes));
      expect(o.head.extra['count'], lessThan(maxCardsPerBatch));
    }
    // Greedy: one more card would not have fit.
    final first = readBatchMembers(objects.first);
    final next = readBatchMembers(objects[1]).first;
    expect(
      gzipJsonLines([
        for (final m in [...first, next]) encodeJsonLine(m.toJson()),
      ]).length,
      greaterThan(maxBatchBodyBytes),
    );
    expect(
      [
        for (final o in objects)
          for (final m in readBatchMembers(o)) m.cardId,
      ],
      [for (final c in cards) c.cardId],
    );
  });

  test('a card over 200 KiB alone becomes a card doc', () {
    final cards = [
      ..._small(2),
      ..._noisy(1, 300 * 1000, prefix: 'big'),
      ..._small(3).skip(2),
    ];
    final objects = cardBatchObjects(
      deckId: _deck,
      cards: cards,
      clock: _clockAt(1000),
    );
    expect(
      [for (final o in objects) o.head.kind],
      [cardBatchKind, cardKind, cardBatchKind],
    );
    final doc = objects[1];
    expect(doc.head.itemId, 'big0000');
    expect(cardContentOf(doc)!.front, cards[2].content.front);
  });

  test('mergeBatchMembers: per cardId the highest h, in any order', () {
    final base = cardBatchObjects(
      deckId: _deck,
      cards: _small(3),
      clock: _clockAt(1000),
    ).single;
    final members = readBatchMembers(base);
    InnerObject headWith(List<CardBatchMember> ms, Hlc version) => InnerObject(
          head: ObjectHead(
            itemId: base.head.itemId,
            collectionId: _deck,
            versionId: version,
            parents: [base.head.versionId],
            kind: cardBatchKind,
            extra: {'count': ms.length},
          ),
          parts: [
            ObjectPart(
              contentType: cardBatchContentType,
              bytes: gzipJsonLines([
                for (final m in ms) encodeJsonLine(m.toJson()),
              ]),
            ),
          ],
        );
    const fromA = CardContent(front: 'A', back: 'A');
    const fromB = CardContent(front: 'B', back: 'B');
    final a = headWith([
      members[0].copyWith(h: hlcAt(5000, 'devA'), content: fromA),
      members[1].copyWith(h: hlcAt(5000, 'devA'), content: fromA),
      members[2],
    ], hlcAt(5001, 'devA'));
    final b = headWith([
      members[0],
      members[1].copyWith(h: hlcAt(6000, 'devB'), content: fromB),
      members[2].copyWith(h: hlcAt(6000, 'devB'), content: fromB),
    ], hlcAt(6001, 'devB'));

    final ab = mergeBatchMembers([a, b]);
    final ba = mergeBatchMembers([b, a]);
    expect(
      [for (final m in ab) jsonEncode(m.toJson())],
      [for (final m in ba) jsonEncode(m.toJson())],
    );
    expect([for (final m in ab) m.content], [fromA, fromB, fromB]);
    final tombstoned = InnerObject(
      head: ObjectHead(
        itemId: base.head.itemId,
        collectionId: _deck,
        versionId: hlcAt(7000),
        deleted: true,
        kind: cardBatchKind,
      ),
    );
    expect(mergeBatchMembers([tombstoned]), isEmpty);
  });

  test('a rewrite collapses all heads and keeps the head fields', () async {
    final base = cardBatchObjects(
      deckId: _deck,
      cards: _small(2),
      clock: _clockAt(1000),
    ).single;
    final other = InnerObject(
      head: ObjectHead(
        itemId: base.head.itemId,
        collectionId: _deck,
        versionId: hlcAt(1500, 'devB'),
        kind: cardBatchKind,
        extra: {'count': 2, 'source': 'anki'},
      ),
      parts: base.parts,
    );
    final members = mergeBatchMembers([base, other]);
    final out = rewriteBatchObject(
      base: other,
      merge: await _mergeOf([base, other]),
      members: [
        members[0].copyWith(
          h: hlcAt(2000),
          content: const CardContent(front: 'x', back: 'y'),
        ),
        members[1],
      ],
      clock: _clockAt(2000),
    );
    final rewritten = out.single;
    expect(rewritten.head.itemId, base.head.itemId);
    expect(
      rewritten.head.parents,
      [base.head.versionId, other.head.versionId],
    );
    expect(rewritten.head.extra, {'count': 2, 'source': 'anki'});
    expect(
      readBatchMembers(rewritten).first.content,
      const CardContent(front: 'x', back: 'y'),
    );
  });

  test(
      'a rewrite over the body limit moves the members that do not fit to '
      'a new batch, each with a higher h', () async {
    final clock = _clockAt(1000);
    final base = cardBatchObjects(
      deckId: _deck,
      cards: _noisy(150, 1000),
      clock: clock,
    ).single;
    final before = readBatchMembers(base);
    final added = [
      for (final c in _noisy(150, 1000, seed: 2, prefix: 'm'))
        CardBatchMember(cardId: c.cardId!, h: clock.send(), content: c.content),
    ];
    final highest = added.last.h;
    final out = rewriteBatchObject(
      base: base,
      merge: await _mergeOf([base]),
      members: [...before, ...added],
      clock: clock,
    );
    expect(out.length, greaterThan(1));
    expect(out.first.head.itemId, base.head.itemId);
    expect(out.first.head.parents, [base.head.versionId]);
    for (final o in out) {
      expect(o.head.kind, cardBatchKind);
      expect(_bodySize(o), lessThanOrEqualTo(maxBatchBodyBytes));
    }
    final kept = readBatchMembers(out.first);
    final moved = [
      for (final o in out.skip(1)) ...readBatchMembers(o),
    ];
    expect(moved, isNotEmpty);
    expect(moved.every((m) => m.h > highest), isTrue);
    expect(
      {
        for (final m in [...kept, ...moved]) m.cardId,
      },
      {
        for (final m in [...before, ...added]) m.cardId,
      },
    );
    expect(kept.length + moved.length, 300);
    // Members that stay keep their h.
    expect(kept.first.h, before.first.h);
  });

  test('a deck doc lives in its own collection; a rename keeps the rest',
      () async {
    final deckId = newDeckId();
    expect(deckId, startsWith('deck-'));
    final deck = newDeckObject(
      deckId: deckId,
      name: 'Spanish',
      clock: _clockAt(1000),
    );
    expect(deck.head.itemId, deckId);
    expect(deck.head.collectionId, deckId);
    expect(deckNameOf(deck), 'Spanish');
    final withExtra = InnerObject(
      head: ObjectHead(
        itemId: deckId,
        collectionId: deckId,
        versionId: deck.head.versionId,
        kind: deckKind,
        extra: {'name': 'Spanish', 'color': 'red'},
      ),
    );
    final renamed = editDeckObject(
      base: withExtra,
      merge: await _mergeOf([withExtra]),
      clock: _clockAt(2000),
      name: 'Español',
    );
    expect(deckNameOf(renamed), 'Español');
    expect(renamed.head.extra['color'], 'red');
    expect(deckNameOf(testObject()), isNull);
  });
}
