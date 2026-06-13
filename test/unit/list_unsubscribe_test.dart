import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/utils/list_unsubscribe.dart';

void main() {
  group('parseListUnsubscribeUri', () {
    test('returns null for null header', () {
      expect(parseListUnsubscribeUri(null), isNull);
    });

    test('returns null for empty header', () {
      expect(parseListUnsubscribeUri(''), isNull);
    });

    test('returns null for whitespace-only header', () {
      expect(parseListUnsubscribeUri('   '), isNull);
    });

    test('returns null when header has no angle-bracketed URIs', () {
      expect(parseListUnsubscribeUri('no brackets here'), isNull);
    });

    test('returns null for unparseable bracketed content', () {
      expect(parseListUnsubscribeUri('<not a uri>'), isNull);
    });

    test('returns null for unsupported scheme', () {
      expect(parseListUnsubscribeUri('<ftp://example.com/u>'), isNull);
    });

    test('parses a single mailto URI', () {
      final uri = parseListUnsubscribeUri('<mailto:unsub@example.com>');
      expect(uri, isNotNull);
      expect(uri!.scheme, 'mailto');
      expect(uri.path, 'unsub@example.com');
    });

    test('parses a single https URI', () {
      final uri = parseListUnsubscribeUri('<https://example.com/u?id=42>');
      expect(uri, isNotNull);
      expect(uri!.scheme, 'https');
      expect(uri.host, 'example.com');
    });

    test('parses a single http URI', () {
      final uri = parseListUnsubscribeUri('<http://example.com/u>');
      expect(uri, isNotNull);
      expect(uri!.scheme, 'http');
    });

    test('prefers mailto over https when both are present', () {
      final uri = parseListUnsubscribeUri(
        '<https://example.com/u>, <mailto:unsub@example.com>',
      );
      expect(uri!.scheme, 'mailto');
      expect(uri.path, 'unsub@example.com');
    });

    test('prefers mailto over https regardless of order', () {
      final uri = parseListUnsubscribeUri(
        '<mailto:unsub@example.com>, <https://example.com/u>',
      );
      expect(uri!.scheme, 'mailto');
    });

    test('returns the first https URI when several are present', () {
      final uri = parseListUnsubscribeUri(
        '<https://first.example/u>, <https://second.example/u>',
      );
      expect(uri!.host, 'first.example');
    });

    test('tolerates surrounding whitespace inside brackets', () {
      final uri = parseListUnsubscribeUri('<  mailto:unsub@example.com  >');
      expect(uri!.scheme, 'mailto');
      expect(uri.path, 'unsub@example.com');
    });

    test('skips unsupported schemes and returns the next usable URI', () {
      final uri = parseListUnsubscribeUri(
        '<ftp://example.com/u>, <https://example.com/u>',
      );
      expect(uri!.scheme, 'https');
    });
  });
}
