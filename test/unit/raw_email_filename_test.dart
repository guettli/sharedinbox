import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/platform/raw_email_downloader.dart';

void main() {
  test('keeps ASCII letters, digits, spaces and dashes', () {
    expect(
      rawEmailFilename('Invoice 4711 - final'),
      'Invoice 4711 - final.eml',
    );
    expect(rawEmailFilename('Re: a/b?c'), 'Re_ a_b_c.eml');
  });

  test('keeps letters of any script', () {
    // An ASCII-only \w made these "Gr_e aus M_nchen.eml" and "_ _ _.eml".
    expect(rawEmailFilename('Grüße aus München'), 'Grüße aus München.eml');
    expect(rawEmailFilename('Привет из Москвы'), 'Привет из Москвы.eml');
    expect(rawEmailFilename('東京の会議'), '東京の会議.eml');
  });

  test('falls back to "email" and clips long subjects', () {
    expect(rawEmailFilename(null), 'email.eml');
    expect(rawEmailFilename('???'), '_.eml');
    // At most 200 UTF-8 bytes before ".eml": 'ü' is 2 bytes, '会' is 3.
    expect(rawEmailFilename('ü' * 200), '${'ü' * 100}.eml');
    expect(rawEmailFilename('会' * 200), '${'会' * 66}.eml');
  });

  test('turns tabs, line breaks and control characters into plain text', () {
    expect(rawEmailFilename('a\tb\nc'), 'a b c.eml');
    // A right-to-left override is not a letter.
    expect(rawEmailFilename('fdp.\u202Eexe'), 'fdp_exe.eml');
  });
}
