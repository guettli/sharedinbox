import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/utils/list_unsubscribe.dart';

void main() {
  group('parseListUnsubscribeUris', () {
    test('returns empty list for null header', () {
      expect(parseListUnsubscribeUris(null), isEmpty);
    });

    test('returns empty list for empty header', () {
      expect(parseListUnsubscribeUris(''), isEmpty);
    });

    test('returns empty list for whitespace-only header', () {
      expect(parseListUnsubscribeUris('   '), isEmpty);
    });

    test('returns empty list when header has no angle-bracketed URIs', () {
      expect(parseListUnsubscribeUris('no brackets here'), isEmpty);
    });

    test('returns empty list for unparseable bracketed content', () {
      expect(parseListUnsubscribeUris('<not a uri>'), isEmpty);
    });

    test('skips unsupported schemes', () {
      expect(parseListUnsubscribeUris('<ftp://example.com/u>'), isEmpty);
    });

    test('parses a single mailto URI', () {
      final uris = parseListUnsubscribeUris('<mailto:unsub@example.com>');
      expect(uris, hasLength(1));
      expect(uris.single.scheme, 'mailto');
      expect(uris.single.path, 'unsub@example.com');
    });

    test('parses a single https URI', () {
      final uris = parseListUnsubscribeUris('<https://example.com/u?id=42>');
      expect(uris, hasLength(1));
      expect(uris.single.scheme, 'https');
      expect(uris.single.host, 'example.com');
    });

    test('parses a single http URI', () {
      final uris = parseListUnsubscribeUris('<http://example.com/u>');
      expect(uris, hasLength(1));
      expect(uris.single.scheme, 'http');
    });

    test('returns all usable URIs in header order', () {
      final uris = parseListUnsubscribeUris(
        '<https://example.com/u>, <mailto:unsub@example.com>',
      );
      expect(uris.map((u) => u.scheme).toList(), ['https', 'mailto']);
    });

    test('returns all usable URIs regardless of order', () {
      final uris = parseListUnsubscribeUris(
        '<mailto:unsub@example.com>, <https://example.com/u>',
      );
      expect(uris.map((u) => u.scheme).toList(), ['mailto', 'https']);
    });

    test('returns multiple https URIs in order', () {
      final uris = parseListUnsubscribeUris(
        '<https://first.example/u>, <https://second.example/u>',
      );
      expect(
        uris.map((u) => u.host).toList(),
        ['first.example', 'second.example'],
      );
    });

    test('tolerates surrounding whitespace inside brackets', () {
      final uris = parseListUnsubscribeUris('<  mailto:unsub@example.com  >');
      expect(uris, hasLength(1));
      expect(uris.single.scheme, 'mailto');
      expect(uris.single.path, 'unsub@example.com');
    });

    test('skips unsupported schemes and keeps the usable ones', () {
      final uris = parseListUnsubscribeUris(
        '<ftp://example.com/u>, <https://example.com/u>',
      );
      expect(uris, hasLength(1));
      expect(uris.single.scheme, 'https');
    });

    test('parses an eBay-style https + mailto pair', () {
      final uris = parseListUnsubscribeUris(
        '<https://www.ebay.com/uns?id=abc>, '
        '<mailto:unsubscribe@reply.ebay.com>',
      );
      expect(uris.map((u) => u.scheme).toList(), ['https', 'mailto']);
    });

    test('falls back to a bare https URI without angle brackets', () {
      final uris = parseListUnsubscribeUris('https://www.ebay.com/uns?id=abc');
      expect(uris, hasLength(1));
      expect(uris.single.scheme, 'https');
      expect(uris.single.host, 'www.ebay.com');
    });

    test('falls back to a bare mailto URI without angle brackets', () {
      final uris = parseListUnsubscribeUris('mailto:unsub@example.com');
      expect(uris, hasLength(1));
      expect(uris.single.scheme, 'mailto');
      expect(uris.single.path, 'unsub@example.com');
    });

    test('falls back to bare comma-separated URIs', () {
      final uris = parseListUnsubscribeUris(
        'mailto:unsub@example.com, https://example.com/u',
      );
      expect(uris.map((u) => u.scheme).toList(), ['mailto', 'https']);
    });

    test('parses a folded multi-line header', () {
      final uris = parseListUnsubscribeUris(
        '<https://example.com/u>,\r\n <mailto:unsub@example.com>',
      );
      expect(uris.map((u) => u.scheme).toList(), ['https', 'mailto']);
    });

    test('prefers bracketed URIs over the bare-token fallback', () {
      // When brackets yield a usable URI, the fallback must not run and pull in
      // extra bare tokens, so the result stays exactly the bracketed set.
      final uris = parseListUnsubscribeUris('<https://example.com/u>');
      expect(uris, hasLength(1));
      expect(uris.single.host, 'example.com');
    });
  });
}
