import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/utils/quote_fold.dart';

void main() {
  group('splitTrailingQuote', () {
    test('folds a long trailing quote below a short reply', () {
      const text = 'yes, please do that\n'
          '\n'
          '> line one\n'
          '> line two\n'
          '> line three\n'
          '> line four\n'
          '> line five\n'
          '> line six';
      final split = splitTrailingQuote(text);
      expect(split.visible, 'yes, please do that');
      expect(split.quoted, isNotNull);
      expect(split.quoted, contains('> line one'));
      expect(split.quoted, contains('> line six'));
    });

    test('absorbs the attribution line into the folded region', () {
      const text = 'Sounds good.\n'
          '\n'
          'On Tue, 1 Jan 2024 at 10:00, Jane Doe <jane@example.com> wrote:\n'
          '> line one\n'
          '> line two\n'
          '> line three\n'
          '> line four\n'
          '> line five\n'
          '> line six';
      final split = splitTrailingQuote(text);
      expect(split.visible, 'Sounds good.');
      expect(split.quoted, startsWith('On Tue, 1 Jan 2024'));
    });

    test('absorbs a German "schrieb:" attribution', () {
      const text = 'Danke!\n'
          '\n'
          'Am 01.01.2024 schrieb Jane Doe:\n'
          '> zeile eins\n'
          '> zeile zwei\n'
          '> zeile drei\n'
          '> zeile vier\n'
          '> zeile fünf\n'
          '> zeile sechs';
      final split = splitTrailingQuote(text);
      expect(split.visible, 'Danke!');
      expect(split.quoted, startsWith('Am 01.01.2024 schrieb'));
    });

    test('does not fold inline/interleaved quoting', () {
      const text = '> what about the deadline?\n'
          'It is next Friday.\n'
          '\n'
          '> and the budget?\n'
          'Still 5k.';
      final split = splitTrailingQuote(text);
      expect(split.quoted, isNull);
      expect(split.visible, text);
    });

    test('does not fold a short trailing quote below the threshold', () {
      const text = 'ack\n'
          '\n'
          '> only one quoted line';
      final split = splitTrailingQuote(text);
      expect(split.quoted, isNull);
    });

    test('handles nested quote prefixes', () {
      const text = 'ok\n'
          '\n'
          '>> deep one\n'
          '>> deep two\n'
          '> shallow one\n'
          '> shallow two\n'
          '>> deep three\n'
          '> shallow three';
      final split = splitTrailingQuote(text);
      expect(split.visible, 'ok');
      expect(split.quoted, contains('>> deep one'));
    });

    test('returns text unchanged when there are no quotes', () {
      const text = 'just a plain message\nwith two lines';
      final split = splitTrailingQuote(text);
      expect(split.quoted, isNull);
      expect(split.visible, text);
    });

    test('does not fold a fully quoted body with no reply text', () {
      const text = '> line one\n'
          '> line two\n'
          '> line three\n'
          '> line four\n'
          '> line five\n'
          '> line six';
      final split = splitTrailingQuote(text);
      expect(split.quoted, isNull);
      expect(split.visible, text);
    });

    test('respects a custom minQuotedLines threshold', () {
      const text = 'sure\n'
          '\n'
          '> a\n'
          '> b';
      expect(splitTrailingQuote(text, minQuotedLines: 2).quoted, isNotNull);
      expect(splitTrailingQuote(text, minQuotedLines: 3).quoted, isNull);
    });

    test('returns empty text unchanged', () {
      final split = splitTrailingQuote('');
      expect(split.quoted, isNull);
      expect(split.visible, '');
    });
  });
}
