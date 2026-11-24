import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/import/csv_cards.dart';
import 'package:sharedinbox/core/import/import_ids.dart';

void main() {
  group('parseCsv', () {
    test('quotes, "" escapes, commas and line breaks inside quotes', () {
      expect(
        parseCsv('a,"b, c","say ""hi"""\r\n"x\ny","1\r\n2",\n'),
        [
          ['a', 'b, c', 'say "hi"'],
          ['x\ny', '1\r\n2', ''],
        ],
      );
    });

    test('a BOM is dropped; \\n and \\r\\n end rows; no trailing empty row',
        () {
      expect(parseCsv('﻿a,b\nc,d\r\ne,f'), [
        ['a', 'b'],
        ['c', 'd'],
        ['e', 'f'],
      ]);
      expect(parseCsv(''), isEmpty);
    });
  });

  group('parseCsvCards', () {
    test('the fixture: header, quotes, UTF-8, default deck, empty front', () {
      final csv = parseCsvCards(
        File('test/fixtures/cards.csv').readAsStringSync(),
      );
      final byFront = {for (final c in csv.cards) c.content.front: c};
      expect(byFront.keys, [
        'Hallo',
        'Apfel, rot',
        'Zitat',
        'zwei\nZeilen',
        'Über',
        '日本',
        'Tschüss',
      ]);
      expect(byFront['Hallo']!.content.back, 'hello');
      expect(byFront['Hallo']!.content.tags, ['greeting']);
      expect(byFront['Hallo']!.deckName, 'German');
      expect(byFront['Apfel, rot']!.content.back, 'apple, red');
      expect(byFront['Apfel, rot']!.content.tags, ['fruit', 'food']);
      expect(byFront['Zitat']!.content.back, 'He said "hi"');
      expect(byFront['Zitat']!.content.tags, isEmpty);
      expect(byFront['Zitat']!.deckName, defaultDeck);
      expect(byFront['zwei\nZeilen']!.content.back, 'two\r\nlines');
      expect(byFront['Über']!.deckName, 'Deutsch::Präpositionen');
      expect(byFront['日本']!.content.back, 'Japan 🗾');
      expect(byFront['日本']!.content.tags, ['cjk', 'emoji']);
      expect(csv.skippedEmpty, 1);
    });

    test('the cardId is a stable hash of deck and front', () {
      final a = parseCsvCards('Hallo,hello,,German\n').cards.single;
      final b = parseCsvCards('Hallo,hi,x,German\n').cards.single;
      final other = parseCsvCards('Hallo,hello,,Dutch\n').cards.single;
      expect(a.cardId, csvCardId('German', 'Hallo'));
      expect(a.cardId, hasLength(22));
      expect(b.cardId, a.cardId);
      expect(other.cardId, isNot(a.cardId));
    });

    test('without a header the first row is a card', () {
      final cards = parseCsvCards('Front side,Back\n').cards;
      expect(cards.single.content.front, 'Front side');
    });
  });
}
