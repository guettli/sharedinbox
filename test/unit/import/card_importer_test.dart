import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/log_segment.dart';
import 'package:sharedinbox/core/flashcards/card_replay.dart';
import 'package:sharedinbox/core/flashcards/fsrs.dart';
import 'package:sharedinbox/core/flashcards/review_event.dart';
import 'package:sharedinbox/core/import/import_ids.dart';
import 'package:sharedinbox/core/models/card.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/import/anki_apkg_reader.dart';
import 'package:sharedinbox/data/import/card_importer.dart';
import 'package:sharedinbox/data/import/review_importer.dart';
import 'package:sharedinbox/data/repositories/mail_object_blobs.dart';
import 'package:sharedinbox/data/repositories/mail_object_device_state.dart';
import 'package:sharedinbox/data/repositories/mail_object_log.dart';
import 'package:sharedinbox/data/repositories/review_log_rows.dart';
import 'package:sharedinbox/data/repositories/review_repository_impl.dart';
import 'package:sharedinbox/data/repositories/review_uploader.dart';

import '../helpers/card_test_device.dart';
import '../helpers/fake_object_account.dart';
import '../helpers/stateful_fake_imap.dart';

const _acc = fakeObjectAccountId;
const _dataPath = fakeObjectDataPath;

Uint8List _fixture(String name) =>
    File('test/fixtures/anki/$name').readAsBytesSync();

/// A [CardTestDevice] with the blob store, the importer and the reviews.
class _Device extends CardTestDevice {
  _Device(super.server, super.keys);

  late final blobs = MailObjectBlobStore(db, store);
  late final log = MailObjectLog(db, store);
  late final importer = CardImporterImpl(repo, blobs, ReviewImporter(db, log));
  late final reviews =
      ReviewRepositoryImpl(db, store, deviceState: DeviceStateStore(db, store));

  Future<List<ReviewLogRow>> reviewRows() =>
      (db.select(db.reviewLog)..orderBy([(t) => OrderingTerm.asc(t.h)])).get();

  Future<CardSchedule?> schedule(String cardId) =>
      reviews.observeSchedule(_acc, cardId).first;

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
  late StatefulFakeImapServer server;
  late SharedCollectionKeys keys;
  late _Device device;
  setUpFakeObjectServer(
    (s, k) {
      (server, keys) = (s, k);
      device = _Device(s, k);
    },
    collections: const [personalCollectionId],
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

  group('review history (#1385)', () {
    late List<ReviewEvent> events;
    late String deviceId;
    setUp(() async {
      final anki = await readApkg(_fixture('reviews.apkg'));
      events = anki.reviews;
      deviceId = anki.reviewDeviceId;
    });

    Map<String, List<ReviewEvent>> byCard(Iterable<ReviewEvent> events) {
      final out = <String, List<ReviewEvent>>{};
      for (final e in events) {
        (out[e.cardId] ??= []).add(e);
      }
      return out;
    }

    test('the revlog becomes review_log rows in segments of the import id',
        () async {
      final result = await device.importer.importApkg(
        _acc,
        _fixture('reviews.apkg'),
      );
      expect(result.added, 3);
      expect(result.reviewsAdded, 10);
      expect(result.reviewsKnown, 0);
      expect(result.skippedReviews, 7);

      final rows = await device.reviewRows();
      expect(rows, hasLength(10));
      expect(rows.map((r) => r.deviceId).toSet(), {deviceId});
      expect(rows.map(cardEventOf), events);
      // In a segment already: nothing pending for the uploader.
      expect(rows.every((r) => r.segmentItemId != null), isTrue);
      expect(await ReviewUploader(device.db, device.log).flush(_acc), 0);

      final segments = await device.heads(segKind(reviewLogName));
      expect(segments, hasLength(1));
      final segment = readSegment((await device.store.open(segments.single))!)!;
      expect(segment.head.device, deviceId);
      expect(segment.head.covers, hasLength(10));
      expect(
        Hlc.parse(segments.single.versionId!).deviceId,
        (await device.store.clockFor(_acc)).deviceId,
      );
    });

    test('a re-import adds no events and writes no segment', () async {
      await device.importer.importApkg(_acc, _fixture('reviews.apkg'));
      final before = await device.serverMessages();

      final again = await device.importer.importApkg(
        _acc,
        _fixture('reviews.apkg'),
      );
      expect(again.reviewsAdded, 0);
      expect(again.reviewsKnown, 10);
      expect(await device.reviewRows(), hasLength(10));
      expect(await device.heads(segKind(reviewLogName)), hasLength(1));
      expect(await device.serverMessages(), before);
    });

    test('the schedules are the FSRS replay of the imported events', () async {
      await device.importer.importApkg(_acc, _fixture('reviews.apkg'));
      final cards = byCard(events);
      expect(cards, hasLength(3));
      for (final MapEntry(key: cardId, value: reviews) in cards.entries) {
        final schedule = await device.schedule(cardId);
        expect(schedule, isNotNull);
        expect(
          schedule,
          replayCard(cardId, reviews, params: FsrsParams()),
          reason: cardId,
        );
        expect(schedule!.lastReviewMs, reviews.last.t);
      }
    });

    test('a card deleted here gets no events', () async {
      final deck = await device.repo.createDeck(_acc, 'Lang::German');
      final id = ankiCardId('rv-3', 0);
      await device.repo.addCard(
        _acc,
        deck.deckId,
        NewCard(const CardContent(front: 'drei', back: 'three'), cardId: id),
      );
      await device.repo.deleteCard(_acc, id);

      final result = await device.importer.importApkg(
        _acc,
        _fixture('reviews.apkg'),
      );
      expect(result.skippedDeleted, 1);
      expect(result.reviewsAdded, 8);
      expect(result.skippedReviews, 9);
      final rows = await device.reviewRows();
      expect(rows.where((r) => r.cardId == id), isEmpty);
      expect(await device.schedule(id), isNull);
    });

    test('two installs importing the same file: each event once after sync',
        () async {
      final b = await _Device(server, keys).init<_Device>();
      await device.importer.importApkg(_acc, _fixture('reviews.apkg'));
      await b.importer.importApkg(_acc, _fixture('reviews.apkg'));
      await device.sync();
      await b.sync();
      await device.sync();

      for (final d in [device, b]) {
        final rows = await d.reviewRows();
        expect(rows.map(cardEventOf), events);
        final logged = await d.log.events(_acc, reviewLogName);
        expect(logged.map((e) => (e.deviceId, e.seq)).toSet(), hasLength(10));
        expect(logged, hasLength(10));
        expect(await d.heads(segKind(reviewLogName)), hasLength(2));
      }
    });

    test('a later local rating is replayed after the imported history',
        () async {
      await device.importer.importApkg(_acc, _fixture('reviews.apkg'));
      final id = ankiCardId('rv-1', 0);
      final local = await device.reviews.rate(_acc, id, Rating.again);
      final imported = byCard(events)[id]!;
      expect(local.h.compareTo(imported.last.h), greaterThan(0));

      final schedule = await device.schedule(id);
      expect(
        schedule,
        replayCard(id, [...imported, local], params: FsrsParams()),
      );
      expect(schedule!.lastReviewMs, local.t);
      expect(schedule.lapses, greaterThan(0));
    });
  });
}
