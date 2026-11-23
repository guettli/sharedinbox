import 'dart:convert';
import 'dart:typed_data';

import 'package:sharedinbox/core/encrypted_objects/object_mail.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  final hmac = seqBytes(0x10, 32);
  final blob = seqBytes(0x00, 300);
  final date = DateTime.utc(2026, 11, 22, 9, 5, 7);
  const messageId = '<aaaaaaaaaaaaaaaaaaaaaaaaaa@sharedinbox.invalid>';

  Uint8List build({String? from}) => buildObjectMail(
        messageId: messageId,
        itemHmac: hmac,
        blob: blob,
        date: date,
        from: from,
      );

  test('Message-ID is 26 lowercase base32 chars at sharedinbox.invalid', () {
    final id = newMessageId(random: counterRandom(9));
    expect(id, matches(RegExp(r'^<[a-z2-7]{26}@sharedinbox\.invalid>$')));
    expect(newMessageId(), isNot(newMessageId()));
  });

  test('base32Lower matches RFC 4648 without padding', () {
    expect(base32Lower(utf8.encode('')), '');
    expect(base32Lower(utf8.encode('f')), 'my');
    expect(base32Lower(utf8.encode('foobar')), 'mzxw6ytboi');
  });

  test('rfc5322Date formats in UTC', () {
    expect(rfc5322Date(date), 'Sun, 22 Nov 2026 09:05:07 +0000');
  });

  test('build and parse round-trip', () {
    final bytes = build(from: 'me@example.com');
    final text = ascii.decode(bytes);
    expect(text, startsWith('From: me@example.com\r\n'));
    expect(text, contains('Subject: SharedInbox item\r\n'));
    expect(text, contains('X-SharedInbox-Schema: 1\r\n'));
    expect(text, contains(objectMailNotice));
    final lines = text.split('\r\n');
    expect(lines.where((l) => l.length == 76), isNotEmpty);
    expect(lines.every((l) => l.length <= 76), isTrue);
    final mail = parseObjectMail(bytes);
    expect(mail.messageId, messageId);
    expect(mail.schema, '1');
    expect(mail.itemHmac, hmac);
    expect(mail.blob, blob);
  });

  test('the bytes depend only on the arguments', () {
    expect(build(), build());
    expect(ascii.decode(build()), startsWith('Date: '));
  });

  group('rejects', () {
    String mail() => ascii.decode(build());

    final cases = <String, String Function(String)>{
      'a missing schema header': (m) =>
          m.replaceFirst('X-SharedInbox-Schema: 1\r\n', ''),
      'an unknown schema': (m) => m.replaceFirst(
            'X-SharedInbox-Schema: 1',
            'X-SharedInbox-Schema: 2',
          ),
      'a missing item header': (m) =>
          m.replaceFirst(RegExp(r'X-SharedInbox-Item: .*\r\n'), ''),
      'a short item header': (m) => m.replaceFirst(
            RegExp(r'X-SharedInbox-Item: .*\r\n'),
            'X-SharedInbox-Item: AAAA\r\n',
          ),
      'an item header that is not base64url': (m) => m.replaceFirst(
            RegExp(r'X-SharedInbox-Item: .*\r\n'),
            'X-SharedInbox-Item: ***\r\n',
          ),
      'a missing Message-ID': (m) =>
          m.replaceFirst('Message-ID: $messageId\r\n', ''),
      'a missing octet-stream part': (m) =>
          m.replaceFirst('application/octet-stream', 'text/plain'),
    };
    for (final c in cases.entries) {
      test(c.key, () {
        final bytes = Uint8List.fromList(ascii.encode(c.value(mail())));
        expect(() => parseObjectMail(bytes), throwsFormatException);
      });
    }
  });
}
