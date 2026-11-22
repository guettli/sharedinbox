import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:sharedinbox/core/encrypted_objects/key_mail.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/recovery_key.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

/// Reproduces test/fixtures/encrypted_objects/vectors.json (section 8),
/// generated independently by scripts/gen_encrypted_objects_vectors.py.
void main() {
  final vectors = jsonDecode(
    File('test/fixtures/encrypted_objects/vectors.json').readAsStringSync(),
  ) as Map<String, dynamic>;

  test('hkdf', () async {
    final v = vectors['hkdf'] as Map<String, dynamic>;
    final root = SecretKeyData(hexBytes(v['root'] as String));
    final subKeys = v['subKeys'] as Map<String, dynamic>;
    expect(
      subKeys.values.map((s) => (s as Map)['info']).toList(),
      HkdfInfo.all,
    );
    for (final s in subKeys.values.cast<Map<String, dynamic>>()) {
      final derived = await deriveSubKey(root, s['info'] as String);
      expect(toHex(derived.bytes), s['key'], reason: s['info'] as String);
    }
  });

  test('recoveryKey', () async {
    final v = vectors['recoveryKey'] as Map<String, dynamic>;
    final key = RecoveryKey(hexBytes(v['raw'] as String));
    expect(toHex(await key.checksum()), v['checksum']);
    expect(await key.format(), v['formatted']);
    expect(toHex((await key.kek()).bytes), v['kek']);
    final parsed = await RecoveryKey.parse(v['formatted'] as String);
    expect(toHex(parsed.raw), v['raw']);
  });

  test('slotWrap', () async {
    final v = vectors['slotWrap'] as Map<String, dynamic>;
    final accountKey = AccountKey(
      hexBytes(v['accountKeyId'] as String),
      hexBytes(v['accountKey'] as String),
    );
    final kek = SecretKeyData(hexBytes(v['kek'] as String));
    final slotId = hexBytes(v['slotId'] as String);
    expect(
      toHex(
        slotAad(
          accountKeyId: accountKey.accountKeyId,
          slotId: slotId,
          type: v['type'] as String,
        ),
      ),
      v['aad'],
    );
    final slot = await wrapSlot(
      accountKey,
      kek,
      v['type'] as String,
      random: queuedRandom([slotId, hexBytes(v['nonce'] as String)]),
    );
    expect(toHex(slot.wrapped), v['wrapped']);
    final back = await unwrapSlot(slot, kek, accountKey.accountKeyId);
    expect(back.key.bytes, accountKey.key.bytes);
  });

  test('collectionWrap', () async {
    final v = vectors['collectionWrap'] as Map<String, dynamic>;
    final accountKey = AccountKey(
      hexBytes(v['accountKeyId'] as String),
      hexBytes(v['accountKey'] as String),
    );
    final collectionKey = CollectionKey(
      v['collectionId'] as String,
      hexBytes(v['keyId'] as String),
      hexBytes(v['collectionKey'] as String),
    );
    expect(toHex((await accountKey.kWrap()).bytes), v['kWrap']);
    expect(
      toHex(
        collectionWrapAad(
          accountKeyId: accountKey.accountKeyId,
          collectionId: collectionKey.collectionId,
          keyId: collectionKey.keyId,
          wrapType: v['wrapType'] as String,
        ),
      ),
      v['aad'],
    );
    final wrap = await wrapCollectionKey(
      accountKey,
      collectionKey,
      random: queuedRandom([hexBytes(v['nonce'] as String)]),
    );
    expect(toHex(wrap.wrapped), v['wrapped']);
  });

  test('keyMailMac', () async {
    final v = vectors['keyMailMac'] as Map<String, dynamic>;
    final slotV = vectors['slotWrap'] as Map<String, dynamic>;
    final accountKey = AccountKey(
      hexBytes(slotV['accountKeyId'] as String),
      hexBytes(v['accountKey'] as String),
    );
    final kSlots = await accountKey.kSlots();
    expect(toHex(kSlots.bytes), v['kSlots']);
    final slot = UnlockSlot(
      slotId: hexBytes(slotV['slotId'] as String),
      type: slotV['type'] as String,
      nonce: hexBytes(slotV['nonce'] as String),
      wrapped: hexBytes(slotV['wrapped'] as String),
    );
    final signed = await KeyMailPayload(
      accountKeyId: accountKey.accountKeyId,
      slotListVersion: 1,
      slots: [slot],
    ).serialize(kSlots);
    expect(utf8.decode(signed.bytes), v['payload']);
    expect(toHex(signed.mac), v['mac']);
    final parsed = SignedKeyMail.parse(
      utf8.encode(v['payload'] as String),
      hexBytes(v['mac'] as String),
    );
    expect(await parsed.verify(kSlots), isTrue);
    expect(
      b64url(parsed.payload.accountKeyId),
      b64url(accountKey.accountKeyId),
    );
  });
}
