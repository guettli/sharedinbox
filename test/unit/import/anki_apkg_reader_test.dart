import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/import/card_import.dart';
import 'package:sharedinbox/core/import/import_ids.dart';
import 'package:sharedinbox/data/import/anki_apkg_reader.dart';

Uint8List _fixture(String name) =>
    File('test/fixtures/anki/$name').readAsBytesSync();

/// [b] imports exactly like [a].
void _expectSameImport(AnkiImport b, AnkiImport a) {
  expect(
    [for (final c in b.cards) (c.cardId, c.deckName, c.content)],
    [for (final c in a.cards) (c.cardId, c.deckName, c.content)],
  );
  expect(b.media.keys, a.media.keys);
  for (final MapEntry(:key, :value) in a.media.entries) {
    expect(b.media[key]!.bytes, value.bytes);
    expect(b.media[key]!.contentType, value.contentType);
  }
  expect(b.skippedCloze, a.skippedCloze);
  expect(b.skippedEmpty, a.skippedEmpty);
  expect(b.droppedSounds, a.droppedSounds);
  expect(b.missingMedia, a.missingMedia);
  expect(b.reviewDeviceId, a.reviewDeviceId);
  expect(b.reviews, a.reviews);
}

/// The zstd entries of [apkg] (raw blocks only) re-encoded with compressed
/// blocks.
Uint8List _recompressed(Uint8List apkg) {
  final out = Archive();
  for (final f in ZipDecoder().decodeBytes(apkg).files) {
    final data = f.readBytes()!;
    final zstd = const {'collection.anki21b', 'media', '0'}.contains(f.name);
    out.addFile(
      ArchiveFile.bytes(
        f.name,
        zstd
            ? ZstdEncoder().encodeBytes(ZstdDecoder().decodeBytes(data))
            : data,
      ),
    );
  }
  return ZipEncoder().encodeBytes(out);
}

