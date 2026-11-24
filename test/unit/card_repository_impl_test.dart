import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/encrypted_objects/card_object.dart';
import 'package:sharedinbox/core/models/card.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';

import 'encrypted_objects/test_helpers.dart';
import 'helpers/card_test_device.dart';
import 'helpers/fake_object_account.dart';
import 'helpers/stateful_fake_imap.dart';

const _acc = fakeObjectAccountId;
const _dataPath = fakeObjectDataPath;

void main() {
  late StatefulFakeImapServer server;
  late SharedCollectionKeys keys;
  setUpFakeObjectServer(
    (s, k) => (server, keys) = (s, k),
  );

  Future<(CardTestDevice, CardTestDevice, Deck)> twoDevicesWithDeck() async {
    final a = await CardTestDevice.open(server, keys);
    final b = await CardTestDevice.open(server, keys);
    final deck = await a.repo.createDeck(_acc, 'Spanish');
    await a.store.waitForIdle();
    return (a, b, deck);
  }

  test('a deck is its own collection; a rename reaches the other device',
      () async {
    final (a, b, deck) = await twoDevicesWithDeck();
    expect(deck.deckId, startsWith('deck-'));
    expect(keys.byCollection.keys, [deck.deckId]);
    expect(deck.name, 'Spanish');

    await b.sync();
    expect((await b.repo.observeDecks(_acc).first).single.name, 'Spanish');

    await b.repo.renameDeck(_acc, deck.deckId, 'Español');
    await b.store.waitForIdle();
    await a.sync();
    final decks = await a.repo.observeDecks(_acc).first;
    expect(decks.single.name, 'Español');
    expect(decks.single.hasConflict, isFalse);
    expect(
      () => a.repo.renameDeck(_acc, 'deck-none', 'x'),
      throwsStateError,
    );
  });

  test('an import of 1 000 cards is 2 batch mails; B sees every card',
      () async {
    final (a, b, deck) = await twoDevicesWithDeck();
    final ids =
        await a.repo.importCards(_acc, deck.deckId, numberedCards(1000));
    await a.store.waitForIdle();
    expect(ids, hasLength(1000));
    expect(await a.heads(cardBatchKind), hasLength(2));
    // 1 deck doc + 2 batches.
    expect(server.messagesIn(_dataPath), hasLength(3));

    await b.sync();
    final onB = await b.cards(deck.deckId);
    expect(onB, hasLength(1000));
    expect(onB.first.front, 'Q0');
    expect(onB.first.sourceKind, CardSourceKind.batch);
  });

  test(
      'B edits one member and deletes another; A shows both, the batch '
      'mails stay as they are', () async {
    final (a, b, deck) = await twoDevicesWithDeck();
    await a.repo.importCards(_acc, deck.deckId, numberedCards(3));
    await a.store.waitForIdle();
    await b.sync();
    final batch = (await b.heads(cardBatchKind)).single;

    await b.repo.editCard(
      _acc,
      'c0000',
      const CardContent(front: 'edited', back: 'A0', tags: ['x']),
    );
    await b.repo.deleteCard(_acc, 'c0001');
    await b.store.waitForIdle();
    await b.sync();
    await a.sync();

    final onA = await a.cards(deck.deckId);
    expect(onA.map((c) => c.cardId), ['c0000', 'c0002']);
    expect(onA.first.front, 'edited');
    expect(onA.first.tags, ['x']);
    expect(onA.first.sourceKind, CardSourceKind.doc);
    expect(await a.repo.card(_acc, 'c0001'), isNull);
    expect(
      [for (final r in await a.heads(cardBatchKind)) r.messageId],
      [batch.messageId],
    );

    // A second edit and a delete of a card that has a doc.
    await a.repo.editCard(
      _acc,
      'c0000',
      const CardContent(front: 'again', back: 'A0'),
    );
    await a.repo.deleteCard(_acc, 'c0000');
    await a.store.waitForIdle();
    expect(await a.fronts(deck.deckId), {'c0002': 'Q2'});
    // Deleted, then edited again: back.
    await a.repo.editCard(
      _acc,
      'c0001',
      const CardContent(front: 'back', back: 'A1'),
    );
    expect(await a.fronts(deck.deckId), {'c0001': 'back', 'c0002': 'Q2'});
  });

  test(
      'concurrent rewrites of one batch merge per cardId; the next rewrite '
      'collapses them', () async {
    final (a, b, deck) = await twoDevicesWithDeck();
    await a.repo.importCards(_acc, deck.deckId, numberedCards(3));
    await a.store.waitForIdle();
    await b.sync();
    final hmac = (await a.heads(cardBatchKind)).single.itemHmac!;

    await a.repo.rewriteBatch(_acc, hmac, {
      'c0000': const CardContent(front: 'A0 by A', back: 'A0'),
      'c0001': const CardContent(front: 'A1 by A', back: 'A1'),
    });
    await a.store.waitForIdle();
    // B's change of the shared member is the later one.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await b.repo.rewriteBatch(_acc, hmac, {
      'c0001': const CardContent(front: 'A1 by B', back: 'A1'),
      'c0002': const CardContent(front: 'A2 by B', back: 'A2'),
    });
    await b.store.waitForIdle();
    await b.sync();
    await a.sync();

    for (final d in [a, b]) {
      final rows = await d.heads(cardBatchKind);
      expect(rows, hasLength(2));
      expect(rows.map((r) => r.conflictOf), everyElement(isNull));
      expect(await d.store.observeConflicts(_acc).first, isEmpty);
      expect(await d.fronts(deck.deckId), {
        'c0000': 'A0 by A',
        'c0001': 'A1 by B',
        'c0002': 'A2 by B',
      });
      expect(
        (await d.cards(deck.deckId)).map((c) => c.hasConflict),
        everyElement(isFalse),
      );
    }

    await a.repo.rewriteBatch(_acc, hmac, {
      'new1': const CardContent(front: 'added', back: 'n'),
    });
    await a.store.waitForIdle();
    await b.sync();
    expect(await b.heads(cardBatchKind), hasLength(1));
    expect(
      server.messagesIn(_dataPath).length,
      2,
      reason: 'the deck doc and one batch',
    );
    expect((await b.fronts(deck.deckId))['new1'], 'added');
    expect((await b.fronts(deck.deckId))['c0001'], 'A1 by B');
  });

  test('addCard writes a card doc; unknown ids throw', () async {
    final (a, _, deck) = await twoDevicesWithDeck();
    final card = await a.repo.addCard(
      _acc,
      deck.deckId,
      const NewCard(CardContent(front: 'f', back: 'b', tags: ['t'])),
    );
    expect(card.sourceKind, CardSourceKind.doc);
    expect(card.tags, ['t']);
    expect(await a.heads(cardKind), hasLength(1));
    expect(
      () => a.repo.editCard(
        _acc,
        'nope',
        const CardContent(front: '', back: ''),
      ),
      throwsStateError,
    );
    expect(
      () => a.repo.rewriteBatch(_acc, 'nope', const {}),
      throwsStateError,
    );
  });

  test(
      'deleteDeck tombstones every card (batch members and docs) and the '
      'deck; the other device sees it gone', () async {
    final (a, b, deck) = await twoDevicesWithDeck();
    final keep = await a.repo.createDeck(_acc, 'Keep');
    await a.repo.importCards(_acc, deck.deckId, numberedCards(3));
    await a.repo.addCard(
      _acc,
      deck.deckId,
      const NewCard(CardContent(front: 'solo', back: 'b'), cardId: 'solo'),
    );
    await a.repo.deleteCard(_acc, 'c0001');
    await a.repo.addCard(
      _acc,
      keep.deckId,
      const NewCard(CardContent(front: 'k', back: 'b'), cardId: 'kept'),
    );
    await a.store.waitForIdle();
    expect(await a.repo.cardCount(_acc, deck.deckId), 3);
    await b.sync();
    expect(await b.cards(deck.deckId), hasLength(3));

    await a.repo.deleteDeck(_acc, deck.deckId);
    await a.store.waitForIdle();
    expect(await a.cards(deck.deckId), isEmpty);
    expect(await a.repo.cardCount(_acc, deck.deckId), 0);
    expect(
      [for (final d in await a.repo.observeDecks(_acc).first) d.name],
      ['Keep'],
    );
    // The collection key stays.
    expect(keys.byCollection, contains(deck.deckId));

    await b.sync();
    expect(await b.cards(deck.deckId), isEmpty);
    expect(
      [for (final d in await b.repo.observeDecks(_acc).first) d.name],
      ['Keep'],
    );
    expect((await b.cards(keep.deckId)).single.cardId, 'kept');
    expect(
      () => a.repo.deleteDeck(_acc, deck.deckId),
      throwsStateError,
    );
  });

  test('deleteDeck without the deck key throws and writes nothing', () async {
    final (a, _, deck) = await twoDevicesWithDeck();
    await a.repo.importCards(_acc, deck.deckId, numberedCards(2));
    await a.store.waitForIdle();
    keys.byCollection.clear();
    await expectLater(
      a.repo.deleteDeck(_acc, deck.deckId),
      throwsA(isA<NoWriteKeyException>()),
    );
    expect(await a.repo.cardCount(_acc, deck.deckId), 2);
    expect(await a.repo.observeDecks(_acc).first, hasLength(1));
  });

  test('a device without the deck key cannot edit its cards', () async {
    final (a, _, deck) = await twoDevicesWithDeck();
    await a.repo.importCards(_acc, deck.deckId, numberedCards(1));
    await a.store.waitForIdle();
    keys.byCollection.clear();
    expect(
      () => a.repo.deleteCard(_acc, 'c0000'),
      throwsA(isA<NoWriteKeyException>()),
    );
  });
}
