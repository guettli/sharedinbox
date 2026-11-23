import 'dart:convert';
import 'dart:typed_data';

import 'package:sharedinbox/core/encrypted_objects/envelope.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  final key = testDeckKey;
  final otherKey =
      CollectionKey('deck-1', seqBytes(0xb1, 16), seqBytes(0x21, 32));
  CollectionKey? lookup(Uint8List keyId) =>
      constantTimeEquals(keyId, key.keyId) ? key : null;

  Matcher fails(EnvelopeFailure reason) => throwsA(
        isA<EnvelopeException>().having((e) => e.reason, 'reason', reason),
      );

  Future<({Uint8List itemHmac, Uint8List blob})> seal(InnerObject object) =>
      sealObject(key: key, object: object, random: counterRandom());

  test('newItemId is base64url of 16 bytes', () {
    final id = newItemId(random: counterRandom(7));
    expect(id, hasLength(22));
    expect(id, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
    expect(newItemId(), isNot(newItemId()));
  });

  test('paddedLength rejects a negative length', () {
    expect(() => paddedLength(-1), throwsArgumentError);
  });

  test('seal and open round-trip, blob padded to a bucket', () async {
    final sealed = await seal(testObject());
    expect(sealed.itemHmac, await itemHmac(key, 'item-1'));
    expect(sealed.blob.length, 4 + 16 + 24 + 1024 + 16);
    expect(ascii.decode(sealed.blob.sublist(0, 4)), 'SIE1');
    final opened = await openObject(
      blob: sealed.blob,
      itemHmacFromHeader: sealed.itemHmac,
      keyLookup: lookup,
    );
    expect(opened.key, same(key));
    expect(opened.object.head.itemId, 'item-1');
    expect(utf8.decode(opened.object.parts.single.bytes), '# Hello');
  });

  test('a swapped X-SharedInbox-Item is rejected', () async {
    final a = await seal(testObject());
    final b = await seal(testObject(itemId: 'item-2'));
    expect(
      openObject(
        blob: a.blob,
        itemHmacFromHeader: b.itemHmac,
        keyLookup: lookup,
      ),
      fails(EnvelopeFailure.authFailed),
    );
  });

  test('an unknown keyId is rejected', () async {
    final a = await seal(testObject());
    expect(
      openObject(
        blob: a.blob,
        itemHmacFromHeader: a.itemHmac,
        keyLookup: (_) => null,
      ),
      fails(EnvelopeFailure.unknownKey),
    );
  });

  test('a swapped keyId is rejected', () async {
    final a = await seal(testObject());
    final swapped = Uint8List.fromList(a.blob)..setRange(4, 20, otherKey.keyId);
    expect(
      openObject(
        blob: swapped,
        itemHmacFromHeader: a.itemHmac,
        keyLookup: (id) =>
            constantTimeEquals(id, otherKey.keyId) ? otherKey : null,
      ),
      fails(EnvelopeFailure.authFailed),
    );
  });

  test('a flipped ciphertext byte is rejected', () async {
    final a = await seal(testObject());
    final tampered = Uint8List.fromList(a.blob);
    tampered[100] ^= 1;
    expect(
      openObject(
        blob: tampered,
        itemHmacFromHeader: a.itemHmac,
        keyLookup: lookup,
      ),
      fails(EnvelopeFailure.authFailed),
    );
  });

  test('a flipped magic or a short blob is rejected', () async {
    final a = await seal(testObject());
    final tampered = Uint8List.fromList(a.blob);
    tampered[0] ^= 1;
    expect(
      openObject(
        blob: tampered,
        itemHmacFromHeader: a.itemHmac,
        keyLookup: lookup,
      ),
      fails(EnvelopeFailure.badMagic),
    );
    expect(
      openObject(
        blob: a.blob.sublist(0, 40),
        itemHmacFromHeader: a.itemHmac,
        keyLookup: lookup,
      ),
      fails(EnvelopeFailure.badMagic),
    );
  });

  test('an itemId that does not match the item header is rejected', () async {
    final mime = buildInnerMime(testObject(), random: counterRandom());
    final hmacB = await itemHmac(key, 'item-2');
    final blob = await sealEnvelope(
      key: key,
      itemHmac: hmacB,
      innerMime: mime,
      random: counterRandom(),
    );
    expect(
      openObject(blob: blob, itemHmacFromHeader: hmacB, keyLookup: lookup),
      fails(EnvelopeFailure.itemMismatch),
    );
  });

  test('a head collectionId other than the key collection is rejected',
      () async {
    final object = testObject(collectionId: 'personal');
    expect(seal(object), fails(EnvelopeFailure.collectionMismatch));
    final hmac = await itemHmac(key, 'item-1');
    final blob = await sealEnvelope(
      key: key,
      itemHmac: hmac,
      innerMime: buildInnerMime(object, random: counterRandom()),
      random: counterRandom(),
    );
    expect(
      openObject(blob: blob, itemHmacFromHeader: hmac, keyLookup: lookup),
      fails(EnvelopeFailure.collectionMismatch),
    );
  });

  test('a length field above the plaintext is rejected', () async {
    final hmac = await itemHmac(key, 'item-1');
    final nonce = seqBytes(0x90, 24);
    final plaintext = Uint8List(1024)..buffer.asByteData().setUint32(0, 1021);
    final sealed = await aeadSeal(
      key: await key.kObj(),
      nonce: nonce,
      plaintext: plaintext,
      aad: envelopeAad(key.keyId, hmac),
    );
    final blob = Uint8List.fromList(
      [...envelopeMagic, ...key.keyId, ...nonce, ...sealed],
    );
    expect(
      openEnvelope(blob: blob, itemHmacFromHeader: hmac, keyLookup: lookup),
      fails(EnvelopeFailure.badLength),
    );
  });

  test('the size limit is enforced on seal and open', () async {
    final hmac = await itemHmac(key, 'item-1');
    expect(
      sealEnvelope(
        key: key,
        itemHmac: hmac,
        innerMime: Uint8List(8 * 1024 * 1024),
        random: counterRandom(),
      ),
      throwsA(isA<ObjectTooLargeException>()),
    );
    final blob = await sealEnvelope(
      key: key,
      itemHmac: hmac,
      innerMime: Uint8List(2000),
      random: counterRandom(),
    );
    expect(
      sealEnvelope(
        key: key,
        itemHmac: hmac,
        innerMime: Uint8List(2000),
        random: counterRandom(),
        maxBytes: 2048,
      ),
      fails(EnvelopeFailure.tooLarge),
    );
    expect(
      openEnvelope(
        blob: blob,
        itemHmacFromHeader: hmac,
        keyLookup: lookup,
        maxBytes: 2048,
      ),
      fails(EnvelopeFailure.tooLarge),
    );
  });

  test('sealEnvelope rejects an item HMAC of the wrong length', () {
    expect(
      sealEnvelope(key: key, itemHmac: Uint8List(31), innerMime: Uint8List(1)),
      throwsArgumentError,
    );
  });

  test('exception toString names the reason', () {
    expect(
      const EnvelopeException(EnvelopeFailure.badLength, 'x').toString(),
      'EnvelopeException(badLength): x',
    );
  });
}
