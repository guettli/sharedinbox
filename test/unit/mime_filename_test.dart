import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/utils/mime_filename.dart';

/// The file name the app reads for the one attachment of a message whose
/// attachment part has the given header lines.
String? _nameOf(String partHeaders) {
  final raw = [
    'Content-Type: multipart/mixed; boundary="b"',
    '',
    '--b',
    'Content-Type: text/plain',
    '',
    'body',
    '--b',
    partHeaders,
    '',
    'data',
    '--b--',
    '',
  ].join('\r\n');
  final info = MimeMessage.parseFromText(raw).findContentInfo().single;
  return mimePartFileName(info.contentDisposition, info.contentType);
}

void main() {
  group('mimePartFileName', () {
    test('RFC 2231 filename* (as Thunderbird sends non-ASCII names)', () {
      expect(
        _nameOf(
          'Content-Type: application/pdf\r\n'
          'Content-Disposition: attachment; '
          "filename*=UTF-8''%C3%9Cbersicht%20M%C3%A4rz%202026.pdf",
        ),
        'Übersicht März 2026.pdf',
      );
    });

    test('RFC 2231 continuations, mixed encoded and plain', () {
      expect(
        _nameOf(
          'Content-Type: application/pdf\r\n'
          'Content-Disposition: attachment;\r\n'
          " filename*0*=UTF-8''%C3%9Cber;\r\n"
          ' filename*1*=sicht%20lang;\r\n'
          ' filename*2=.pdf',
        ),
        'Übersicht lang.pdf',
      );
    });

    test('RFC 2231 with another charset and a language', () {
      expect(
        _nameOf(
          'Content-Type: text/plain\r\n'
          "Content-Disposition: attachment; filename*=iso-8859-1'de'%DCber.txt",
        ),
        'Über.txt',
      );
    });

    test('Content-Type name* when the disposition has no name', () {
      expect(
        _nameOf(
          "Content-Type: application/pdf; name*=UTF-8''r%C3%A9sum%C3%A9.pdf\r\n"
          'Content-Disposition: attachment',
        ),
        'résumé.pdf',
      );
    });

    test('plain and encoded-word names still work', () {
      expect(
        _nameOf(
          'Content-Type: application/pdf\r\n'
          'Content-Disposition: attachment; filename="a b.pdf"',
        ),
        'a b.pdf',
      );
      expect(
        _nameOf(
          'Content-Type: application/pdf; name="=?UTF-8?B?w5xiZXIucGRm?="\r\n'
          'Content-Disposition: attachment',
        ),
        'Über.pdf',
      );
    });

    test('null without a name', () {
      expect(
        _nameOf(
          'Content-Type: application/pdf\r\n'
          'Content-Disposition: attachment',
        ),
        isNull,
      );
    });
  });

  group('mimePartFileName edge cases', () {
    test('malformed RFC 2231 never throws and falls back', () {
      expect(
        _nameOf(
          'Content-Type: application/pdf\r\n'
          'Content-Disposition: attachment; '
          'filename*99999999999999999999=x; filename="plain.pdf"',
        ),
        'plain.pdf',
      );
      expect(
        _nameOf(
          'Content-Type: application/pdf\r\n'
          "Content-Disposition: attachment; filename*0*=UTF-8''a; "
          'filename*1=日本.pdf',
        ),
        'a日本.pdf',
      );
    });

    test('a missing first segment falls back to the plain name', () {
      expect(
        _nameOf(
          'Content-Type: application/pdf; name="type.pdf"\r\n'
          'Content-Disposition: attachment; filename*1=tail.pdf',
        ),
        'type.pdf',
      );
    });

    test('segments out of order, quoted value, upper-case key', () {
      expect(
        _nameOf(
          'Content-Type: application/pdf\r\n'
          'Content-Disposition: attachment; FILENAME*1=b.pdf; '
          '''filename*0*="UTF-8''%C3%9C"''',
        ),
        'Üb.pdf',
      );
    });

    test('percent-decoding takes only two hex digits', () {
      expect(
        rfc2231Parameter({'f*': "UTF-8''a%-1b%+Fc%"}, 'f'),
        'a%-1b%+Fc%',
      );
    });

    test('an unknown charset still yields a name', () {
      expect(rfc2231Parameter({'f*': "x-unknown''abc"}, 'f'), 'abc');
    });

    test('the disposition filename wins over Content-Type name*', () {
      expect(
        _nameOf(
          "Content-Type: application/pdf; name*=UTF-8''type.pdf\r\n"
          'Content-Disposition: attachment; filename="disp.pdf"',
        ),
        'disp.pdf',
      );
    });

    test('works for parameters set from a BODYSTRUCTURE', () {
      final disposition = ContentDispositionHeader('attachment')
        ..setParameter('FILENAME*', "UTF-8''%C3%9C.pdf");
      expect(mimePartFileName(disposition, null), 'Ü.pdf');
    });
  });

  group('safeFileName', () {
    test('strips directories and control characters', () {
      expect(safeFileName('../../.config/autostart/x.desktop'), 'x.desktop');
      expect(safeFileName('/etc/passwd'), 'passwd');
      expect(safeFileName(r'..\..\evil.exe'), 'evil.exe');
      expect(safeFileName('a\r\nb\u0000.pdf'), 'a__b_.pdf');
      expect(safeFileName('Übersicht März.pdf'), 'Übersicht März.pdf');
    });

    test('never returns an empty or dot name', () {
      for (final name in ['', '..', '.', '/', '   ']) {
        expect(safeFileName(name), 'attachment');
      }
    });

    test('an RFC 2231 name with %2F cannot climb out', () {
      final name = rfc2231Parameter({'f*': "UTF-8''..%2F..%2Fx.sh"}, 'f')!;
      expect(name, '../../x.sh');
      expect(safeFileName(name), 'x.sh');
    });
  });
}
