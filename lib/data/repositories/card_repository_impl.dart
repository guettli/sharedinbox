import 'package:drift/drift.dart';

import 'package:sharedinbox/core/encrypted_objects/card_object.dart';
import 'package:sharedinbox/core/encrypted_objects/envelope.dart';
import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/merge.dart';
import 'package:sharedinbox/core/models/card.dart';
import 'package:sharedinbox/core/repositories/card_repository.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/projection_json.dart';

/// Makes sure this device has a write key for a collection, creating the
/// collection key if needed (`EncryptedKeyService.ensureCollection`).
typedef EnsureCollection = Future<void> Function(
  String accountId,
  String collectionId,
);

/// [CardRepository] over the `Decks` and `Cards` projections (read) and the
/// [MailObjectStore] (write), which keeps the projections up to date in its
/// merge (`CardDocProjector`, `CardBatchProjector`, `DeckProjector`).
class CardRepositoryImpl implements CardRepository {
  CardRepositoryImpl(
    this._db,
    this._store, {
    required EnsureCollection ensureCollection,
  }) : _ensureCollection = ensureCollection;

  final AppDatabase _db;
  final MailObjectStore _store;
  final EnsureCollection _ensureCollection;

  @override
  Stream<List<Deck>> observeDecks(String accountId) => (_db.select(_db.decks)
        ..where((t) => t.accountId.equals(accountId))
        ..orderBy([
          (t) => OrderingTerm.asc(t.name),
          (t) => OrderingTerm.asc(t.collectionId),
        ]))
      .watch()
      .map((rows) => rows.map(_toDeck).toList());

