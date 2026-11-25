import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:sharedinbox/core/encrypted_objects/card_object.dart';
import 'package:sharedinbox/core/encrypted_objects/envelope.dart';
import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/encrypted_objects/key_mail.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/log_segment.dart';
import 'package:sharedinbox/core/encrypted_objects/object_mail.dart';
import 'package:sharedinbox/core/encrypted_objects/pairing.dart';
import 'package:sharedinbox/core/encrypted_objects/passkey_slot.dart';
import 'package:sharedinbox/core/encrypted_objects/recovery_key.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:sharedinbox/core/services/share_encryption_service.dart';
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

  test('pairingV2', () async {
    final v = vectors['pairingV2'] as Map<String, dynamic>;
    final x25519 = X25519();
    Future<SimpleKeyPair> pairOf(String hex) =>
        x25519.newKeyPairFromSeed(hexBytes(hex));
    final recipient = await pairOf(v['recipientPriv'] as String);
    final eph = await pairOf(v['ephPriv'] as String);
    final recipientPub = (await recipient.extractPublicKey()).bytes;
    final ephPub = (await eph.extractPublicKey()).bytes;
    expect(toHex(recipientPub), v['recipientPub']);
    expect(toHex(ephPub), v['ephPub']);
    final shared = await (await x25519.sharedSecretKey(
      keyPair: eph,
      remotePublicKey: SimplePublicKey(recipientPub, type: KeyPairType.x25519),
    ))
        .extractBytes();
    expect(toHex(shared), v['sharedSecret']);

    final secret = pairingSecret(hexBytes(v['recipientPriv'] as String));
    expect(toHex(secret), v['secret']);
    final keyId = hexBytes(v['keyId'] as String);
    final aesKey = await ShareEncryptionService.deriveAesKey(
      sharedSecret: shared,
      keyId: keyId,
      info: HkdfInfo.pairingV2,
      bindSecret: secret,
      ephPub: ephPub,
      recipientPub: recipientPub,
    );
    expect(toHex(aesKey), v['aesKey']);
    expect(
      pairingFingerprint(
        PairingRequest(
          keyId: keyId,
          publicKey: Uint8List.fromList(recipientPub),
          secret: secret,
          server: 's',
          username: 'u',
        ),
      ),
      v['fingerprint'],
    );

    // The weak point: an all-zero shared secret is refused.
    expect(v['weakSharedSecret'], '00' * 32);
    await expectLater(
      ShareEncryptionService.deriveAesKey(
        sharedSecret: hexBytes(v['weakSharedSecret'] as String),
        keyId: keyId,
        info: HkdfInfo.pairingV2,
        bindSecret: secret,
        ephPub: hexBytes(v['weakEphPub'] as String),
        recipientPub: recipientPub,
      ),
      throwsFormatException,
    );
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

  test('passkeySlot', () async {
    final v = vectors['passkeySlot'] as Map<String, dynamic>;
    final accountKey = AccountKey(
      hexBytes(v['accountKeyId'] as String),
      hexBytes(v['accountKey'] as String),
    );
    final prfOutput = hexBytes(v['prfOutput'] as String);
    expect(toHex((await passkeyKek(prfOutput)).bytes), v['kek']);
    final slot = await wrapPasskeySlot(
      accountKey,
      prfOutput,
      credentialId: hexBytes(v['credentialId'] as String),
      salt: hexBytes(v['prfSalt'] as String),
      label: 'Google Password Manager',
      random: queuedRandom([
        hexBytes(v['slotId'] as String),
        hexBytes(v['nonce'] as String),
      ]),
    );
    expect(
      toHex(
        slotAad(
          accountKeyId: accountKey.accountKeyId,
          slotId: slot.slotId,
          type: slot.type,
        ),
      ),
      v['aad'],
    );
    expect(toHex(slot.wrapped), v['wrapped']);
    expect(jsonEncode(slot.toJson()), v['slot']);
    final parsed = UnlockSlot.fromJson(
      jsonDecode(v['slot'] as String) as Map<String, Object?>,
    );
    final back = await unwrapPasskeySlot(
      parsed,
      prfOutput,
      accountKey.accountKeyId,
    );
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

  CollectionKey collectionKeyOf(Map<String, dynamic> v) => CollectionKey(
        'deck-1',
        hexBytes(v['keyId'] as String? ?? '00' * 16),
        hexBytes(v['collectionKey'] as String),
      );

  test('itemHmac', () async {
    final v = vectors['itemHmac'] as Map<String, dynamic>;
    final key = collectionKeyOf(v);
    expect(toHex((await key.kItem()).bytes), v['kItem']);
    expect(
      toHex(await itemHmac(key, v['itemId'] as String)),
      v['itemHmac'],
    );
  });

  test('padding', () {
    for (final c in (vectors['padding'] as List).cast<Map<String, dynamic>>()) {
      expect(paddedLength(c['p'] as int), c['padded'], reason: '${c['p']}');
    }
  });

  test('envelope', () async {
    final v = vectors['envelope'] as Map<String, dynamic>;
    final key = collectionKeyOf(v);
    final hmac = hexBytes(v['itemHmac'] as String);
    expect(toHex(await itemHmac(key, v['itemId'] as String)), v['itemHmac']);
    expect(toHex((await key.kObj()).bytes), v['kObj']);
    expect(toHex(envelopeAad(key.keyId, hmac)), v['aad']);
    final blob = await sealEnvelope(
      key: key,
      itemHmac: hmac,
      innerMime: hexBytes(v['innerMime'] as String),
      random: queuedRandom([hexBytes(v['nonce'] as String)]),
    );
    expect(toHex(blob), v['blob']);
    final opened = await openEnvelope(
      blob: hexBytes(v['blob'] as String),
      itemHmacFromHeader: hmac,
      keyLookup: (_) => key,
    );
    expect(toHex(opened.innerMime), v['innerMime']);
  });

  test('hlc', () {
    for (final c in (vectors['hlc'] as List).cast<Map<String, dynamic>>()) {
      final hlc = Hlc(
        c['wallMs'] as int,
        c['counter'] as int,
        c['deviceId'] as String,
      );
      expect(hlc.encode(), c['encoded']);
      expect(Hlc.parse(c['encoded'] as String), hlc);
    }
  });

  test('messageId', () {
    final v = vectors['messageId'] as Map<String, dynamic>;
    expect(
      newMessageId(random: queuedRandom([hexBytes(v['random'] as String)])),
      v['messageId'],
    );
  });

  test('logSegment', () {
    final v = vectors['logSegment'] as Map<String, dynamic>;
    final events = decodeEventsBody(hexBytes(v['gzip'] as String));
    expect([for (final e in events) e.seq], [1, 2, 3]);
    expect(events.every((e) => e.deviceId == v['deviceId']), isTrue);
    expect(utf8.decode(encodeEventLines(events)), v['jsonl']);
    expect(decodeEventsBody(encodeEventsBody(events)).length, 3);
    final head = SegmentHead.of(
      v['deviceId'] as String,
      events,
      period: periodOf(events.first.hlc),
    );
    expect(jsonEncode(head.toExtra()), jsonEncode(v['head']));
    expect(
      jsonEncode(
        SegmentHead.fromExtra(v['head'] as Map<String, Object?>).toExtra(),
      ),
      jsonEncode(v['head']),
    );
  });

  test('cardBatch', () {
    final v = vectors['cardBatch'] as Map<String, dynamic>;
    final batch = InnerObject(
      head: ObjectHead(
        itemId: 'batch-1',
        collectionId: 'deck-1',
        versionId: Hlc.parse('1700000000002-0000-${v['deviceId'] as String}'),
        kind: cardBatchKind,
        extra: v['head'] as Map<String, Object?>,
      ),
      parts: [
        ObjectPart(
          contentType: cardBatchContentType,
          bytes: hexBytes(v['gzip'] as String),
        ),
      ],
    );
    final members = readBatchMembers(batch);
    expect([for (final m in members) m.cardId], ['card-1', 'card-2', 'card-3']);
    expect(members.every((m) => m.h.deviceId == v['deviceId']), isTrue);
    expect(members.last.extra, {'ease': 2.5});
    expect(members.last.content.tags, ['de', 'animal']);
    expect(
      utf8.decode([
        for (final m in members) ...encodeJsonLine(m.toJson()),
      ]),
      v['jsonl'],
    );
    expect(mergeBatchMembers([batch]), hasLength(3));
  });
}
