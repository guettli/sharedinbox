import 'package:test/test.dart';

import 'package:sharedinbox/core/utils/html_utils.dart';

void main() {
  group('htmlToPlain', () {
    test('returns plain text unchanged', () {
      expect(htmlToPlain('Hello world'), 'Hello world');
    });

    test('strips simple tags', () {
      expect(htmlToPlain('<b>bold</b> text'), 'bold text');
    });

    test('converts <br> to newline', () {
      expect(htmlToPlain('line1<br>line2'), 'line1\nline2');
    });

    test('converts self-closing <br/> to newline', () {
      expect(htmlToPlain('line1<br/>line2'), 'line1\nline2');
    });

    test('converts <p> to newline', () {
      expect(htmlToPlain('<p>paragraph</p>'), '\nparagraph');
    });

    test('decodes &amp;', () {
      expect(htmlToPlain('a &amp; b'), 'a & b');
    });

    test('decodes &lt; and &gt;', () {
      expect(htmlToPlain('&lt;tag&gt;'), '<tag>');
    });

    test('decodes &quot;', () {
      expect(htmlToPlain('say &quot;hi&quot;'), 'say "hi"');
    });

    test('decodes &#39;', () {
      expect(htmlToPlain('it&#39;s'), "it's");
    });

    test('decodes &nbsp; as space', () {
      expect(htmlToPlain('a&nbsp;b'), 'a b');
    });

    test('trims surrounding whitespace', () {
      expect(htmlToPlain('  hello  '), 'hello');
    });

    test('handles empty string', () {
      expect(htmlToPlain(''), '');
    });

    test('handles nested tags', () {
      expect(htmlToPlain('<div><p>text</p></div>'), '\ntext');
    });

    test('real-world HTML email snippet', () {
      const html = '<p>Hello <b>Alice</b>,</p>'
          '<p>Please find the invoice attached.</p>'
          '<p>Best regards,<br/>Bob</p>';
      final result = htmlToPlain(html);
      expect(result, contains('Hello Alice,'));
      expect(result, contains('Best regards,'));
      expect(result, contains('Bob'));
    });
  });
}
