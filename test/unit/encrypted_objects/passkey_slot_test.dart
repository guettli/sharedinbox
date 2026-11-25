import 'dart:typed_data';

import 'package:sharedinbox/core/encrypted_objects/key_mail.dart';
import 'package:sharedinbox/core/encrypted_objects/passkey_slot.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:test/test.dart';

import 'fake_prf_provider.dart';
import 'test_helpers.dart';

final _output = seqBytes(0x60, 32);
final _credentialId = seqBytes(0xd0, 16);
final _salt = seqBytes(0xe0, 32);

Future<UnlockSlot> _wrap() => wrapPasskeySlot(
      testAccountKey,
      _output,
      credentialId: _credentialId,
      salt: _salt,
      label: 'Phone',
    );

UnlockSlot _edit(UnlockSlot slot, Map<String, Object?> changes) =>
    UnlockSlot.fromJson({...slot.toJson(), ...changes});

void main() {
  test('round-trips with the PRF output; the clear fields are stored',
      () async {
    final slot = await _wrap();
    expect(slot.type, UnlockSlotType.passkeyPrf);
    expect(slot.extra, {
      'credentialId': b64url(_credentialId),
      'prfSalt': b64url(_salt),
      'rpId': passkeyRpId,
      'label': 'Phone',
    });

    final info = PasskeySlotInfo.parse(slot);
    expect(info.credentialId, _credentialId);
    expect(info.credentialIdB64, b64url(_credentialId));
    expect(info.prfSalt, _salt);
    expect(info.rpId, 'keys.sharedinbox.de');
    expect(info.label, 'Phone');
    expect(info.slotIdB64, slot.slotIdB64);

    final key =
        await unwrapPasskeySlot(slot, _output, testAccountKey.accountKeyId);
    expect(key.key.bytes, testAccountKey.key.bytes);
  });

  test('another PRF output does not open', () async {
    final slot = await _wrap();
    await expectLater(
      unwrapPasskeySlot(slot, seqBytes(0x61, 32), testAccountKey.accountKeyId),
      throwsA(isA<KeyUnwrapException>()),
    );
    await expectLater(
      unwrapPasskeySlot(slot, seqBytes(0x60, 31), testAccountKey.accountKeyId),
      throwsA(isA<KeyUnwrapException>()),
    );
    expect(() => passkeyKek(Uint8List(16)), throwsArgumentError);
  });

  test('a relabelled slotId or type fails the AAD', () async {
    final slot = await _wrap();
    await expectLater(
      unwrapPasskeySlot(
        _edit(slot, {'slotId': b64url(seqBytes(0x01, 16))}),
        _output,
        testAccountKey.accountKeyId,
      ),
      throwsA(isA<KeyUnwrapException>()),
    );
    // As another type the KEK still matches, the AAD does not.
    final relabelled = _edit(slot, {'type': UnlockSlotType.recovery});
    await expectLater(
      unwrapSlot(
        relabelled,
        await passkeyKek(_output),
        testAccountKey.accountKeyId,
      ),
      throwsA(isA<KeyUnwrapException>()),
    );
    await expectLater(
      unwrapPasskeySlot(relabelled, _output, testAccountKey.accountKeyId),
      throwsFormatException,
    );
  });

  test('a malformed slot is skipped by tryParse and refused by unwrap',
      () async {
    final slot = await _wrap();
    for (final bad in <Map<String, Object?>>[
      {'credentialId': null},
      {'credentialId': ''},
      {'credentialId': b64url(Uint8List(1024))},
      {'credentialId': '!!'},
      {'prfSalt': b64url(Uint8List(16))},
      {'prfSalt': null},
      {'rpId': 7},
      {'label': 3},
    ]) {
      final edited = _edit(slot, bad);
      expect(PasskeySlotInfo.tryParse(edited), isNull, reason: '$bad');
      await expectLater(
        unwrapPasskeySlot(edited, _output, testAccountKey.accountKeyId),
        throwsFormatException,
        reason: '$bad',
      );
    }
    // A missing label reads as empty.
    final noLabel = UnlockSlot.fromJson({...slot.toJson()}..remove('label'));
    expect(PasskeySlotInfo.parse(noLabel).label, '');
  });

  test('unknown fields survive a JSON round trip of the key mail', () async {
    final slot = _edit(await _wrap(), {'future': 1});
    final payload = KeyMailPayload(
      accountKeyId: testAccountKey.accountKeyId,
      slotListVersion: 1,
      slots: [slot],
    );
    final parsed = KeyMailPayload.parse(payload.bytes).slots.single;
    expect(parsed.extra, slot.extra);
    expect(parsed.extra['future'], 1);
    final key =
        await unwrapPasskeySlot(parsed, _output, testAccountKey.accountKeyId);
    expect(key.key.bytes, testAccountKey.key.bytes);
  });

  test('the fake provider: the same salt gives the same output', () async {
    final prf = FakePrfProvider();
    final reg = await prf.register(
      rpId: passkeyRpId,
      userId: Uint8List(16),
      userName: 'a@example.com',
      challenge: Uint8List(32),
    );
    Future<PrfAssertion> eval(Uint8List salt) => prf.evaluate(
          rpId: passkeyRpId,
          challenge: Uint8List(32),
          evalByCredential: {b64url(reg.credentialId): salt},
        );
    final a = await eval(_salt);
    expect(a.credentialId, reg.credentialId);
    expect(a.output, hasLength(prfOutputLength));
    expect((await eval(_salt)).output, a.output);
    expect((await eval(seqBytes(1, 32))).output, isNot(a.output));
  });
}
