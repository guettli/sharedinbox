import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/sieve/sieve_flags.dart';

void main() {
  group('normalizeSieveFlags', () {
    test('splits a space-separated string into separate flags', () {
      final r = normalizeSieveFlags(['Work Urgent']);
      expect(r.flags, ['Work', 'Urgent']);
      expect(r.dropped, isEmpty);
    });

    test('one string can hold several system flags', () {
      expect(normalizeSieveFlags([r'\Seen \Flagged']).flags, [
        r'\Seen',
        r'\Flagged',
      ]);
      // A still-escaped spelling from a hand-written script.
      expect(normalizeSieveFlags([r'\\seen  \\FLAGGED']).flags, [
        r'\Seen',
        r'\Flagged',
      ]);
    });

    test('drops keywords with atom-specials', () {
      final r = normalizeSieveFlags(['a(b', 'ok', 'x*', 'q"', 'p%', r'a\b']);
      expect(r.flags, ['ok']);
      expect(r.dropped, ['a(b', 'x*', 'q"', 'p%', r'a\b']);
    });

    test('drops a string with CR or LF whole', () {
      final r = normalizeSieveFlags(['Work\r\nA1 LOGOUT', 'Fine', 'a\nb']);
      expect(r.flags, ['Fine']);
      expect(r.dropped, ['Work\r\nA1 LOGOUT', 'a\nb']);
    });

    test('drops unknown and unsupported system flags', () {
      final r = normalizeSieveFlags([r'\Deleted \Recent \Bogus \Answered']);
      expect(r.flags, [r'\Answered']);
      expect(r.dropped, [r'\Deleted', r'\Recent', r'\Bogus']);
    });

    test('drops non-ASCII and over-long keywords, dedupes ignoring case', () {
      final long = 'k' * 256;
      final r = normalizeSieveFlags(['Wörk', long, 'Work', 'WORK', r'\seen']);
      expect(r.flags, ['Work', r'\Seen']);
      expect(r.dropped, ['Wörk', long]);
    });
  });
}
