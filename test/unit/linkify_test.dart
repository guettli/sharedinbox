import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/utils/linkify.dart';

void main() {
  group('findUrls', () {
    test('returns empty list when text has no URLs', () {
      expect(findUrls('hello world'), isEmpty);
    });

    test('returns empty list for empty text', () {
      expect(findUrls(''), isEmpty);
    });

    test('finds a bare https URL', () {
      final urls = findUrls('go to https://example.com');
      expect(urls, hasLength(1));
      expect(urls.single.url, 'https://example.com');
      expect(urls.single.start, 6);
      expect(urls.single.end, 25);
    });

    test('finds a bare http URL', () {
      final urls = findUrls('http://example.com');
      expect(urls.map((u) => u.url).toList(), ['http://example.com']);
    });

    test('finds multiple URLs on one line', () {
      final urls = findUrls('a https://a.example and b http://b.example c');
      expect(
        urls.map((u) => u.url).toList(),
        ['https://a.example', 'http://b.example'],
      );
    });

    test('preserves query strings and fragments', () {
      final urls = findUrls('link: https://example.com/path?q=1&r=2#frag');
      expect(urls.single.url, 'https://example.com/path?q=1&r=2#frag');
    });

    test('strips trailing sentence punctuation', () {
      expect(
        findUrls('see https://example.com.').single.url,
        'https://example.com',
      );
      expect(
        findUrls('see https://example.com!').single.url,
        'https://example.com',
      );
      expect(
        findUrls('see https://example.com, ok').single.url,
        'https://example.com',
      );
      expect(
        findUrls('see https://example.com; ok').single.url,
        'https://example.com',
      );
    });

    test('strips unbalanced trailing parenthesis', () {
      expect(
        findUrls('(see https://example.com)').single.url,
        'https://example.com',
      );
    });

    test('keeps balanced parentheses inside the URL', () {
      final urls = findUrls(
        'see https://en.wikipedia.org/wiki/Foo_(bar) here',
      );
      expect(urls.single.url, 'https://en.wikipedia.org/wiki/Foo_(bar)');
    });

    test('strips unbalanced trailing bracket', () {
      expect(
        findUrls('[link: https://example.com]').single.url,
        'https://example.com',
      );
    });

    test('does not match URLs without an http scheme', () {
      expect(findUrls('visit example.com for info'), isEmpty);
    });

    test('does not match ftp scheme', () {
      expect(findUrls('ftp://example.com'), isEmpty);
    });

    test('URL scheme matching is case-insensitive', () {
      final urls = findUrls('go to HTTPS://Example.COM');
      expect(urls.single.url, 'HTTPS://Example.COM');
    });

    test('stops at whitespace', () {
      final urls = findUrls('https://example.com/path more text');
      expect(urls.single.url, 'https://example.com/path');
    });

    test('reports byte offsets that align with the substring', () {
      const text = 'prefix https://example.com/a suffix';
      final m = findUrls(text).single;
      expect(text.substring(m.start, m.end), m.url);
    });
  });
}
