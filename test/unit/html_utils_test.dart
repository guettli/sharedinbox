import 'package:sharedinbox/core/utils/html_utils.dart';
import 'package:test/test.dart';

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
      expect(htmlToPlain('<p>paragraph</p>'), 'paragraph');
    });

    test('drops the content of a style block (#680)', () {
      expect(
        htmlToPlain(
          '<style>@media screen{.hide{display:none}}</style>'
          '<p>Real body text</p>',
        ),
        'Real body text',
      );
    });

    test('drops script and head blocks', () {
      expect(
        htmlToPlain(
          '<head><title>Ignore me</title></head>'
          '<script>var x = 1;</script>'
          'Visible',
        ),
        'Visible',
      );
    });

    test('drops an unclosed style block truncated mid-way', () {
      expect(
        htmlToPlain('<p>Intro</p><style>@font-face { font-family: "Lex'),
        'Intro',
      );
    });

    test('drops a tag left unterminated by truncation', () {
      expect(
        htmlToPlain('Intro<br>Body text <div style="font-family: Anth'),
        'Intro\nBody text',
      );
    });

    test('decodes &amp;', () {
      expect(htmlToPlain('a &amp; b'), 'a & b');
    });

    // Since #682 entities are decoded BEFORE tags are stripped, so escaped
    // markup is treated as markup and removed rather than shown as literal
    // text — the real fix for previews reading "<tr> <td ...".
    test('escaped markup is decoded then stripped (#682)', () {
      expect(htmlToPlain('&lt;tr&gt; &lt;td&gt;cell'), 'cell');
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

    test('decodes decimal numeric entities (#682)', () {
      expect(htmlToPlain('caf&#233;'), 'café');
    });

    test('decodes hex numeric entities (#682)', () {
      expect(htmlToPlain('I &#x2764; you'), 'I \u2764 you');
    });

    test('drops zero-width preheader padding (#682)', () {
      // &#847; is U+034F (combining grapheme joiner), &zwnj; is U+200C —
      // marketing mail pads its preheader with these; they must not survive.
      expect(htmlToPlain('deal&#847;&zwnj; ends'), 'deal ends');
    });

    test('leaves &amp; undecoded-into-double (applied last)', () {
      // &amp;lt; must become "&lt;", not "<": &amp; is decoded last.
      expect(htmlToPlain('a &amp;lt; b'), 'a &lt; b');
    });

    test('leaves a malformed numeric entity as written (#682)', () {
      expect(htmlToPlain('x&#;y'), 'x&#;y');
    });

    test('trims surrounding whitespace', () {
      expect(htmlToPlain('  hello  '), 'hello');
    });

    test('handles empty string', () {
      expect(htmlToPlain(''), '');
    });

    test('handles nested tags', () {
      expect(htmlToPlain('<div><p>text</p></div>'), 'text');
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

  group('htmlHasRemoteResources', () {
    test('false for markup without any images', () {
      expect(
        htmlHasRemoteResources(
          '<h1>Hi</h1><p>A <a href="https://example.com">link</a>.</p>',
        ),
        isFalse,
      );
    });

    test('false for inline cid: and data: images', () {
      expect(
        htmlHasRemoteResources(
          '<img src="cid:logo@x"><img src="data:image/png;base64,AAAA">',
        ),
        isFalse,
      );
    });

    test('true for an http(s) img src, quoted or not', () {
      expect(
        htmlHasRemoteResources('<img src="https://x.test/a.png">'),
        isTrue,
      );
      expect(htmlHasRemoteResources("<IMG SRC='http://x.test/a.png'>"), isTrue);
      expect(htmlHasRemoteResources('<img src=https://x.test/a.png>'), isTrue);
    });

    test('true for a protocol-relative src', () {
      expect(htmlHasRemoteResources('<img src="//x.test/pixel.gif">'), isTrue);
    });

    test('true for srcset and legacy background attributes', () {
      expect(
        htmlHasRemoteResources('<img srcset="https://x.test/a.png 2x">'),
        isTrue,
      );
      expect(
        htmlHasRemoteResources('<td background="https://x.test/bg.jpg">'),
        isTrue,
      );
    });

    test('true for CSS url(), including entity-quoted ones', () {
      expect(
        htmlHasRemoteResources(
          '<style>.h{background:url(https://x.test/bg.jpg)}</style>',
        ),
        isTrue,
      );
      expect(
        htmlHasRemoteResources(
          '<div style="background-image:url(&quot;https://x.test/b.jpg&quot;)">',
        ),
        isTrue,
      );
    });
  });
}
