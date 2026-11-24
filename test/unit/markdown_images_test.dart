import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/utils/markdown_images.dart';

void main() {
  test('the image line refers to the blob', () {
    expect(siImageMarkdown('ab-c_9'), '![](si-img:ab-c_9)');
    expect(siImageId(Uri.parse('si-img:ab-c_9')), 'ab-c_9');
  });

  test('only plain si-img ids are blob references', () {
    for (final href in [
      'si-img:',
      'si-img:a/b',
      'si-img:a?b',
      'si-img:a#b',
      'cid:part1',
      'https://example.com/a.png',
      'abc',
    ]) {
      expect(siImageId(Uri.parse(href)), isNull, reason: href);
    }
  });

  test('lists every blob a body refers to, once, in order', () {
    const body = 'x\n![](si-img:one)\n![pic](si-img:two "t")\n'
        '![](cid:three)\n![](https://e.com/x.png)\n![a](si-img:one)\n'
        '[not an image](si-img:four)';
    expect(siImageIds(body), ['one', 'two']);
    expect(siImageIds('plain'), isEmpty);
  });

  test('inserts the image on a line of its own', () {
    expect(insertSiImage('', 0, 'i'), ('![](si-img:i)\n', 14));
    expect(insertSiImage('ab', 1, 'i'), ('a\n![](si-img:i)\nb', 16));
    expect(insertSiImage('a\nb', 2, 'i'), ('a\n![](si-img:i)\nb', 16));
    expect(insertSiImage('a\n', 1, 'i'), ('a\n![](si-img:i)\n', 15));
    expect(insertSiImage('ab', 2, 'i'), ('ab\n![](si-img:i)\n', 17));
  });

  test('an offset outside the text appends', () {
    expect(insertSiImage('ab', -1, 'i'), ('ab\n![](si-img:i)\n', 17));
    expect(insertSiImage('ab', 9, 'i'), ('ab\n![](si-img:i)\n', 17));
  });
}
