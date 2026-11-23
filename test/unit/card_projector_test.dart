import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/encrypted_objects/card_object.dart';
import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/models/card.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/card_projector.dart';

import 'db_test_helper.dart';

const _acc = 'acc-1';
const _deck = 'deck-1';

HlcClock _clockAt(int ms, [String device = 'devA']) =>
    HlcClock(device, nowMs: () => ms);

/// What the store's merge hands a projector for [heads].
ProjectedItem _item(List<InnerObject> heads, {bool conflict = false}) =>
    ProjectedItem(
      display: heads.where((h) => !h.head.deleted).lastOrNull,
      conflict: conflict,
      heads: heads,
    );

void main() {
  setUpAll(configureSqliteForTests);

  late AppDatabase db;
  late CardDocProjector docs;
  late CardBatchProjector batches;
  late DeckProjector decks;

  setUp(() async {
    db = await openTestDatabaseWithAccounts([_acc]);
    docs = CardDocProjector(db);
    batches = CardBatchProjector(db);
    decks = DeckProjector(db);
  });
  tearDown(() => db.close());

  Future<CardRow?> cardRow(String cardId) =>
      (db.select(db.cards)..where((t) => t.cardId.equals(cardId)))
          .getSingleOrNull();

  Future<void> applyBatch(String hmac, List<InnerObject> heads) =>
      batches.apply(_acc, hmac, _item(heads, conflict: heads.length > 1));

  Future<void> applyDoc(
    String hmac,
    List<InnerObject> heads, {
    bool conflict = false,
  }) =>
      docs.apply(_acc, hmac, _item(heads, conflict: conflict));

  InnerObject batchOf(List<String> ids, HlcClock clock) => cardBatchObjects(
        deckId: _deck,
        cards: [
          for (final id in ids)
            NewCard(CardContent(front: 'batch $id', back: 'b'), cardId: id),
        ],
        clock: clock,
      ).single;

  test('a batch projects one source and one card per member', () async {
    expect(batches.mergesHeads, isTrue);
    expect(docs.mergesHeads, isFalse);
    await applyBatch('B1', [
      batchOf(['c1', 'c2'], _clockAt(1000)),
    ]);

    final cards = await db.select(db.cards).get();
    expect(cards.map((c) => c.cardId), ['c1', 'c2']);
    expect(cards.first.sourceKind, CardSourceKind.batch.name);
    expect(cards.first.sourceItemHmac, 'B1');
    expect(cards.first.front, 'batch c1');
    expect(cards.first.tagsJson, '[]');
    expect(await db.select(db.cardSources).get(), hasLength(2));
  });

  test('a lower-h member never beats a doc or a tombstone', () async {
    final batch = batchOf(['c1', 'c2'], _clockAt(1000));
    final edit = cardDocVersion(
      deckId: _deck,
      cardId: 'c1',
      content: const CardContent(front: 'edited', back: 'b'),
      clock: _clockAt(5000, 'devB'),
    );
    final gone = cardDocVersion(
      deckId: _deck,
      cardId: 'c2',
      clock: _clockAt(5000, 'devB'),
    );
    // The docs first, the older batch after them (as a pull may order it).
    await applyDoc('D1', [edit]);
    await applyDoc('D2', [gone]);
    await applyBatch('B1', [batch]);

    final c1 = (await cardRow('c1'))!;
    expect(c1.front, 'edited');
    expect(c1.sourceKind, CardSourceKind.doc.name);
    expect(c1.sourceItemHmac, 'D1');
    final c2 = (await cardRow('c2'))!;
    expect(c2.deleted, isTrue, reason: 'the tombstone row stays');
    expect(c2.h, gone.head.versionId.encode());
    expect(await db.select(db.cardSources).get(), hasLength(4));
  });

  test('a member with a higher h beats an older doc', () async {
    final doc = cardDocVersion(
      deckId: _deck,
      cardId: 'c1',
      content: const CardContent(front: 'doc', back: 'b'),
      clock: _clockAt(1000),
    );
    await applyDoc('D1', [doc]);
    await applyBatch('B1', [
      batchOf(['c1'], _clockAt(2000)),
    ]);

    expect((await cardRow('c1'))!.front, 'batch c1');
  });

  test('an edit racing a delete stays visible as a conflict', () async {
    final base = cardDocVersion(
      deckId: _deck,
      cardId: 'c1',
      content: const CardContent(front: 'v1', back: 'b'),
      clock: _clockAt(1000),
    );
    final edit = InnerObject(
      head: ObjectHead(
        itemId: 'c1',
        collectionId: _deck,
        versionId: Hlc(2000, 0, 'devA'),
        parents: [base.head.versionId],
        kind: cardKind,
        extra: const {'tags': <String>[]},
      ),
      parts: cardDocVersion(
        deckId: _deck,
        cardId: 'c1',
        content: const CardContent(front: 'v2', back: 'b'),
        clock: _clockAt(2000),
      ).parts,
    );
    final gone = InnerObject(
      head: ObjectHead(
        itemId: 'c1',
        collectionId: _deck,
        versionId: Hlc(3000, 0, 'devB'),
        parents: [base.head.versionId],
        deleted: true,
        kind: cardKind,
      ),
    );
    await applyDoc('D1', [edit, gone], conflict: true);

    final c1 = (await cardRow('c1'))!;
    expect(c1.deleted, isFalse);
    expect(c1.front, 'v2');
    expect(c1.hasConflict, isTrue);
  });

  test('a batch never shows a conflict', () async {
    final clock = _clockAt(1000);
    final a = batchOf(['c1'], clock);
    final b = batchOf(['c1'], clock);
    await batches.apply(
      _acc,
      'B1',
      ProjectedItem(display: b, conflict: true, heads: [a, b]),
    );

    final c1 = (await cardRow('c1'))!;
    expect(c1.hasConflict, isFalse);
    expect(c1.h, readBatchMembers(b).single.h.encode());
  });

  test('a card without sources left loses its row', () async {
    await applyBatch('B1', [
      batchOf(['c1'], _clockAt(1000)),
    ]);
    expect(await cardRow('c1'), isNotNull);

    await batches.apply(_acc, 'B1', const ProjectedItem());

    expect(await cardRow('c1'), isNull);
    expect(await db.select(db.cardSources).get(), isEmpty);
  });

  test('a deck doc projects its name; a tombstone removes it', () async {
    final deck = newDeckObject(
      deckId: _deck,
      name: 'Spanish',
      clock: _clockAt(1700000000000),
    );
    await decks.apply(_acc, 'K1', _item([deck]));

    final row = (await db.select(db.decks).get()).single;
    expect(row.collectionId, _deck);
    expect(row.name, 'Spanish');
    expect(row.itemHmac, 'K1');
    expect(row.updatedAt, 1700000000000);

    await decks.apply(_acc, 'K1', const ProjectedItem());
    expect(await db.select(db.decks).get(), isEmpty);
  });
}
