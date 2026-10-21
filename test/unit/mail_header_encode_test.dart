import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/utils/mail_header_decode.dart';
import 'package:sharedinbox/core/utils/mail_header_encode.dart';

/// Builds a message with [subject] the way the outbox does and renders it.
String _rendered(String subject) => (MessageBuilder()
      ..from = [const MailAddress('A', 'a@example.com')]
      ..to = [const MailAddress('B', 'b@example.com')]
      ..subject = encodeUnstructuredHeader(subject)
      ..subjectEncoding = HeaderEncoding.none
      ..text = 'x')
    .buildMimeMessage()
    .renderMessage();

/// The raw Subject header lines of [_rendered].
List<String> _renderedSubjectLines(String subject) {
  final lines = _rendered(subject).split('\r\n');
  final start = lines.indexWhere((l) => l.startsWith('Subject: '));
  return [
    lines[start],
    ...lines.skip(start + 1).takeWhile((l) => l.startsWith('\t')),
  ];
}

void main() {
  group('encodeUnstructuredHeader', () {
    test('leaves ASCII alone', () {
      expect(encodeUnstructuredHeader('Hello, world'), 'Hello, world');
    });

    test('encodes the whole value, never glued to plain text', () {
      final encoded = encodeUnstructuredHeader('Grüße aus dem Test ✓');
      expect(encoded, startsWith('=?UTF-8?B?'));
      for (final word in encoded.split(' ')) {
        expect(word, matches(RegExp(r'^=\?UTF-8\?B\?[A-Za-z0-9+/=]+\?=$')));
        expect(word.length, lessThanOrEqualTo(52));
      }
      expect(decodeMailHeader(encoded), 'Grüße aus dem Test ✓');
    });

    test('never splits a character across words', () {
      final text = '😀' * 20 + ' über';
      final encoded = encodeUnstructuredHeader(text);
      expect(encoded.split(' ').length, greaterThan(1));
      expect(decodeMailHeader(encoded), text);
    });

    test('CR and LF cannot end the header', () {
      for (final subject in ['Hi\r\nBcc: x@evil.test', 'Grüße\r\nX-Evil: 1']) {
        final header = _rendered(subject).split('\r\n\r\n').first;
        final names = header
            .split('\r\n')
            .where((l) => !l.startsWith('\t') && !l.startsWith(' '))
            .map((l) => l.split(':').first.toLowerCase());
        expect(names, isNot(contains('bcc')), reason: header);
        expect(names, isNot(contains('x-evil')), reason: header);
      }
      expect(encodeUnstructuredHeader('Hi\r\nthere'), 'Hi there');
    });

    test('keeps leading and trailing spaces', () {
      expect(decodeMailHeader(encodeUnstructuredHeader(' ä ')), ' ä ');
    });

    test('a long ASCII token is encoded so it folds cleanly', () {
      final token = 'x' * 120;
      final lines = _renderedSubjectLines('see $token');
      for (final line in lines) {
        expect(line.length, lessThanOrEqualTo(76), reason: line);
      }
      final parsed =
          MimeMessage.parseFromText('${lines.join('\r\n')}\r\n\r\nx');
      expect(parsed.decodeSubject(), 'see $token');
      expect(encodeUnstructuredHeader('short ascii'), 'short ascii');
    });

    test('a long subject folds into valid lines and parses back', () {
      final subject = 'Rückfrage zur Größe der Übersetzung — ' * 4;
      final lines = _renderedSubjectLines(subject);
      expect(lines.length, greaterThan(1));
      for (final line in lines) {
        expect(line.length, lessThanOrEqualTo(76), reason: line);
      }
      final parsed =
          MimeMessage.parseFromText('${lines.join('\r\n')}\r\n\r\nx');
      expect(decodeMailHeader(parsed.getHeaderValue('subject')), subject);
      expect(parsed.decodeSubject(), subject);
    });
  });
}
