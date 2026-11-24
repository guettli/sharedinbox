import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/import/import_ids.dart';
import 'package:sharedinbox/core/models/card.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/data/import/card_importer.dart';
import 'package:sharedinbox/data/repositories/mail_object_blobs.dart';

import '../helpers/card_test_device.dart';
import '../helpers/fake_object_account.dart';
import '../helpers/stateful_fake_imap.dart';

const _acc = fakeObjectAccountId;
const _dataPath = fakeObjectDataPath;

Uint8List _fixture(String name) =>
    File('test/fixtures/anki/$name').readAsBytesSync();

/// A [CardTestDevice] with the blob store and the importer.
class _Device extends CardTestDevice {
  _Device(StatefulFakeImapServer server)
      : super(server, SharedCollectionKeys());

  late final blobs = MailObjectBlobStore(db, store);
  late final importer = CardImporterImpl(repo, blobs);

  Future<List<FlashCard>> allCards() async => [
        for (final d in await repo.observeDecks(_acc).first)
          ...await cards(d.deckId),
      ];

  Future<int> serverMessages() async {
    await store.waitForIdle();
    return server.messagesIn(_dataPath).length;
  }
}

void main() {
  late _Device device;
  setUpFakeObjectServer(
    (server, _) => device = _Device(server),
  );
  setUp(() => device.init<_Device>());

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
