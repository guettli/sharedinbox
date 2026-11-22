import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  final accountKey = AccountKey(seqBytes(0xa0, 16), seqBytes(0x00, 32));
  final deckKey =
      CollectionKey('deck-1', seqBytes(0xb0, 16), seqBytes(0x20, 32));

  group('deriveSubKey', () {
    test('the 8 sub-keys are pairwise distinct and differ from the root',
        () async {
      final keys = <String>{toHex(accountKey.key.bytes)};
      for (final info in HkdfInfo.all) {
        final sub = await deriveSubKey(accountKey.key, info);
        expect(sub.bytes, hasLength(32));
        keys.add(toHex(sub.bytes));
      }
      expect(keys, hasLength(HkdfInfo.all.length + 1));
    });

    test('is deterministic', () async {
      final a = await deriveSubKey(accountKey.key, HkdfInfo.obj);
      final b = await deriveSubKey(
        SecretKeyData(seqBytes(0x00, 32)),
        HkdfInfo.obj,
      );
      expect(a.bytes, b.bytes);
    });

    test('helpers use their info strings', () async {
      expect(
        (await accountKey.kSlots()).bytes,
        (await deriveSubKey(accountKey.key, HkdfInfo.slotsMac)).bytes,
      );
      expect(
        (await accountKey.kWrap()).bytes,
        (await deriveSubKey(accountKey.key, HkdfInfo.collectionWrap)).bytes,
      );
      expect(
        (await deckKey.kObj()).bytes,
        (await deriveSubKey(deckKey.key, HkdfInfo.obj)).bytes,
      );
      expect(
        (await deckKey.kItem()).bytes,
        (await deriveSubKey(deckKey.key, HkdfInfo.itemIdHmac)).bytes,
      );
    });
  });

  group('generate', () {
    test('uses fresh random ids and keys', () {
      final a = AccountKey.generate();
      final b = AccountKey.generate();
      expect(a.accountKeyId, hasLength(16));
      expect(a.key.bytes, hasLength(32));
      expect(a.accountKeyId, isNot(b.accountKeyId));
      final c = CollectionKey.generate(personalCollectionId);
      expect(c.collectionId, 'personal');
      expect(c.keyId, hasLength(16));
    });

    test('rejects wrong lengths', () {
      expect(
        () => AccountKey(seqBytes(0, 15), seqBytes(0, 32)),
        throwsArgumentError,
      );
      expect(
        () => AccountKey(seqBytes(0, 16), seqBytes(0, 31)),
        throwsArgumentError,
      );
    });
  });

  group('collection-key wrap', () {
    late CollectionKeyWrap wrap;
    setUp(() async {
      wrap = await wrapCollectionKey(accountKey, deckKey);
    });

    Future<CollectionKey> unwrap({
      AccountKey? key,
      String collectionId = 'deck-1',
      Uint8List? keyId,
      CollectionKeyWrap? w,
    }) =>
        unwrapCollectionKey(
          key ?? accountKey,
          collectionId: collectionId,
          keyId: keyId ?? deckKey.keyId,
          wrap: w ?? wrap,
        );

    test('round-trips', () async {
      expect(wrap.type, 'account');
      expect(wrap.nonce, hasLength(24));
      expect(wrap.wrapped, hasLength(32 + 16));
      final back = await unwrap();
      expect(back.key.bytes, deckKey.key.bytes);
      expect(back.collectionId, 'deck-1');
      expect(back.keyId, deckKey.keyId);
    });

    test('uses a fresh nonce per wrap', () async {
      final again = await wrapCollectionKey(accountKey, deckKey);
      expect(again.nonce, isNot(wrap.nonce));
    });

    test('JSON round-trips', () async {
      final back = CollectionKeyWrap.fromJson(wrap.toJson());
      expect((await unwrap(w: back)).key.bytes, deckKey.key.bytes);
      expect(
        () => CollectionKeyWrap.fromJson({...wrap.toJson(), 'type': 'x25519'}),
        throwsFormatException,
      );
    });

    test('relabelling the collectionId as personal fails', () {
      expect(
        unwrap(collectionId: personalCollectionId),
        throwsA(isA<KeyUnwrapException>()),
      );
    });

    test('a different keyId fails', () {
      expect(
        unwrap(keyId: seqBytes(0xb1, 16)),
        throwsA(isA<KeyUnwrapException>()),
      );
    });

    test('a different accountKeyId fails', () {
      final relabelled = AccountKey(seqBytes(0xa1, 16), seqBytes(0x00, 32));
      expect(unwrap(key: relabelled), throwsA(isA<KeyUnwrapException>()));
    });

    test('a different wrapType in the AAD fails', () async {
      final aad = collectionWrapAad(
        accountKeyId: accountKey.accountKeyId,
        collectionId: 'deck-1',
        keyId: deckKey.keyId,
        wrapType: 'x25519',
      );
      expect(
        aeadOpen(
          key: await accountKey.kWrap(),
          nonce: wrap.nonce,
          sealed: wrap.wrapped,
          aad: aad,
        ),
        throwsA(isA<KeyUnwrapException>()),
      );
    });

    test('a wrong account key fails', () {
      final other = AccountKey(accountKey.accountKeyId, seqBytes(0x01, 32));
      expect(unwrap(key: other), throwsA(isA<KeyUnwrapException>()));
    });

    test('a tampered ciphertext fails', () {
      final bytes = Uint8List.fromList(wrap.wrapped)..[0] ^= 1;
      expect(
        unwrap(w: CollectionKeyWrap(nonce: wrap.nonce, wrapped: bytes)),
        throwsA(isA<KeyUnwrapException>()),
      );
    });

    test('a malformed wrap fails', () {
      expect(
        unwrap(w: CollectionKeyWrap(nonce: wrap.nonce, wrapped: Uint8List(3))),
        throwsA(isA<KeyUnwrapException>()),
      );
    });
  });

  group('wire helpers', () {
    test('buildAad writes ids raw and strings length-prefixed', () {
      final aad = buildAad([
        Uint8List.fromList([1, 2]),
        'ab',
      ]);
      expect(aad, [1, 2, 0, 2, 0x61, 0x62]);
      expect(() => buildAad([42]), throwsArgumentError);
      expect(() => buildAad(['x' * 0x10000]), throwsArgumentError);
    });

    test('b64url has no padding and decodes either form', () {
      expect(b64url([0xff]), '_w');
      expect(b64urlDecode('_w'), [0xff]);
      expect(b64urlDecode('_w=='), [0xff]);
    });

    test('canonicalJson sorts keys recursively', () {
      expect(
        canonicalJson({
          'b': 1,
          'a': [
            {'d': 1, 'c': 2},
          ],
        }),
        '{"a":[{"c":2,"d":1}],"b":1}',
      );
    });

    test('readBytesField rejects bad values', () {
      expect(() => readBytesField({}, 'x', null), throwsFormatException);
      expect(
        () => readBytesField({'x': '%%'}, 'x', null),
        throwsFormatException,
      );
      expect(() => readBytesField({'x': 'AA'}, 'x', 2), throwsFormatException);
      expect(() => readStringField({'x': 1}, 'x'), throwsFormatException);
    });

    test('decodeJsonObject rejects non-objects', () {
      expect(
        () => decodeJsonObject(Uint8List.fromList([0xff])),
        throwsFormatException,
      );
      expect(
        () => decodeJsonObject(Uint8List.fromList('[1]'.codeUnits)),
        throwsFormatException,
      );
    });

    test('secureRandomBytes and counterRandom differ per draw', () {
      expect(secureRandomBytes(8), hasLength(8));
      final r = counterRandom();
      expect(r(2), isNot(r(2)));
    });

    test('KeyUnwrapException describes itself', () {
      expect(const KeyUnwrapException('x').toString(), contains('x'));
    });
  });
}
