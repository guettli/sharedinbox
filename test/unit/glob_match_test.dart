import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/utils/glob_match.dart';

void main() {
  group('globMatch', () {
    test('exact match (no wildcards)', () {
      expect(globMatch('alice@example.com', 'alice@example.com'), isTrue);
      expect(globMatch('alice@example.com', 'bob@example.com'), isFalse);
    });

    test('* matches any domain wildcard', () {
      expect(globMatch('alice@example.com', '*@example.com'), isTrue);
      expect(globMatch('bob@example.com', '*@example.com'), isTrue);
      expect(globMatch('alice@other.com', '*@example.com'), isFalse);
    });

    test('* matches zero or more characters', () {
      expect(
        globMatch('newsletter@news.example.com', '*@*.example.com'),
        isTrue,
      );
      expect(globMatch('alice@example.com', 'alice*'), isTrue);
      expect(globMatch('alice@example.com', '*example*'), isTrue);
    });

    test('? matches exactly one character', () {
      expect(globMatch('alice@example.com', 'alice@exampl?.com'), isTrue);
      expect(globMatch('alice@example.com', 'alice@exampl??.com'), isFalse);
    });

    test('case-insensitive comparison', () {
      expect(globMatch('Alice@Example.COM', '*@example.com'), isTrue);
      expect(globMatch('alice@example.com', '*@EXAMPLE.COM'), isTrue);
    });

    test('no wildcards — mismatch is false', () {
      expect(globMatch('alice@example.com', 'alice@other.com'), isFalse);
    });

    test('bare * matches everything', () {
      expect(globMatch('alice@example.com', '*'), isTrue);
      expect(globMatch('', '*'), isTrue);
    });

    test('empty pattern only matches empty string', () {
      expect(globMatch('', ''), isTrue);
      expect(globMatch('alice@example.com', ''), isFalse);
    });
  });
}