void main() {
  test('basic.apkg: 7 cards (reversed notes twice), deck, tags, image',
      () async {
    final anki = await readApkg(_fixture('basic.apkg'));
    expect(anki.cards, hasLength(7));
    expect(anki.skippedCloze, 1);
    expect(anki.droppedSounds, 1);
    expect(anki.missingMedia, isEmpty);
    expect(anki.cards.map((c) => c.deckName).toSet(), {'Lang::German'});

    final byId = {for (final c in anki.cards) c.cardId: c.content};
    expect(byId.keys.toSet(), {
      ankiCardId('basic-1', 0),
      ankiCardId('basic-2', 0),
      ankiCardId('basic-3', 0),
      ankiCardId('rev-1', 0),
      ankiCardId('rev-1', 1),
      ankiCardId('rev-2', 0),
      ankiCardId('rev-2', 1),
    });

    final hund = byId[ankiCardId('basic-1', 0)]!;
    expect(hund.front, 'Hund');
    expect(hund.back, 'dog\na pet');
    expect(hund.tags, ['animal', 'noun']);

    final cat = byId[ankiCardId('basic-2', 0)]!;
    final png = anki.media.values.single;
    final blobId = mediaBlobId(png.bytes);
    expect(anki.media.keys.single, blobId);
    expect(png.contentType, 'image/png');
    expect(png.bytes.sublist(1, 4), 'PNG'.codeUnits);
    expect(cat.front, 'Katze ![](si-img:$blobId)');
    expect(cat.back, 'cat & kitten');

    expect(byId[ankiCardId('basic-3', 0)]!.front, '**Haus**');
    expect(byId[ankiCardId('basic-3', 0)]!.back, 'house');
    expect(byId[ankiCardId('basic-3', 0)]!.tags, isEmpty);

    // The reverse card shows the back on its front.
    expect(byId[ankiCardId('rev-1', 1)]!.front, 'good');
    expect(byId[ankiCardId('rev-1', 1)]!.back, 'gut');
    expect(byId[ankiCardId('rev-2', 0)]!.front, '*schnell*');
    expect(byId[ankiCardId('rev-2', 0)]!.back, 'fast\nquick');
  });

  test('collection.anki21 wins over the dummy collection.anki2', () async {
    final anki = await readApkg(_fixture('both.apkg'));
    expect(anki.cards, hasLength(7));
    expect(
      anki.cards.where((c) => c.content.front.contains('Please update')),
      isEmpty,
    );
  });

  test('reviews.apkg: the revlog of the imported cards as review events',
      () async {
    final anki = await readApkg(_fixture('reviews.apkg'));
    const t0 = 1735689600000;
    const minute = 60 * 1000;
    const hour = 60 * minute;
    const day = 24 * hour;
    final deviceId = ankiImportDeviceId(1700000000);
    expect(anki.reviewDeviceId, deviceId);
    expect(deviceId, startsWith('import:'));
    expect(anki.cards, hasLength(3));
    expect(anki.skippedCloze, 1);
    // rv-1: the rescheduled row; rv-2: 3 rows up to the reset and the
    // manual "set due"; the cloze card and the unknown cid.
    expect(anki.skippedReviews, 7);

    final seqs = {
      for (final e in anki.reviews) (e.cardId, e.seq),
    };
    expect(seqs, {
      for (final t in [
        t0,
        t0 + 10 * minute,
        t0 + day,
        t0 + 4 * day,
        t0 + 4 * day + 10 * minute,
        t0 + 5 * day,
      ])
        (ankiCardId('rv-1', 0), t),
      (ankiCardId('rv-2', 0), t0 + 3 * day + hour),
      (ankiCardId('rv-2', 0), t0 + 5 * day + hour),
      (ankiCardId('rv-3', 0), t0 + 2 * hour),
      (ankiCardId('rv-3', 0), t0 + 3 * day + 2 * hour),
    });
    expect(
      anki.reviews.map((e) => e.seq),
      [...anki.reviews.map((e) => e.seq)]..sort(),
    );

    final first = anki.reviews.first;
    expect(first.deviceId, deviceId);
    expect(first.t, t0);
    expect(first.h, Hlc(t0, 0, deviceId).encode());
    expect(first.rating, 3);
    expect(first.ms, 5000);
    final lapse = anki.reviews.singleWhere((e) => e.seq == t0 + 4 * day);
    expect(lapse.rating, 1);
    expect(lapse.ms, 8000);
  });

  test('a collection without revlog rows has no reviews', () async {
    final anki = await readApkg(_fixture('basic.apkg'));
    expect(anki.reviews, isEmpty);
    expect(anki.skippedReviews, 0);
    expect(anki.reviewDeviceId, ankiImportDeviceId(0));
    expect(anki.reviewDeviceId, isNot(ankiImportDeviceId(1700000000)));
  });

  test('basic_21b.apkg (anki21b, zstd, protobuf media) imports like basic',
      () async {
    final legacy = await readApkg(_fixture('basic.apkg'));
    final latest = await readApkg(_fixture('basic_21b.apkg'));
    expect(latest.cards, hasLength(7));
    expect(latest.media, hasLength(1));
    // Not the dummy collection.anki2 next to it.
    expect(
      latest.cards.where((c) => c.content.front.contains('Please update')),
      isEmpty,
    );
    _expectSameImport(latest, legacy);
  });

  test('anki21b with compressed zstd blocks imports like basic', () async {
    final raw = _fixture('basic_21b.apkg');
    final compressed = _recompressed(raw);
    final rawCollection =
        ZipDecoder().decodeBytes(raw).findFile('collection.anki21b')!;
    final compressedCollection =
        ZipDecoder().decodeBytes(compressed).findFile('collection.anki21b')!;
    // The encoder really compressed the schema 18 collection.
    expect(
      compressedCollection.readBytes()!.length,
      lessThan(rawCollection.readBytes()!.length ~/ 2),
    );
    _expectSameImport(
      await readApkg(compressed),
      await readApkg(_fixture('basic.apkg')),
    );
  });

  test('a corrupt zstd collection.anki21b is a FormatException', () {
    expect(readApkg(_fixture('anki21b_corrupt.apkg')), throwsFormatException);
  });

  test('a meta version newer than LATEST is not supported', () {
    final out = Archive()
      ..addFile(ArchiveFile.bytes('collection.anki21b', Uint8List(0)))
      ..addFile(ArchiveFile.bytes('meta', [0x08, 0x04]));
    expect(
      readApkg(ZipEncoder().encodeBytes(out)),
      throwsA(isA<UnsupportedAnkiFormatException>()),
    );
  });

  test('a file that is not a ZIP is a FormatException', () {
    expect(
      readApkg(Uint8List.fromList('front,back'.codeUnits)),
      throwsFormatException,
    );
  });
}
