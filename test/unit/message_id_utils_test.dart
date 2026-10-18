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

  group('replyThreading', () {
    test('appends the parent to its References chain', () {
      final t = replyThreading(
        messageId: '<p@x>',
        inReplyTo: '<b@x>',
        references: '<a@x> <b@x>',
      );
      expect(t?.inReplyTo, 'p@x');
      expect(t?.references, ['a@x', 'b@x', 'p@x']);
    });

    test('falls back to In-Reply-To when the parent has no References', () {
      final t = replyThreading(messageId: 'p@x', inReplyTo: '<b@x>');
      expect(t?.references, ['b@x', 'p@x']);
    });

    test('starts a chain for a parent that answers nothing', () {
      final t = replyThreading(messageId: '<p@x>');
      expect(t?.inReplyTo, 'p@x');
      expect(t?.references, ['p@x']);
    });

    test('lists the parent once even if its References already name it', () {
      final t = replyThreading(messageId: 'p@x', references: 'a@x p@x');
      expect(t?.references, ['a@x', 'p@x']);
    });

    test('is null when the parent has no Message-ID', () {
      expect(replyThreading(messageId: null, references: 'a@x'), isNull);
      expect(replyThreading(messageId: '<>'), isNull);
    });
  });

  test('bracketMessageIds renders a header value', () {
    expect(bracketMessageIds(['a@x', 'b@y']), '<a@x> <b@y>');
  });
}
