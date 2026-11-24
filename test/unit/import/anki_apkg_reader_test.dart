import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/import/card_import.dart';
import 'package:sharedinbox/core/import/import_ids.dart';
import 'package:sharedinbox/data/import/anki_apkg_reader.dart';

Uint8List _fixture(String name) =>
    File('test/fixtures/anki/$name').readAsBytesSync();

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

  test('an .apkg with only collection.anki21b is not supported', () {
    expect(
      readApkg(_fixture('anki21b_only.apkg')),
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
