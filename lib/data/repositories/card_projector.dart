import 'dart:convert';

import 'package:drift/drift.dart';

import 'package:sharedinbox/core/encrypted_objects/card_object.dart';
import 'package:sharedinbox/core/models/card.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/card_schedule_writer.dart';

/// Writes the `CardSources` rows of the `card` docs (#1379): one row per
/// doc. Runs inside the store's merge transaction ([ObjectProjector]). A
/// card whose deck changes (e.g. it arrives after its reviews) gets its
/// schedule recomputed with the params of the deck (#1380).
class CardDocProjector extends ObjectProjector {
  CardDocProjector(this.db, {CardScheduleWriter? schedules})
      : schedules = schedules ?? CardScheduleWriter(db);

  final AppDatabase db;
  final CardScheduleWriter schedules;

  @override
  String get kind => cardKind;

  /// The newest head that is not a tombstone, so an edit racing a delete
  /// stays visible as a conflict; once every head is a tombstone, the
  /// newest tombstone as `deleted`, so it beats older batch members.
  @override
  Future<void> apply(
    String accountId,
    String itemHmac,
    ProjectedItem item,
  ) async {
    final display = item.display;
    final shown = display ?? item.heads.lastOrNull;
    final content = shown == null ? null : cardContentOf(shown);
    final moved = await replaceCardSources(db, accountId, itemHmac, [
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
          hasConflict: Value(item.conflict),
        ),
    ]);
    await schedules.recompute(accountId, moved);
  }
}

/// Writes the `CardSources` rows of the `card-batch` docs (#1379): one row
/// per member of [mergeBatchMembers] over all heads. Its heads merge by
/// themselves ([mergesHeads]): never a conflict. Like [CardDocProjector]
/// it recomputes the schedules of cards whose deck changes.
class CardBatchProjector extends ObjectProjector {
  CardBatchProjector(this.db, {CardScheduleWriter? schedules})
      : schedules = schedules ?? CardScheduleWriter(db);

  final AppDatabase db;
  final CardScheduleWriter schedules;

  @override
  String get kind => cardBatchKind;

  @override
  bool get mergesHeads => true;

  @override
  Future<void> apply(
    String accountId,
    String itemHmac,
    ProjectedItem item,
  ) async {
    final collectionId = item.display?.head.collectionId;
    final moved = await replaceCardSources(db, accountId, itemHmac, [
      if (collectionId != null)
        for (final m in mergeBatchMembers(item.heads))
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
    await schedules.recompute(accountId, moved);
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
    ProjectedItem item,
  ) async {
    final display = item.display;
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
            hasConflict: Value(item.conflict),
          ),
        );
  }
}

/// Replaces the `CardSources` rows of [sourceItemHmac] by [rows], then sets
/// the `Cards` row of every cardId they touch to its source with the
/// highest `h`; a cardId without a source left loses its row. Returns the
/// cardIds whose deck changed (a new, moved or removed row): their
/// schedules depend on it.
Future<Set<String>> replaceCardSources(
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
  return _recomputeCards(db, accountId, {
    ...old,
    for (final r in rows) r.cardId.value,
  });
}

/// SQLite's default limit of host parameters is 999; stay well below.
const _chunk = 400;

Future<Set<String>> _recomputeCards(
  AppDatabase db,
  String accountId,
  Set<String> cardIds,
) async {
  final ids = cardIds.toList();
  final moved = <String>{};
  for (var i = 0; i < ids.length; i += _chunk) {
    final chunk = ids.sublist(i, (i + _chunk).clamp(0, ids.length));
    final decks = {
      for (final c in await (db.select(db.cards)
            ..where(
              (t) => t.accountId.equals(accountId) & t.cardId.isIn(chunk),
            ))
          .get())
        c.cardId: c.collectionId,
    };
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
    moved.addAll([
      for (final id in chunk)
        if (decks[id] != winners[id]?.collectionId) id,
    ]);
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
  return moved;
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
