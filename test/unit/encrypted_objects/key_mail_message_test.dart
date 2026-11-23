import 'dart:convert';
import 'dart:typed_data';

import 'package:sharedinbox/core/encrypted_objects/collection_key_mail.dart';
import 'package:sharedinbox/core/encrypted_objects/key_mail.dart';
import 'package:sharedinbox/core/encrypted_objects/key_mail_message.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/recovery_key.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

const _messageId = '<abc@sharedinbox.invalid>';
final _date = DateTime.utc(2026, 11, 23, 10);

Future<SignedKeyMail> _signed() async {
  final slot = await wrapRecoverySlot(
    testAccountKey,
    RecoveryKey(seqBytes(0x40, 16)),
    random: counterRandom(),
  );
  final payload = KeyMailPayload(
    accountKeyId: testAccountKey.accountKeyId,
    slotListVersion: 1,
    slots: [slot],
  );
  return payload.serialize(await testAccountKey.kSlots());
}

String _text(Uint8List mail) => ascii.decode(mail);

void main() {
  test('an account-key mail round-trips and its MAC verifies', () async {
    final signed = await _signed();
    final mail = buildKeyMail(messageId: _messageId, mail: signed, date: _date);

    final text = _text(mail);
    expect(text, contains('X-SharedInbox-Schema: 1\r\n'));
    expect(text, contains('X-SharedInbox-Key-Kind: account-key\r\n'));
    expect(text, contains('Content-Transfer-Encoding: base64\r\n'));
    expect(text, contains('X-SharedInbox-Key-Mac: ${b64url(signed.mac)}\r\n'));

    final parsed = parseKeyMailMessage(mail);
    expect(parsed, isA<AccountKeyMailMsg>());
    parsed as AccountKeyMailMsg;
    expect(parsed.messageId, _messageId);
    expect(parsed.mail.bytes, signed.bytes);
    expect(parsed.mail.mac, signed.mac);
    expect(await parsed.mail.verify(await testAccountKey.kSlots()), isTrue);
  });

  test('the same JSON in another key order does not verify with the old MAC',
      () async {
    final signed = await _signed();
    final json = jsonDecode(utf8.decode(signed.bytes)) as Map<String, Object?>;
    final reordered = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          for (final k in json.keys.toList().reversed) k: json[k],
        }),
      ),
    );
    expect(reordered, isNot(signed.bytes));
    final tampered = SignedKeyMail(KeyMailPayload.parse(reordered), signed.mac);
    final mail =
        buildKeyMail(messageId: _messageId, mail: tampered, date: _date);

    final parsed = parseKeyMailMessage(mail) as AccountKeyMailMsg;
    expect(await parsed.mail.verify(await testAccountKey.kSlots()), isFalse);
  });

  test('an account-key mail without or with two MAC headers is rejected',
      () async {
    final signed = await _signed();
    final text = _text(
      buildKeyMail(messageId: _messageId, mail: signed, date: _date),
    );
    final macLine = 'X-SharedInbox-Key-Mac: ${b64url(signed.mac)}\r\n';

    expect(
      () => parseKeyMailMessage(
        Uint8List.fromList(ascii.encode(text.replaceFirst(macLine, ''))),
      ),
      throwsFormatException,
    );
    expect(
      () => parseKeyMailMessage(
        Uint8List.fromList(
          ascii.encode(text.replaceFirst(macLine, '$macLine$macLine')),
        ),
      ),
      throwsFormatException,
    );
  });

  test('a collection-key mail round-trips without a MAC', () async {
    final key = CollectionKey(
      personalCollectionId,
      seqBytes(0xc0, 16),
      seqBytes(0x60, 32),
    );
    final ck = await CollectionKeyMail.create(
      testAccountKey,
      key,
      random: counterRandom(),
    );
    final mail =
        buildCollectionKeyMail(messageId: _messageId, mail: ck, date: _date);
    expect(_text(mail), contains('X-SharedInbox-Key-Kind: collection-key'));
    expect(_text(mail), isNot(contains('X-SharedInbox-Key-Mac')));

    final parsed = parseKeyMailMessage(mail) as CollectionKeyMailMsg;
    expect(parsed.mail.bytes, ck.bytes);
    final unwrapped = await parsed.mail.unwrapWith(testAccountKey);
    expect(unwrapped.key.bytes, key.key.bytes);
  });

  test('a foreign mail or an unknown kind is a FormatException', () async {
    final plain = Uint8List.fromList(
      ascii.encode(
        'Message-ID: <x@example.com>\r\nSubject: Hi\r\n\r\nHello\r\n',
      ),
    );
    expect(() => parseKeyMailMessage(plain), throwsFormatException);

    final pairing = _text(
      buildKeyMail(messageId: _messageId, mail: await _signed(), date: _date),
    ).replaceFirst('Key-Kind: account-key', 'Key-Kind: pairing');
    expect(
      () => parseKeyMailMessage(Uint8List.fromList(ascii.encode(pairing))),
      throwsFormatException,
    );
  });
}