  @override
  Stream<List<FlashCard>> observeCards(String accountId, String deckId) =>
      (_db.select(_db.cards)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.collectionId.equals(deckId) &
                  t.deleted.equals(false),
            )
            ..orderBy([(t) => OrderingTerm.asc(t.cardId)]))
          .watch()
          .map((rows) => rows.map(_toCard).toList());

  @override
  Future<FlashCard?> card(String accountId, String cardId) async {
    final row = await _cardRow(accountId, cardId);
    return row == null || row.deleted ? null : _toCard(row);
  }

  @override
  Future<Deck> createDeck(String accountId, String name) async {
    final deckId = newDeckId();
    await _ensureCollection(accountId, deckId);
    await _store.put(
      accountId,
      newDeckObject(
        deckId: deckId,
        name: name,
        clock: await _store.clockFor(accountId),
      ),
    );
    return _toDeck((await _deckRow(accountId, deckId))!);
  }

  @override
  Future<void> renameDeck(String accountId, String deckId, String name) async {
    final row = await _deckRow(accountId, deckId);
    if (row == null) throw StateError('unknown deck $deckId');
    final current = await _store.item(accountId, row.itemHmac);
    if (current == null) throw StateError('deck $deckId cannot be opened');
    await _store.put(
      accountId,
      editDeckObject(
        base: current.display,
        merge: current.merge,
        clock: await _store.clockFor(accountId),
        name: name,
      ),
    );
  }

  @override
  Future<int> cardCount(String accountId, String deckId) async {
    final count = _db.cards.cardId.count();
    return (await (_db.selectOnly(_db.cards)
              ..addColumns([count])
              ..where(_liveCardsOf(accountId, deckId)))
            .map((r) => r.read(count))
            .getSingle()) ??
        0;
  }

  @override
  Future<void> deleteDeck(String accountId, String deckId) async {
    final row = await _deckRow(accountId, deckId);
    if (row == null) throw StateError('unknown deck $deckId');
    if (await _store.itemHmacOf(accountId, deckId, deckId) == null) {
      throw NoWriteKeyException(deckId);
    }
    final cardIds = await (_db.selectOnly(_db.cards)
          ..addColumns([_db.cards.cardId])
          ..where(_liveCardsOf(accountId, deckId)))
        .map((r) => r.read(_db.cards.cardId)!)
        .get();
    for (final cardId in cardIds) {
      await _writeCardDoc(accountId, cardId, null);
    }
    final current = await _store.item(accountId, row.itemHmac);
    if (current == null) throw StateError('deck $deckId cannot be opened');
    await _store.put(
      accountId,
      tombstone(
        base: current.display,
        merge: current.merge,
        clock: await _store.clockFor(accountId),
      ),
    );
  }

  Expression<bool> _liveCardsOf(String accountId, String deckId) =>
      _db.cards.accountId.equals(accountId) &
      _db.cards.collectionId.equals(deckId) &
      _db.cards.deleted.equals(false);

  @override
  Future<List<String>> importCards(
    String accountId,
    String deckId,
    List<NewCard> cards,
  ) async {
    final withIds = [
      for (final c in cards)
        NewCard(c.content, cardId: c.cardId ?? newItemId()),
    ];
    final objects = cardBatchObjects(
      deckId: deckId,
      cards: withIds,
      clock: await _store.clockFor(accountId),
    );
    for (final object in objects) {
      await _store.put(accountId, object);
    }
    return [for (final c in withIds) c.cardId!];
  }

  @override
  Future<FlashCard> addCard(
    String accountId,
    String deckId,
    NewCard card,
  ) async {
    final object = newCardObject(
      deckId: deckId,
      cardId: card.cardId,
      content: card.content,
      clock: await _store.clockFor(accountId),
    );
    await _store.put(accountId, object);
    return (await this.card(accountId, object.head.itemId))!;
  }

  @override
  Future<void> editCard(
    String accountId,
    String cardId,
    CardContent content,
  ) =>
      _writeCardDoc(accountId, cardId, content);

  @override
  Future<void> deleteCard(String accountId, String cardId) =>
      _writeCardDoc(accountId, cardId, null);

  @override
  Future<void> rewriteBatch(
    String accountId,
    String batchItemHmac,
    Map<String, CardContent> changes,
  ) async {
    final current = await _store.item(accountId, batchItemHmac);
    if (current == null || current.display.head.kind != cardBatchKind) {
      throw StateError('batch $batchItemHmac cannot be opened');
    }
    final clock = await _store.clockFor(accountId);
    final members = mergeBatchMembers(current.heads);
    CardBatchMember changed(CardBatchMember m, CardContent content) {
      clock.receive(m.h);
      return m.copyWith(h: clock.send(), content: content);
    }

    final known = {for (final m in members) m.cardId};
    final objects = rewriteBatchObject(
      base: current.display,
      merge: current.merge,
      members: [
        for (final m in members)
          if (changes[m.cardId] case final content?) changed(m, content) else m,
        for (final MapEntry(key: cardId, value: content) in changes.entries)
          if (!known.contains(cardId))
            CardBatchMember(cardId: cardId, h: clock.send(), content: content),
      ],
      clock: clock,
    );
    for (final object in objects) {
      await _store.put(accountId, object);
    }
  }

  /// Writes the next version of the `card` doc of [cardId]
  /// ([cardDocVersion]): [content], or a tombstone when null. A card without
  /// a doc yet (a batch member) gets its first one.
  Future<void> _writeCardDoc(
    String accountId,
    String cardId,
    CardContent? content,
  ) async {
    final shown = await _cardRow(accountId, cardId);
    if (shown == null) throw StateError('unknown card $cardId');
    final hmac = await _store.itemHmacOf(
      accountId,
      shown.collectionId,
      shown.cardId,
    );
    if (hmac == null) throw NoWriteKeyException(shown.collectionId);
    final doc = await _store.item(accountId, hmac);
    await _store.put(
      accountId,
      cardDocVersion(
        deckId: shown.collectionId,
        cardId: cardId,
        content: content,
        clock: await _store.clockFor(accountId),
        base: doc?.display,
        merge: doc?.merge,
        above: Hlc.parse(shown.h),
      ),
    );
  }

  Future<CardRow?> _cardRow(String accountId, String cardId) =>
      (_db.select(_db.cards)
            ..where(
              (t) => t.accountId.equals(accountId) & t.cardId.equals(cardId),
            ))
          .getSingleOrNull();

  Future<DeckRow?> _deckRow(String accountId, String deckId) =>
      (_db.select(_db.decks)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) & t.collectionId.equals(deckId),
            ))
          .getSingleOrNull();

  static FlashCard _toCard(CardRow r) => FlashCard(
        accountId: r.accountId,
        cardId: r.cardId,
        deckId: r.collectionId,
        content: CardContent(
          front: r.front,
          back: r.back,
          tags: stringsFromJson(r.tagsJson),
        ),
        h: r.h,
        sourceItemHmac: r.sourceItemHmac,
        sourceKind: CardSourceKind.values.asNameMap()[r.sourceKind] ??
            CardSourceKind.batch,
        hasConflict: r.hasConflict,
      );

  static Deck _toDeck(DeckRow r) => Deck(
        accountId: r.accountId,
        deckId: r.collectionId,
        itemHmac: r.itemHmac,
        name: r.name,
        versionId: r.versionId,
        updatedAt:
            DateTime.fromMillisecondsSinceEpoch(r.updatedAt, isUtc: true),
        hasConflict: r.hasConflict,
      );
}
