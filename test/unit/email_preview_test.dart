import 'package:sharedinbox/core/utils/email_preview.dart';
import 'package:test/test.dart';

void main() {
  group('previewFromBody', () {
    test('returns plain text unchanged', () {
      expect(previewFromBody('Hello there', null), 'Hello there');
    });

    test('collapses newlines and tabs into single spaces', () {
      expect(previewFromBody('a\r\n\tb\n c', null), 'a b c');
    });

    test('collapses non-breaking spaces into a single space', () {
      expect(previewFromBody('a  b', null), 'a b');
    });

    test('strips HTML tags when only html is present', () {
      expect(
        previewFromBody(null, '<p>Hello <b>Alice</b></p>'),
        'Hello Alice',
      );
    });

    test('prefers text over html when both are supplied', () {
      expect(
        previewFromBody('plain body', '<p>html body</p>'),
        'plain body',
      );
    });

    test('falls back to html when text is blank', () {
      expect(previewFromBody('   ', '<p>Fallback</p>'), 'Fallback');
    });

    test('returns null for empty inputs', () {
      expect(previewFromBody(null, null), isNull);
      expect(previewFromBody('', ''), isNull);
      expect(previewFromBody('  ', '  '), isNull);
    });

    test('truncates at kPreviewMaxChars', () {
      final long = 'x' * (kPreviewMaxChars + 50);
      final preview = previewFromBody(long, null);
      expect(preview, isNotNull);
      expect(preview!.length, kPreviewMaxChars);
      expect(preview, 'x' * kPreviewMaxChars);
    });

    test('does not truncate when body is shorter than the cap', () {
      final body = 'y' * (kPreviewMaxChars - 1);
      expect(previewFromBody(body, null)!.length, kPreviewMaxChars - 1);
    });

    test('trims leading and trailing whitespace before truncating', () {
      expect(previewFromBody('   Hello world   ', null), 'Hello world');
    });
  });
}
