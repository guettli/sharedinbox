// Backend tests for flash cards and decks (#1379) against a real Stalwart:
// two devices of one account, the key set up on A and unlocked on B with
// the recovery key. A deck is its own collection; an import of 1 000 cards
// is two `card-batch` mails; an edit and a delete of a member on one device
// reach the other; concurrent rewrites of one batch merge per cardId. Each
// device has its own database, secure storage, key ring, store with the
// card projections, and card repository.
// Run via: task test-backend

import 'package:sharedinbox/core/encrypted_objects/card_object.dart';
import 'package:sharedinbox/core/encrypted_objects/key_mail_message.dart';
import 'package:sharedinbox/core/models/card.dart';
import 'package:sharedinbox/core/services/encrypted_key_service.dart';
import 'package:sharedinbox/data/repositories/card_projector.dart';
import 'package:sharedinbox/data/repositories/card_repository_impl.dart';
import 'package:test/test.dart';

import 'key_device_harness.dart';

void main() {
  final pool = setUpKeyPool();

  Future<_CardDevice> device() =>
      addKeyDevice(pool(), _CardDevice(pool().account));

  /// A with a new key and deck holding [cards], B unlocked with A's
  /// recovery key and synced.
  Future<(_CardDevice, _CardDevice, Deck)> twoDevicesWithDeck(
    int cards,
  ) async {
    final a = await device();
    final created = await a.service.createKey(a.id) as KeyCreated;
    final deck = await a.repo.createDeck(a.id, 'Spanish');
    await a.repo.importCards(a.id, deck.deckId, numberedCards(cards));
    await a.store.waitForIdle();
    await a.listAndSync();
    final b = await device();
    await b.listAndSync();
    await b.service.unlockWithRecoveryKey(b.id, created.formatted);
    await b.listAndSync();
    return (a, b, deck);
  }

  test(
      'an import of 1 000 cards is 2 batch mails; B sees the deck and every '
      'card without fetching a body on demand', () async {
    final (a, b, deck) = await twoDevicesWithDeck(1000);

    final batches = await a.store.rowsOfKind(a.id, cardBatchKind);
    final decks = await a.store.rowsOfKind(a.id, deckKind);
    expect(batches, hasLength(2));
    expect(decks, hasLength(1));
    expect(
      (await pool().rawMails(dataPath)).keys.toSet(),
      {
        for (final r in [...batches, ...decks]) r.messageId,
      },
    );
    // The account key mail and two collection keys: personal and the deck.
    final keyMails = [
      for (final raw in (await pool().rawMails(keysPath)).values)
        parseKeyMailMessage(raw),
    ];
    expect(keyMails.whereType<CollectionKeyMailMsg>(), hasLength(2));
    expect(keyMails.whereType<AccountKeyMailMsg>(), hasLength(1));

    expect((await b.repo.observeDecks(b.id).first).single.name, 'Spanish');
    final cards = await b.cards(deck.deckId);
    expect(cards, hasLength(1000));
    expect(cards.first.front, 'Q0');
    expect(cards.last.back, 'A999');
    final rows = await b.store.rowsOfKind(b.id, cardBatchKind);
    expect(rows, hasLength(2));
    expect(rows.every((r) => r.payload != null), isTrue);
  });

  test(
      'B edits one member and deletes another; A shows both, the batch '
      'mails are unchanged', () async {
    final (a, b, deck) = await twoDevicesWithDeck(3);
    final batch = (await a.store.rowsOfKind(a.id, cardBatchKind)).single;

    await b.repo.editCard(
      b.id,
      'c0000',
      const CardContent(front: 'edited on B', back: 'A0'),
    );
    await b.repo.deleteCard(b.id, 'c0001');
    await b.store.waitForIdle();
    await b.listAndSync();
    await a.listAndSync();

    expect(await a.fronts(deck.deckId), {
      'c0000': 'edited on B',
      'c0002': 'Q2',
    });
    expect(
      (await a.store.rowsOfKind(a.id, cardBatchKind)).map((r) => r.messageId),
      [batch.messageId],
    );
    expect(
      (await pool().rawMails(dataPath)).keys,
      contains(batch.messageId),
    );
    expect(await a.store.rowsOfKind(a.id, cardKind), hasLength(2));
  });

  test(
      'concurrent rewrites of one batch merge per cardId without a '
      'conflict; the next rewrite collapses them to one mail', () async {
    final (a, b, deck) = await twoDevicesWithDeck(3);
    final hmac =
        (await a.store.rowsOfKind(a.id, cardBatchKind)).single.itemHmac!;

    // Neither device has seen the other's rewrite.
    await a.repo.rewriteBatch(a.id, hmac, {
      'c0000': const CardContent(front: 'A0 by A', back: 'A0'),
      'c0001': const CardContent(front: 'A1 by A', back: 'A1'),
    });
    await a.store.waitForIdle();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await b.repo.rewriteBatch(b.id, hmac, {
      'c0001': const CardContent(front: 'A1 by B', back: 'A1'),
      'c0002': const CardContent(front: 'A2 by B', back: 'A2'),
    });
    await b.store.waitForIdle();
    await b.listAndSync();
    await a.listAndSync();

    for (final d in [a, b]) {
      final heads = await d.store.rowsOfKind(d.id, cardBatchKind);
      expect(heads, hasLength(2));
      expect(heads.map((r) => r.conflictOf), everyElement(isNull));
      expect(await d.fronts(deck.deckId), {
        'c0000': 'A0 by A',
        'c0001': 'A1 by B',
        'c0002': 'A2 by B',
      });
    }

    await a.repo.rewriteBatch(a.id, hmac, const {});
    await a.store.waitForIdle();
    await a.listAndSync();
    await b.listAndSync();
    expect(await b.store.rowsOfKind(b.id, cardBatchKind), hasLength(1));
    expect(await pool().rawMails(dataPath), hasLength(2));
    expect((await b.fronts(deck.deckId))['c0001'], 'A1 by B');
  });
}

/// A [KeyDevice] whose store writes the card projections, with the card
/// repository on top.
class _CardDevice extends ProjectingKeyDevice {
  _CardDevice(super.account)
      : super(
          projectors: (db) => [
            CardDocProjector(db),
            CardBatchProjector(db),
            DeckProjector(db),
          ],
        );

  late final repo = CardRepositoryImpl(
    db,
    store,
    ensureCollection: service.ensureCollection,
  );

  Future<List<FlashCard>> cards(String deckId) =>
      repo.observeCards(id, deckId).first;

  Future<Map<String, String>> fronts(String deckId) async =>
      {for (final c in await cards(deckId)) c.cardId: c.front};
}
