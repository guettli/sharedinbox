import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/utils/mail_header_encode.dart';
import 'package:sharedinbox/data/imap/header_mail_address.dart';

/// The rendered header block of a message from [from] to [to].
String _header(MailAddress from, List<MailAddress> to) => (MessageBuilder()
      ..from = [from]
      ..to = to
      ..subject = 'x'
      ..text = 'x')
    .buildMimeMessage()
    .renderMessage()
    .split('\r\n\r\n')
    .first;

void main() {
  group('encodeDisplayName', () {
    test('quotes ASCII and escapes quotes and backslashes', () {
      expect(encodeDisplayName('Bob'), '"Bob"');
      expect(
        encodeDisplayName(r'Bob "the" \ Builder'),
        r'"Bob \"the\" \\ Builder"',
      );
    });

    test('encodes non-ASCII without quotes', () {
      final encoded = encodeDisplayName('Alice Müller');
      expect(encoded, startsWith('=?UTF-8?B?'));
      expect(encoded, isNot(contains('"')));
    });

    test('blank and control characters', () {
      expect(encodeDisplayName('  '), '');
      expect(
        encodeDisplayName('Bob\r\nBcc: x@evil.test'),
        '"Bob Bcc: x@evil.test"',
      );
    });
  });

  group('HeaderMailAddress', () {
    test('a rendered message parses back to the same names', () {
      final header = _header(
        HeaderMailAddress('Alice Müller', 'alice@example.com'),
        [
          HeaderMailAddress('Bob "B" Smith', 'bob@example.com'),
          HeaderMailAddress('Zoë 😀', 'zoe@example.com'),
          HeaderMailAddress(null, 'carol@example.com'),
        ],
      );
      expect(header, isNot(contains('"=?')), reason: header);
      final parsed = MimeMessage.parseFromText('$header\r\n\r\nx');
      expect(parsed.from!.single.personalName, 'Alice Müller');
      expect(parsed.from!.single.email, 'alice@example.com');
      expect(
        parsed.to!.map((a) => (a.personalName ?? '', a.email)).toList(),
        [
          ('Bob "B" Smith', 'bob@example.com'),
          ('Zoë 😀', 'zoe@example.com'),
          ('', 'carol@example.com'),
        ],
      );
    });

    test('a name or address with CR/LF adds no header', () {
      final header = _header(
        HeaderMailAddress('Alice', 'alice@example.com'),
        [
          HeaderMailAddress(
            'Bob\r\nBcc: x@evil.test',
            'bob@example.com\r\nX: 1',
          ),
        ],
      );
      final names = header
          .split('\r\n')
          .where((l) => !l.startsWith('\t') && !l.startsWith(' '))
          .map((l) => l.split(':').first.toLowerCase());
      expect(names, isNot(contains('bcc')), reason: header);
      expect(names, isNot(contains('x')), reason: header);
    });
  });
}
