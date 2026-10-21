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
}
