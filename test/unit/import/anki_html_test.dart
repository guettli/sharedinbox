import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/import/anki_html.dart';

String _md(String html) => ankiHtmlToMarkdown(html, (_) => null).text;

void main() {
  test('line breaks, divs and paragraphs', () {
    expect(_md('a<br>b<br/>c'), 'a\nb\nc');
    expect(_md('<div>a</div><div>b</div>'), 'a\nb');
    expect(_md('<p>a</p><p>b</p>'), 'a\n\nb');
    // Source line breaks are spaces in HTML.
    expect(_md('a\nb'), 'a b');
  });

  test('bold and italic', () {
    expect(_md('<b>a</b> <strong>b</strong>'), '**a** **b**');
    expect(_md('<i>a</i> <EM>b</EM>'), '*a* *b*');
  });

  test('entities are decoded', () {
    expect(
      _md('a &amp; b &lt;c&gt; &quot;d&quot; &#228; &#xFC; &nbsp;x'),
      'a & b <c> "d" ä ü  x',
    );
    expect(_md('&unknown;'), '&unknown;');
  });

  test('unknown tags, comments, scripts and styles are stripped', () {
    expect(
      _md('<span style="color:red">a</span><!-- c --><script>x()</script>'
          '<style>.a{}</style><font>b</font>'),
      'ab',
    );
  });

  test('images resolve through the callback; a missing one stays as text', () {
    final md = ankiHtmlToMarkdown(
      'x <img src="cat.png"> <img class=a src=\'dog.jpg\'>',
      (name) => name == 'cat.png' ? 'blob1' : null,
    );
    expect(md.text, 'x ![](si-img:blob1) [image missing: dog.jpg]');
    expect(md.missingImages, ['dog.jpg']);
  });

  test('sounds are dropped and counted', () {
    final md = ankiHtmlToMarkdown('house [sound:a.mp3][sound:b.mp3]', (_) {
      return null;
    });
    expect(md.text, 'house');
    expect(md.droppedSounds, 2);
  });
}
