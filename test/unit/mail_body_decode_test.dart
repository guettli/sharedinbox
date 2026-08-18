import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/utils/mail_body_decode.dart';

/// Builds a message whose single `text/html` part is quoted-printable and ends
/// with a dangling `=` — the exact shape that makes enough_mail 2.1.7 throw
/// `RangeError (end)` from `QuotedPrintableMailCodec.decodeText` (#588). The
/// bytes are synthesized rather than committing the real (political newsletter)
/// attachment from the issue.
MimeMessage _danglingEqualsHtmlMessage(String htmlBody) {
  // No trailing CRLF after the final `=`, so it is a bare escape byte rather
  // than a soft line break (`=\r\n`).
  final raw = 'From: sender@example.com\r\n'
      'Subject: Test\r\n'
      'Content-Type: text/html; charset="utf-8"\r\n'
      'Content-Transfer-Encoding: quoted-printable\r\n'
      '\r\n'
      '$htmlBody=';
  return MimeMessage.parseFromText(raw);
}

void main() {
  group('decodeTextHtmlPartSafe', () {
    test('reproduces the enough_mail RangeError on the raw decoder', () {
      final msg = _danglingEqualsHtmlMessage('<p>f=C3=BCr Tills</p>');
      // Guards the regression: if enough_mail stops throwing here, the
      // workaround is no longer needed and this test flags it.
      expect(msg.decodeTextHtmlPart, throwsRangeError);
    });

    test('recovers the html body despite the dangling =', () {
      final msg = _danglingEqualsHtmlMessage('<p>f=C3=BCr Tills</p>');
      expect(decodeTextHtmlPartSafe(msg), '<p>für Tills</p>');
    });

    test('returns null when there is no html part rather than throwing', () {
      final msg = MimeMessage.parseFromText(
        'Subject: Test\r\n'
        'Content-Type: text/plain; charset="utf-8"\r\n'
        '\r\n'
        'plain body\r\n',
      );
      expect(decodeTextHtmlPartSafe(msg), isNull);
    });

    test('recovers a dangling = in a nested multipart/alternative part', () {
      // The real-world message is multipart, so exercise the nested traversal.
      final msg = MimeMessage.parseFromText(
        'Subject: Test\r\n'
        'Content-Type: multipart/alternative; boundary="b"\r\n'
        '\r\n'
        '--b\r\n'
        'Content-Type: text/plain; charset="utf-8"\r\n'
        '\r\n'
        'plain fallback\r\n'
        '--b\r\n'
        'Content-Type: text/html; charset="utf-8"\r\n'
        'Content-Transfer-Encoding: quoted-printable\r\n'
        '\r\n'
        // A part is always CRLF-terminated before the boundary, so the dangling
        // `=` only surfaces after the decoder strips the trailing `=\r\n` soft
        // break — the shape the real newsletter hit.
        '<p>f=C3=BCr Tills</p>==\r\n'
        '--b--\r\n',
      );
      expect(msg.decodeTextHtmlPart, throwsRangeError);
      expect(decodeTextHtmlPartSafe(msg), contains('für Tills'));
    });

    test('passes a well-formed html part straight through', () {
      final msg = MimeMessage.parseFromText(
        'Subject: Test\r\n'
        'Content-Type: text/html; charset="utf-8"\r\n'
        'Content-Transfer-Encoding: quoted-printable\r\n'
        '\r\n'
        '<p>f=C3=BCr Tills</p>\r\n',
      );
      // Well-formed part: enough_mail's own decoder is used unchanged, trailing
      // CRLF and all.
      expect(decodeTextHtmlPartSafe(msg), '<p>für Tills</p>\r\n');
    });
  });

  group('decodeTextPlainPartSafe', () {
    test('recovers the plain body despite the dangling =', () {
      const raw = 'Subject: Test\r\n'
          'Content-Type: text/plain; charset="utf-8"\r\n'
          'Content-Transfer-Encoding: quoted-printable\r\n'
          '\r\n'
          'f=C3=BCr Tills=';
      final msg = MimeMessage.parseFromText(raw);
      expect(msg.decodeTextPlainPart, throwsRangeError);
      expect(decodeTextPlainPartSafe(msg), 'für Tills');
    });
  });
}
