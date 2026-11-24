import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/import/anki_template.dart';

void main() {
  const fields = {'Front': 'Hund', 'Back': '<b>dog</b>', 'Extra': ''};

  test('fields and filters', () {
    expect(
      renderAnkiTemplate('{{Front}} / {{ Back }}', fields),
      'Hund / <b>dog</b>',
    );
    expect(renderAnkiTemplate('{{text:Back}}', fields), 'dog');
    expect(renderAnkiTemplate('{{type:Back}}', fields), '');
    expect(renderAnkiTemplate('{{hint:Front}}', fields), 'Hund');
    expect(renderAnkiTemplate('{{Unknown}}x', fields), 'x');
  });

  test('sections and inverted sections, nested', () {
    expect(
      renderAnkiTemplate('{{#Back}}[{{Back}}]{{/Back}}', fields),
      '[<b>dog</b>]',
    );
    expect(renderAnkiTemplate('{{#Extra}}[{{Extra}}]{{/Extra}}', fields), '');
    expect(renderAnkiTemplate('{{^Extra}}none{{/Extra}}', fields), 'none');
    expect(renderAnkiTemplate('{{^Front}}none{{/Front}}', fields), '');
    expect(
      renderAnkiTemplate(
        '{{#Front}}a{{^Extra}}b{{/Extra}}{{#Extra}}c{{/Extra}}{{/Front}}',
        fields,
      ),
      'ab',
    );
  });

  test('a field of only whitespace and <br> is empty; an image is not', () {
    expect(ankiFieldIsEmpty(' <br> &nbsp;<div></div>'), isTrue);
    expect(ankiFieldIsEmpty('<img src="a.png">'), isFalse);
  });

  test('the back drops {{FrontSide}} and the <hr id=answer> after it', () {
    expect(
      renderAnkiBack('{{FrontSide}}\n\n<hr id=answer>\n\n{{Back}}', fields),
      '\n\n<b>dog</b>',
    );
    expect(
      renderAnkiBack('{{FrontSide}}<hr id="answer">{{Back}}', fields),
      '<b>dog</b>',
    );
    expect(renderAnkiBack('{{Back}}', fields), '<b>dog</b>');
  });
}
