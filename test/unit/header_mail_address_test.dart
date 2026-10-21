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
    test('quotes plain ASCII names', () {
      expect(encodeDisplayName('Bob'), '"Bob"');
      expect(encodeDisplayName('Smith, Bob'), '"Smith, Bob"');
    });

    test('encodes names with quotes or backslashes', () {
      for (final name in [r'Bob "the" \ Builder', 'O"Brien']) {
        final encoded = encodeDisplayName(name);
        expect(encoded, startsWith('=?UTF-8?B?'));
        expect(encoded, isNot(contains('"')));
      }
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

    test('quotes in names cannot change the SMTP recipients', () {
      // enough_mail reads RCPT TO back from the header, ignoring \".
      final message = (MessageBuilder()
            ..from = [HeaderMailAddress('Alice', 'alice@example.com')]
            ..to = [
              HeaderMailAddress('O"Brien', 'obrien@example.com'),
              HeaderMailAddress(
                'x" <attacker@evil.test>, "',
                'victim@example.com',
              ),
              HeaderMailAddress(r'Bob \ Builder', 'bob@example.com'),
            ]
            ..subject = 'x'
            ..text = 'x')
          .buildMimeMessage();
      expect(message.recipientAddresses, [
        'obrien@example.com',
        'victim@example.com',
        'bob@example.com',
      ]);
      final parsed = MimeMessage.parseFromText(message.renderMessage());
      expect(parsed.to!.map((a) => a.personalName), [
        'O"Brien',
        'x" <attacker@evil.test>, "',
        r'Bob \ Builder',
      ]);
    });

    test('a long name without spaces folds and parses back', () {
      final name = 'N' * 90;
      final header = _header(
        HeaderMailAddress('Alice', 'alice@example.com'),
        [HeaderMailAddress(name, 'bob@example.com')],
      );
      for (final line in header.split('\r\n')) {
        expect(line.length, lessThanOrEqualTo(76), reason: line);
      }
      final parsed = MimeMessage.parseFromText('$header\r\n\r\nx');
      expect(parsed.to!.single.personalName, name);
      expect(parsed.to!.single.email, 'bob@example.com');
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
