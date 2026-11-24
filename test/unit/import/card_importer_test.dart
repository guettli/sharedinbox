import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:sharedinbox/core/import/import_ids.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/card.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/data/import/card_importer.dart';
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/card_projector.dart';
import 'package:sharedinbox/data/repositories/card_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mail_object_blobs.dart';
import 'package:sharedinbox/data/repositories/mail_object_store_imap.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';

import '../db_test_helper.dart';
import '../helpers/fake_secure_storage.dart';
import '../helpers/stateful_fake_imap.dart';

const _acc = 'acc-1';
const _dataPath = 'SharedInbox/Data';

const _account = Account(
  id: _acc,
  displayName: 'Alice',
  email: 'alice@example.com',
  imapHost: 'imap.example.com',
  smtpHost: 'smtp.example.com',
);

Uint8List _fixture(String name) =>
    File('test/fixtures/anki/$name').readAsBytesSync();

/// One install with the card projections and the blob store over a fake
/// IMAP server; collection keys are made on demand.
class _Device {
  _Device(this.server);

  final StatefulFakeImapServer server;
  final keys = <String, CollectionKey>{};
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
    keyLookup: (_, keyId) {
      for (final k in keys.values) {
        if (constantTimeEquals(k.keyId, keyId)) return k;
      }
      return null;
    },
    writeKey: (_, collectionId) => keys[collectionId],
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
      keys[collectionId] ??= CollectionKey.generate(collectionId);
    },
  );
  late final blobs = MailObjectBlobStore(db, store);
  late final importer = CardImporterImpl(repo, blobs);

  static Future<String> _namespace(Object client) =>
      (client as StatefulFakeImapClient).namespace();

  static Future<_Device> open(StatefulFakeImapServer server) async {
    final device = _Device(server);
    addTearDown(() async {
      await device.store.waitForIdle();
      await device.db.close();
    });
    await device.accounts.addAccount(_account, 'pw');
    return device;
  }

  Future<List<FlashCard>> allCards() async => [
        for (final d in await repo.observeDecks(_acc).first)
          ...await repo.observeCards(_acc, d.deckId).first,
      ];

  Future<int> serverMessages() async {
    await store.waitForIdle();
    return server.messagesIn(_dataPath).length;
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  late _Device device;

  setUp(() async {
    device = await _Device.open(
      StatefulFakeImapServer(uidValidityByFolder: {'INBOX': 1}),
    );
  });

  test('basic.apkg: 7 cards in 1 deck, the image blob in that deck', () async {
    final result = await device.importer.importApkg(
      _acc,
      _fixture('basic.apkg'),
    );
    expect(result.added, 7);
    expect(result.skippedCloze, 1);
    expect(result.droppedSounds, 1);
    expect(result.decks, ['Lang::German']);

    final decks = await device.repo.observeDecks(_acc).first;
    expect(decks.single.name, 'Lang::German');
    final cards = await device.allCards();
    expect(cards, hasLength(7));
    expect(cards.map((c) => c.deckId).toSet(), {decks.single.deckId});
    final cat = cards.singleWhere((c) => c.front.startsWith('Katze'));
    final blobId = RegExp(r'si-img:(\S+)\)').firstMatch(cat.front)!.group(1)!;
    final blob = await device.blobs.blob(_acc, decks.single.deckId, blobId);
    expect(blob!.contentType, 'image/png');
    expect(mediaBlobId(blob.bytes), blobId);
  });

  test('re-importing the same file writes nothing', () async {
    await device.importer.importApkg(_acc, _fixture('basic.apkg'));
    final before = await device.serverMessages();
    final blobs = await device.store.rowsOfKind(_acc, mailObjectBlobKind);

    final again = await device.importer.importApkg(
      _acc,
      _fixture('basic.apkg'),
    );
    expect(again.added, 0);
    expect(again.updated, 0);
    expect(again.unchanged, 7);
    expect(await device.serverMessages(), before);
    expect(
      await device.store.rowsOfKind(_acc, mailObjectBlobKind),
      hasLength(blobs.length),
    );
    expect(await device.allCards(), hasLength(7));
  });

  test('basic_v2.apkg updates the changed card and adds the new note',
      () async {
    await device.importer.importApkg(_acc, _fixture('basic.apkg'));
    final result = await device.importer.importApkg(
      _acc,
      _fixture('basic_v2.apkg'),
    );
    expect(result.added, 2);
    expect(result.updated, 1);
    expect(result.unchanged, 6);

    final cards = await device.allCards();
    expect(cards, hasLength(9));
    expect(cards.map((c) => c.cardId).toSet(), hasLength(9));
    expect(await device.repo.observeDecks(_acc).first, hasLength(1));
    final hund = await device.repo.card(_acc, ankiCardId('basic-1', 0));
    expect(hund!.back, 'dog\na loyal pet');
    // The image is in the deck once.
    expect(
      await device.store.rowsOfKind(_acc, mailObjectBlobKind),
      hasLength(1),
    );
  });

  test('a card deleted here stays deleted after a re-import', () async {
    await device.importer.importApkg(_acc, _fixture('basic.apkg'));
    final id = ankiCardId('rev-1', 1);
    await device.repo.deleteCard(_acc, id);

    final result = await device.importer.importApkg(
      _acc,
      _fixture('basic_v2.apkg'),
    );
    expect(result.skippedDeleted, 1);
    expect(await device.repo.card(_acc, id), isNull);
    expect(await device.repo.cardState(_acc, id), isA<CardDeleted>());
    expect(await device.allCards(), hasLength(8));
  });

  test('a CSV import twice adds no duplicates; a changed back updates',
      () async {
    final text = File('test/fixtures/cards.csv').readAsStringSync();
    final first = await device.importer.importCsv(_acc, text);
    expect(first.added, 7);
    expect(first.skippedEmpty, 1);
    expect(
      (await device.repo.observeDecks(_acc).first).map((d) => d.name),
      ['Asia', 'Default', 'Deutsch::Präpositionen', 'German'],
    );

    final again = await device.importer.importCsv(_acc, text);
    expect(again.added, 0);
    expect(again.unchanged, 7);

    final changed = await device.importer.importCsv(
      _acc,
      text.replaceFirst('Hallo,hello', 'Hallo,hi there'),
    );
    expect(changed.updated, 1);
    final cards = await device.allCards();
    expect(cards, hasLength(7));
    expect(
      cards.singleWhere((c) => c.front == 'Hallo').back,
      'hi there',
    );
  });
}
