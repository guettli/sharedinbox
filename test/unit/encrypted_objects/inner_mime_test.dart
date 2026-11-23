import 'dart:convert';
import 'dart:typed_data';

import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  Uint8List mime(String text) =>
      Uint8List.fromList(utf8.encode(text.replaceAll('\n', '\r\n')));

  Map<String, Object?> headJson({int v = 1, Object? kind = 'entry'}) => {
        'v': v,
        'itemId': 'item-1',
        'collectionId': 'deck-1',
        'versionId': hlcAt(1000).encode(),
        'parents': [hlcAt(900).encode()],
        if (kind != null) 'kind': kind,
        'future': {'x': 1},
      };

  test('round-trips head and parts', () {
    final object = InnerObject(
      head: ObjectHead(
        itemId: 'item-1',
        collectionId: 'deck-1',
        versionId: hlcAt(2000),
        parents: [hlcAt(1000), hlcAt(1500, 'devB')],
        deleted: true,
        kind: 'entry',
        extra: {
          'title': 'Hi',
          'tags': ['a'],
        },
      ),
      parts: [
        ObjectPart(
          contentType: 'text/markdown; charset=utf-8',
          bytes: Uint8List.fromList(utf8.encode('# Hi\r\n\r\n--x')),
        ),
        ObjectPart(
          contentType: 'image/png',
          contentId: 'img1',
          extraHeaders: {'x-future': 'yes'},
          bytes: Uint8List.fromList([0, 13, 10, 13, 10, 255]),
        ),
      ],
    );
    final bytes = buildInnerMime(object, random: counterRandom());
    expect(
      ascii.decode(bytes.sublist(0, 60)),
      startsWith('Content-Type: multipart/related; boundary="si-'),
    );
    final back = parseInnerMime(bytes);
    expect(back.head.toJson(), object.head.toJson());
    expect(back.head.isParseable, isTrue);
    expect(back.head.deleted, isTrue);
    expect(back.parts, hasLength(2));
    expect(utf8.decode(back.parts[0].bytes), '# Hi\r\n\r\n--x');
    expect(back.parts[1].contentId, 'img1');
    expect(back.parts[1].contentType, 'image/png');
    expect(back.parts[1].extraHeaders, {'x-future': 'yes'});
    expect(back.parts[1].bytes, [0, 13, 10, 13, 10, 255]);
  });

  test('a boundary found in a part is redrawn', () {
    // counterRandom(1) draws twelve 0x01 bytes first: "si-AQEBAQEBAQEBAQEB".
    final object = testObject(body: 'si-AQEBAQEBAQEBAQEB');
    final bytes = buildInnerMime(object, random: counterRandom());
    expect(ascii.decode(bytes.sublist(0, 80)), contains('si-AgICAgICAgICAgIC'));
    expect(
      utf8.decode(parseInnerMime(bytes).parts.single.bytes),
      'si-AQEBAQEBAQEBAQEB',
    );
  });

  test('unknown fields and parts survive a rewrite', () {
    final bytes = mime('''
Content-Type: multipart/related; boundary=b1

--b1
Content-Type: application/json

${jsonEncode(headJson())}
--b1
Content-Type: application/x-future
X-Future: 1

opaque
--b1--
''');
    final parsed = parseInnerMime(bytes);
    expect(parsed.head.extra, {
      'future': {'x': 1},
    });
    expect(parsed.parts.single.contentType, 'application/x-future');
    final rewritten = parseInnerMime(buildInnerMime(parsed));
    expect(rewritten.head.toJson(), headJson());
    expect(rewritten.parts.single.extraHeaders, {'x-future': '1'});
    expect(utf8.decode(rewritten.parts.single.bytes), 'opaque');
  });

  test('an unknown kind parses', () {
    final bytes = mime('''
Content-Type: multipart/related; boundary="b1"

--b1
Content-Type: application/json; charset=utf-8

${jsonEncode(headJson(kind: 'hologram'))}
--b1--
''');
    final parsed = parseInnerMime(bytes);
    expect(parsed.head.kind, 'hologram');
    expect(parsed.head.isParseable, isTrue);
  });

  test('a head of v 2 keeps its prefix but is not parseable', () {
    final bytes = mime('''
Content-Type: multipart/related; boundary=b1

--b1
Content-Type: application/json

${jsonEncode(headJson(v: 2, kind: null))}
--b1--
''');
    final head = parseInnerMime(bytes).head;
    expect(head.isParseable, isFalse);
    expect(head.itemId, 'item-1');
    expect(head.collectionId, 'deck-1');
    expect(head.versionId, hlcAt(1000));
    expect(head.parents, [hlcAt(900)]);
    expect(head.kind, isNull);
  });

  test('base64, 8bit and header-less parts are read', () {
    final bytes = mime(
      '''
preamble
--b1
Content-Type: application/json
Content-Transfer-Encoding: base64

${base64.encode(utf8.encode(jsonEncode(headJson())))}
--b1
Content-Type: text/plain;
 charset=utf-8
Content-Transfer-Encoding: 8bit

folded
--b1

no headers
--b1


--b1--
'''
          .replaceFirst(
        'preamble\n',
        'Content-Type: multipart/related; '
            'boundary=b1\n\npreamble\n',
      ),
    );
    final parsed = parseInnerMime(bytes);
    expect(parsed.head.itemId, 'item-1');
    expect(parsed.parts, hasLength(3));
    expect(parsed.parts[0].contentType, 'text/plain; charset=utf-8');
    expect(utf8.decode(parsed.parts[1].bytes), 'no headers');
    expect(parsed.parts[1].contentType, 'text/plain');
    expect(parsed.parts[2].bytes, isEmpty);
  });

  group('malformed input is rejected', () {
    final cases = {
      'no Content-Type': 'Subject: x\n\n--b1--\n',
      'not related': 'Content-Type: multipart/mixed; boundary=b1\n\n--b1--\n',
      'no boundary': 'Content-Type: multipart/related\n\n--b1--\n',
      'no first boundary': 'Content-Type: multipart/related; boundary=b1\n\nx',
      'no parts': 'Content-Type: multipart/related; boundary=b1\n\n--b1--\n',
      'unterminated': 'Content-Type: multipart/related; boundary=b1\n\n--b1',
      'no close': 'Content-Type: multipart/related; boundary=b1\n\n--b1\n'
          'Content-Type: application/json\n\n{}',
      'head not json': 'Content-Type: multipart/related; boundary=b1\n\n--b1\n'
          'Content-Type: text/plain\n\n{}\n--b1--\n',
      'bad header': 'Content-Type: multipart/related; boundary=b1\n\n--b1\n'
          'nocolon\n\n{}\n--b1--\n',
      'bad encoding': 'Content-Type: multipart/related; boundary=b1\n\n--b1\n'
          'Content-Type: application/json\n'
          'Content-Transfer-Encoding: quoted-printable\n\n{}\n--b1--\n',
      'bad base64': 'Content-Type: multipart/related; boundary=b1\n\n--b1\n'
          'Content-Type: application/json\n'
          'Content-Transfer-Encoding: base64\n\n!!!\n--b1--\n',
      'no header end': 'Content-Type: multipart/related; boundary=b1',
    };
    for (final c in cases.entries) {
      test(c.key, () {
        expect(() => parseInnerMime(mime(c.value)), throwsFormatException);
      });
    }
  });

  group('a malformed head prefix is rejected', () {
    final cases = <String, Map<String, Object?>>{
      'no v': {...headJson()}..remove('v'),
      'no parents': {...headJson()}..remove('parents'),
      'bad parent': {
        ...headJson(),
        'parents': [1],
      },
      'bad deleted': {...headJson(), 'deleted': 'yes'},
      'bad kind': {...headJson(), 'kind': 3},
      'bad versionId': {...headJson(), 'versionId': 'nope'},
      'no itemId': {...headJson()}..remove('itemId'),
    };
    for (final c in cases.entries) {
      test(c.key, () {
        expect(() => ObjectHead.fromJson(c.value), throwsFormatException);
      });
    }
  });

  test('extra may not override a prefix field', () {
    expect(
      () => ObjectHead(
        itemId: 'i',
        collectionId: 'c',
        versionId: hlcAt(1),
        extra: {'itemId': 'x'},
      ),
      throwsArgumentError,
    );
  });
}
