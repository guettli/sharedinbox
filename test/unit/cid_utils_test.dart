import 'dart:convert';

import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/utils/cid_utils.dart';

// A minimal multipart/related email with one embedded PNG referenced via cid:.
//
// The image data is the 1×1 red pixel PNG (67 bytes) from RFC-tests tradition.
const _kPixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwADhQGAWjR9awAAAABJRU5ErkJggg==';

// Build a synthetic RFC 2822 multipart/related message.
String _buildRelatedMime({String cidHost = 'test@example.com'}) {
  const boundary = '----=_Part_TEST_BOUNDARY';
  const innerBoundary = '----=_Part_INNER_BOUNDARY';
  return [
    'MIME-Version: 1.0',
    'Content-Type: multipart/related;',
    '\ttype="multipart/alternative";',
    '\tboundary="$boundary"',
    '',
    '--$boundary',
    'Content-Type: multipart/alternative;',
    '\tboundary="$innerBoundary"',
    '',
    '--$innerBoundary',
    'Content-Type: text/plain; charset=UTF-8',
    '',
    'See the image below.',
    '--$innerBoundary',
    'Content-Type: text/html; charset=UTF-8',
    '',
    '<html><body><img src="cid:$cidHost"></body></html>',
    '--$innerBoundary--',
    '',
    '--$boundary',
    'Content-Type: image/png',
    'Content-Disposition: inline',
    'Content-Transfer-Encoding: base64',
    'Content-ID: <$cidHost>',
    '',
    _kPixelPng,
    '--$boundary--',
  ].join('\r\n');
}

void main() {
  group('injectInlineImages', () {
    test('replaces cid: reference with data: URI', () {
      final msg = imap.MimeMessage.parseFromText(_buildRelatedMime());
      const html = '<img src="cid:test@example.com">';

      final result = injectInlineImages(html, msg);

      expect(result, contains('src="data:image/png;base64,'));
      expect(result, isNot(contains('cid:')));
    });

    test('leaves HTML unchanged when there are no inline parts', () {
      // A plain text-only message.
      const plainMime =
          'MIME-Version: 1.0\r\n'
          'Content-Type: text/plain\r\n'
          '\r\n'
          'Hello';
      final msg = imap.MimeMessage.parseFromText(plainMime);
      const html = '<img src="cid:foo@bar">';

      expect(injectInlineImages(html, msg), html);
    });

    test('handles single-quoted src attribute', () {
      final msg = imap.MimeMessage.parseFromText(_buildRelatedMime());
      const html = "<img src='cid:test@example.com'>";

      final result = injectInlineImages(html, msg);

      expect(result, contains("src='data:image/png;base64,"));
      expect(result, isNot(contains('cid:')));
    });

    test('embedded data is the same base64 as the MIME part', () {
      final msg = imap.MimeMessage.parseFromText(_buildRelatedMime());
      const html = '<img src="cid:test@example.com">';

      final result = injectInlineImages(html, msg);

      // Extract base64 payload from the data URI.
      final match = RegExp(
        r'data:image/png;base64,([A-Za-z0-9+/=]+)',
      ).firstMatch(result);
      expect(match, isNotNull);
      final decoded = base64.decode(match!.group(1)!);
      expect(decoded.length, greaterThan(0));
    });
  });
}
