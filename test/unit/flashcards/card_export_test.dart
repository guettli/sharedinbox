import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/flashcards/card_export.dart';
import 'package:sharedinbox/core/flashcards/review_event.dart';
import 'package:sharedinbox/core/models/card.dart';

Deck _deck(String id, String name) => Deck(
      accountId: 'acc',
      deckId: id,
      itemHmac: 'hm-$id',
      name: name,
      versionId: 'v',
      updatedAt: DateTime.utc(2026),
    );

FlashCard _card(
  String id,
  String deckId,
  String front,
  String back, {
  List<String> tags = const [],
}) =>
    FlashCard(
      accountId: 'acc',
      cardId: id,
      deckId: deckId,
      content: CardContent(front: front, back: back, tags: tags),
      h: 'h-$id',
      sourceItemHmac: 's',
      sourceKind: CardSourceKind.doc,
    );

void main() {
  test('one CSV row per card with the deck name and space-separated tags', () {
    final out = cardsCsv(
      [_deck('deck-1', 'Spanish')],
      [
        _card('c1', 'deck-1', 'hola', 'hello', tags: ['greet', 'a1']),
        _card('c2', 'deck-x', 'adiós', 'bye'),
      ],
    );
    expect(
      out.csv,
      'cardId,deckId,deckName,front,back,tags,h\r\n'
      'c1,deck-1,Spanish,hola,hello,greet a1,h-c1\r\n'
      'c2,deck-x,,adiós,bye,,h-c2\r\n',
    );
    expect(out.media, isEmpty);
  });

  test('fields with commas, quotes and line breaks are quoted (RFC 4180)', () {
    final out = cardsCsv(
      [_deck('deck-1', 'Words, phrases')],
      [_card('c1', 'deck-1', 'say "hi"', 'line 1\nline 2\r\nline 3')],
    );
    expect(
      out.csv.split('\r\n')[1],
      'c1,deck-1,"Words, phrases","say ""hi""","line 1\nline 2',
    );
    expect(out.csv, endsWith('line 3",,h-c1\r\n'));
  });

  test('image references point into media/ and are listed once', () {
    final out = cardsCsv(
      const [],
      [
        _card('c1', 'd', '![cat](si-img:AbC_1-x)', 'si-img:Zz9'),
        _card('c2', 'd', 'again ![](si-img:AbC_1-x)', 'no image: si-img:'),
      ],
    );
    final rows = out.csv.split('\r\n');
    expect(rows[1], 'c1,d,,![cat](media/AbC_1-x),media/Zz9,,h-c1');
    expect(rows[2], 'c2,d,,again ![](media/AbC_1-x),no image: si-img:,,h-c2');
    expect(out.media, ['AbC_1-x', 'Zz9']);
  });

  test(
      'the review log is one wire event plus its device per line, in '
      '(h, deviceId, seq) order', () {
    const events = [
      ReviewEvent(
        deviceId: 'devB',
        seq: 1,
        h: '0000000000002-0000-devB',
        cardId: 'c1',
        t: 2,
        rating: 3,
        ms: 10,
      ),
      UndoEvent(
        deviceId: 'devA',
        seq: 2,
        h: '0000000000003-0000-devA',
        refDeviceId: 'devB',
        refSeq: 1,
      ),
      ReviewEvent(
        deviceId: 'devA',
        seq: 1,
        h: '0000000000002-0000-devB',
        cardId: 'c2',
        t: 2,
        rating: 1,
      ),
    ];
    final lines = reviewLogJsonl(events).split('\n');
    expect(lines.last, isEmpty);
    final json = [
      for (final l in lines.take(3)) jsonDecode(l) as Map<String, Object?>,
    ];
    final ids = [for (final j in json) (j['device'], j['s'])];
    expect(ids, [('devA', 1), ('devB', 1), ('devA', 2)]);
    expect(json[1], {
      'op': 'review',
      'c': 'c1',
      's': 1,
      'h': '0000000000002-0000-devB',
      't': 2,
      'r': 3,
      'ms': 10,
      'device': 'devB',
    });
    expect(json[2]['ref'], ['devB', 1]);
    expect(reviewLogJsonl(const []), isEmpty);
  });
}
