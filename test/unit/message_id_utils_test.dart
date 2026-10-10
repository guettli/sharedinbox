import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/utils/message_id_utils.dart';

void main() {
  group('normaliseMessageId', () {
    test('strips a single pair of angle brackets', () {
      expect(normaliseMessageId('<foo@bar.example>'), 'foo@bar.example');
    });

    test('leaves bracket-less ids untouched', () {
      expect(normaliseMessageId('foo@bar.example'), 'foo@bar.example');
    });

    test('trims whitespace before checking brackets', () {
      expect(normaliseMessageId('  <foo@bar>  '), 'foo@bar');
    });

    test('returns null for null input', () {
      expect(normaliseMessageId(null), isNull);
    });

    test('returns null for empty and whitespace-only input', () {
      expect(normaliseMessageId(''), isNull);
      expect(normaliseMessageId('   '), isNull);
    });

    test('returns null when brackets contain nothing', () {
      expect(normaliseMessageId('<>'), isNull);
    });

    test('leaves half-bracketed ids as-is', () {
      // Malformed inputs should not silently lose characters.
      expect(normaliseMessageId('<foo@bar'), '<foo@bar');
      expect(normaliseMessageId('foo@bar>'), 'foo@bar>');
    });

    test('strips all repeated surrounding pairs', () {
      // Stalwart wraps an already-bracketed id in a second pair on
      // delivery-status notifications (#859). Fully canonicalising to the
      // bracket-less form lets it match the single-pair id the IMAP ENVELOPE
      // and JMAP arrays produce, so the body-load identity check no longer
      // sees a false mismatch.
      expect(normaliseMessageId('<<foo@bar>>'), 'foo@bar');
      expect(normaliseMessageId('<<<a@b>>>'), 'a@b');
    });

    test('returns null when nested brackets contain nothing', () {
      expect(normaliseMessageId('<<>>'), isNull);
    });
  });

  group('normaliseReferences', () {
    test('normalises every whitespace-separated token', () {
      expect(
        normaliseReferences('<a@x> <b@y>  <c@z>'),
        'a@x b@y c@z',
      );
    });

    test('accepts a mixed list of bracketed and bracket-less ids', () {
      expect(
        normaliseReferences('<a@x> b@y <c@z>'),
        'a@x b@y c@z',
      );
    });

    test('returns null for null input', () {
      expect(normaliseReferences(null), isNull);
    });

    test('returns null when every token is empty', () {
      expect(normaliseReferences('   '), isNull);
      expect(normaliseReferences('<> <>'), isNull);
    });

    test('preserves order', () {
      expect(
        normaliseReferences('<c@z> <a@x> <b@y>'),
        'c@z a@x b@y',
      );
    });
  });
}
