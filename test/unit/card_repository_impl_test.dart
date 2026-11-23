import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/encrypted_objects/card_object.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/card.dart';
import 'package:sharedinbox/core/models/mail_object.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/card_projector.dart';
import 'package:sharedinbox/data/repositories/card_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mail_object_store_imap.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';

import 'db_test_helper.dart';
import 'helpers/fake_secure_storage.dart';
import 'helpers/stateful_fake_imap.dart';

const _acc = 'acc-1';
const _dataPath = 'SharedInbox/Data';

const _account = Account(
  id: _acc,
  displayName: 'Alice',
  email: 'alice@example.com',
  imapHost: 'imap.example.com',
  smtpHost: 'smtp.example.com',
);

/// The collection keys of the account, as the key lifecycle shares them
/// between devices through the keys folder.
class _Keys {
  final byCollection = <String, CollectionKey>{};

  CollectionKey? lookup(Uint8List keyId) {
    for (final k in byCollection.values) {
      if (constantTimeEquals(k.keyId, keyId)) return k;
    }
    return null;
  }
}

/// One install with the card projections, talking to the shared fake
/// [server].
class _CardDevice {
  _CardDevice(this.server, this.keys);

  final StatefulFakeImapServer server;
  final _Keys keys;
  final db = openTestDatabase();
  final storage = FakeSecureStorage();
  late final accounts = AccountRepositoryImpl(db, storage);
  late final mailboxes = MailboxRepositoryImpl(
    db,
    accounts,
    imapConnect: (_, __, ___) async => server.connect(),
    namespace: _namespace,
  );
  late final store = MailObjectStoreImap(
    db,
    accounts,
    mailboxes,
    storage,
    imapConnect: (_, __, ___) async => server.connect(),
    namespace: _namespace,
    keyLookup: (_, keyId) => keys.lookup(keyId),
    writeKey: (_, collectionId) => keys.byCollection[collectionId],
    projectors: [
      CardDocProjector(db),
      CardBatchProjector(db),
      DeckProjector(db),
    ],
  );
  late final repo = CardRepositoryImpl(
    db,
    store,
    ensureCollection: (_, collectionId) async {
      keys.byCollection[collectionId] ??= CollectionKey.generate(collectionId);
    },
  );

  static Future<String> _namespace(Object client) =>
      (client as StatefulFakeImapClient).namespace();

  static Future<_CardDevice> open(
    StatefulFakeImapServer server,
    _Keys keys,
  ) async {
    final device = _CardDevice(server, keys);
    addTearDown(() async {
      await device.store.waitForIdle();
      await device.db.close();
    });
    await device.accounts.addAccount(_account, 'pw');
    return device;
  }

  Future<void> sync() async {
    await mailboxes.syncMailboxes(_acc);
    await store.sync(_acc);
    await store.waitForIdle();
  }

  Future<List<FlashCard>> cards(String deckId) =>
      repo.observeCards(_acc, deckId).first;

  Future<Map<String, String>> fronts(String deckId) async =>
      {for (final c in await cards(deckId)) c.cardId: c.front};

  Future<List<MailObject>> heads(String kind) => store.rowsOfKind(_acc, kind);
}

List<NewCard> _cards(int n) => [
      for (var i = 0; i < n; i++)
        NewCard(
          CardContent(front: 'Q$i', back: 'A$i'),
          cardId: 'c${i.toString().padLeft(4, '0')}',
        ),
    ];

void main() {
  setUpAll(configureSqliteForTests);

  late StatefulFakeImapServer server;
  late _Keys keys;

  setUp(() {
    server = StatefulFakeImapServer(uidValidityByFolder: {'INBOX': 1});
    keys = _Keys();
  });

  Future<(_CardDevice, _CardDevice, Deck)> twoDevicesWithDeck() async {
    final a = await _CardDevice.open(server, keys);
    final b = await _CardDevice.open(server, keys);
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
    final ids = await a.repo.importCards(_acc, deck.deckId, _cards(1000));
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
    await a.repo.importCards(_acc, deck.deckId, _cards(3));
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
    await a.repo.importCards(_acc, deck.deckId, _cards(3));
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

  test('a device without the deck key cannot edit its cards', () async {
    final (a, _, deck) = await twoDevicesWithDeck();
    await a.repo.importCards(_acc, deck.deckId, _cards(1));
    await a.store.waitForIdle();
    keys.byCollection.clear();
    expect(
      () => a.repo.deleteCard(_acc, 'c0000'),
      throwsA(isA<NoWriteKeyException>()),
    );
  });
}
