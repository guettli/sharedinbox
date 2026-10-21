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
    expect(rawEmailFilename('ü' * 200), '${'ü' * 120}.eml');
  });
}
