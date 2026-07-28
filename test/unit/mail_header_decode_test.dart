import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/utils/mail_header_decode.dart';

void main() {
  group('decodeMailHeader', () {
    test('returns null for null and empty for empty', () {
      expect(decodeMailHeader(null), isNull);
      expect(decodeMailHeader(''), '');
    });

    test('passes plain ASCII through unchanged', () {
      expect(decodeMailHeader('Hello world'), 'Hello world');
    });

    test('decodes a single quoted-printable encoded-word', () {
      expect(
        decodeMailHeader('=?utf-8?Q?f=C3=BCr_Tills_Rucksack?='),
        'für Tills Rucksack',
      );
    });

    test('decodes a single base64 encoded-word', () {
      expect(
        decodeMailHeader(
          '=?utf-8?B?ZsO8ciBUaWxscyBSdWNrc2FjaywgR8O8cnRlbHNjaG5hbGxl?=',
        ),
        'für Tills Rucksack, Gürtelschnalle',
      );
    });

    test('preserves whitespace between plain text and an encoded-word', () {
      expect(
        decodeMailHeader('Prefix =?utf-8?Q?=C3=BCber?= suffix'),
        'Prefix über suffix',
      );
    });

    test('strips SP between adjacent encoded-words (§6.2)', () {
      expect(
        decodeMailHeader(
          '=?utf-8?Q?f?= =?utf-8?Q?=C3=BCr_Tills_Rucksack,_G=C3=BC?= '
          '=?utf-8?Q?rtelschnalle?=',
        ),
        'für Tills Rucksack, Gürtelschnalle',
      );
    });

    test(
        'strips SP between adjacent encoded-words with mismatched '
        'charset case (#418)', () {
      // Same content as above but the middle encoded-word capitalises the
      // charset — the buggy path in enough_mail leaves a stray space in.
      expect(
        decodeMailHeader(
          '=?utf-8?Q?f?= =?UTF-8?Q?=C3=BCr_Tills_Rucksack,_G=C3=BC?= '
          '=?utf-8?Q?rtelschnalle?=',
        ),
        'für Tills Rucksack, Gürtelschnalle',
      );
    });

    test('unfolds RFC 5322 folding with HTAB between encoded-words (#418)', () {
      expect(
        decodeMailHeader(
          '=?utf-8?Q?f?=\r\n\t=?utf-8?Q?=C3=BCr_Tills_Rucksack,_G=C3=BC?='
          '\r\n\t=?utf-8?Q?rtelschnalle?=',
        ),
        'für Tills Rucksack, Gürtelschnalle',
      );
    });
  });
}
