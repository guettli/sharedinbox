import 'dart:convert';

import 'package:drift/drift.dart';

import 'package:sharedinbox/core/encrypted_objects/card_object.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/models/card.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/data/db/database.dart';

/// Writes the `CardSources` rows of the `card` docs (#1379): one row per
/// doc. Runs inside the store's merge transaction ([ObjectProjector]).
class CardDocProjector extends ObjectProjector {
  CardDocProjector(this.db);

  final AppDatabase db;

  @override
  String get kind => cardKind;

  /// The newest head that is not a tombstone, so an edit racing a delete
  /// stays visible as a conflict; once every head is a tombstone, the
  /// newest tombstone as `deleted`, so it beats older batch members.
  @override
  Future<void> apply(
    String accountId,
    String itemHmac,
    InnerObject? display, {
    required bool conflict,
    required List<InnerObject> heads,
  }) async {
    final shown = display ?? heads.lastOrNull;
    final content = shown == null ? null : cardContentOf(shown);
    await replaceCardSources(db, accountId, itemHmac, [
      if (shown != null)
        CardSourcesCompanion.insert(
          accountId: accountId,
          cardId: shown.head.itemId,
          sourceItemHmac: itemHmac,
          collectionId: shown.head.collectionId,
          sourceKind: CardSourceKind.doc.name,
          h: shown.head.versionId.encode(),
          deleted: Value(content == null),
          front: Value(content?.front ?? ''),
          back: Value(content?.back ?? ''),
          tagsJson: Value(jsonEncode(content?.tags ?? const <String>[])),
          hasConflict: Value(conflict),
        ),
    ]);
  }
}

/// Writes the `CardSources` rows of the `card-batch` docs (#1379): one row
/// per member of [mergeBatchMembers] over all heads. Its heads merge by
/// themselves ([mergesHeads]): never a conflict.
class CardBatchProjector extends ObjectProjector {
  CardBatchProjector(this.db);

  final AppDatabase db;

  @override
  String get kind => cardBatchKind;

  @override
  bool get mergesHeads => true;

  @override
  Future<void> apply(
    String accountId,
    String itemHmac,
    InnerObject? display, {
    required bool conflict,
    required List<InnerObject> heads,
  }) async {
    final collectionId = display?.head.collectionId;
    await replaceCardSources(db, accountId, itemHmac, [
      if (collectionId != null)
        for (final m in mergeBatchMembers(heads))
          CardSourcesCompanion.insert(
            accountId: accountId,
            cardId: m.cardId,
            sourceItemHmac: itemHmac,
            collectionId: collectionId,
            sourceKind: CardSourceKind.batch.name,
            h: m.h.encode(),
            front: Value(m.content.front),
            back: Value(m.content.back),
            tagsJson: Value(jsonEncode(m.content.tags)),
          ),
    ]);
  }
}

/// Writes the `Decks` projection of the `deck` docs (#1379).
class DeckProjector extends ObjectProjector {
  DeckProjector(this.db);

  final AppDatabase db;

  @override
  String get kind => deckKind;

  @override
  Future<void> apply(
    String accountId,
    String itemHmac,
    InnerObject? display, {
    required bool conflict,
    required List<InnerObject> heads,
  }) async {
    final name = display == null ? null : deckNameOf(display);
    if (display == null || name == null) {
      await (db.delete(db.decks)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) & t.itemHmac.equals(itemHmac),
            ))
          .go();
      return;
    }
    final head = display.head;
    await db.into(db.decks).insertOnConflictUpdate(
          DecksCompanion.insert(
            accountId: accountId,
            collectionId: head.collectionId,
            itemHmac: itemHmac,
            name: name,
            versionId: head.versionId.encode(),
            updatedAt: head.versionId.wallMs,
            hasConflict: Value(conflict),
          ),
        );
  }
}

/// Replaces the `CardSources` rows of [sourceItemHmac] by [rows], then sets
/// the `Cards` row of every cardId they touch to its source with the
/// highest `h`; a cardId without a source left loses its row.
Future<void> replaceCardSources(
  AppDatabase db,
  String accountId,
  String sourceItemHmac,
  List<CardSourcesCompanion> rows,
) async {
  final old = await (db.selectOnly(db.cardSources)
        ..addColumns([db.cardSources.cardId])
        ..where(
          db.cardSources.accountId.equals(accountId) &
              db.cardSources.sourceItemHmac.equals(sourceItemHmac),
        ))
      .map((r) => r.read(db.cardSources.cardId)!)
      .get();
  await (db.delete(db.cardSources)
        ..where(
          (t) =>
              t.accountId.equals(accountId) &
              t.sourceItemHmac.equals(sourceItemHmac),
        ))
      .go();
  await db.batch((b) => b.insertAll(db.cardSources, rows));
  await _recomputeCards(db, accountId, {
    ...old,
    for (final r in rows) r.cardId.value,
  });
}

/// SQLite's default limit of host parameters is 999; stay well below.
const _chunk = 400;

Future<void> _recomputeCards(
  AppDatabase db,
  String accountId,
  Set<String> cardIds,
) async {
  final ids = cardIds.toList();
  for (var i = 0; i < ids.length; i += _chunk) {
    final chunk = ids.sublist(i, (i + _chunk).clamp(0, ids.length));
    final sources = await (db.select(db.cardSources)
          ..where(
            (t) => t.accountId.equals(accountId) & t.cardId.isIn(chunk),
          ))
        .get();
    final winners = <String, CardSourceRow>{};
    for (final s in sources) {
      final known = winners[s.cardId];
      if (known == null || _beats(s, known)) winners[s.cardId] = s;
    }
    await db.batch((b) {
      for (final id in chunk) {
        final w = winners[id];
        if (w == null) {
          b.deleteWhere(
            db.cards,
            (t) => t.accountId.equals(accountId) & t.cardId.equals(id),
          );
          continue;
        }
        b.insert(
          db.cards,
          CardsCompanion.insert(
            accountId: accountId,
            cardId: id,
            collectionId: w.collectionId,
            sourceItemHmac: w.sourceItemHmac,
            sourceKind: w.sourceKind,
            h: w.h,
            deleted: Value(w.deleted),
            front: Value(w.front),
            back: Value(w.back),
            tagsJson: Value(w.tagsJson),
            hasConflict: Value(w.hasConflict),
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }
}

/// The highest `h` wins; on a tie a `card` doc beats a batch member, then
/// the greater source item HMAC — the same on every device.
bool _beats(CardSourceRow a, CardSourceRow b) {
  final byH = a.h.compareTo(b.h);
  if (byH != 0) return byH > 0;
  if (a.sourceKind != b.sourceKind) {
    return a.sourceKind == CardSourceKind.doc.name;
  }
  return a.sourceItemHmac.compareTo(b.sourceItemHmac) > 0;
}
