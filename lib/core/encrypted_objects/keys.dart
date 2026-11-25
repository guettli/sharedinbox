import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:sharedinbox/core/encrypted_objects/wire.dart';

/// Key hierarchy of the encrypted-objects format (`ENCRYPTED-OBJECTS.md` 4.1).

/// The default collection every account has.
const personalCollectionId = 'personal';

/// HKDF info strings (4.1), verbatim. Never use a root key directly.
abstract final class HkdfInfo {
  static const obj = 'sharedinbox-obj-v1';
  static const itemIdHmac = 'sharedinbox-itemid-hmac-v1';
  static const slotsMac = 'sharedinbox-slots-mac-v1';
  static const collectionWrap = 'sharedinbox-collection-wrap-v1';
  static const kekRecovery = 'sharedinbox-kek-recovery-v1';
  static const kekPassphrase = 'sharedinbox-kek-passphrase-v1';
  static const kekPasskey = 'sharedinbox-kek-passkey-v1';

  /// Pairing v1: superseded by [pairingV2]; kept for its frozen vector.
  static const pairing = 'sharedinbox-pairing-v1';

  /// Pairing v2 (4.6): followed by `ephPub ‖ recipientPub`, with the request
  /// secret mixed into the key material. Not a root-key sub key, so not in
  /// [all].
  static const pairingV2 = 'sharedinbox-pairing-v2';

  static const all = [
    obj,
    itemIdHmac,
    slotsMac,
    collectionWrap,
    kekRecovery,
    kekPassphrase,
    kekPasskey,
    pairing,
  ];
}

final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: keyLength);

/// HKDF-SHA256 with an empty salt and a 32-byte output.
Future<SecretKeyData> deriveSubKey(SecretKey root, String info) async {
  // The default nonce (HKDF salt) is empty.
  final derived = await _hkdf.deriveKey(
    secretKey: root,
    info: utf8.encode(info),
  );
  return SecretKeyData(await derived.extractBytes());
}

SecretKeyData _keyFromBytes(List<int> bytes) {
  if (bytes.length != keyLength) {
    throw ArgumentError.value(bytes.length, 'key', 'must be $keyLength bytes');
  }
  return SecretKeyData(List<int>.unmodifiable(bytes));
}

void _checkId(Uint8List id, String name) {
  if (id.length != idLength) {
    throw ArgumentError.value(id.length, name, 'must be $idLength bytes');
  }
}

/// Per mail account: random 256-bit key plus a 16-byte random id.
class AccountKey {
  AccountKey(this.accountKeyId, List<int> keyBytes)
      : key = _keyFromBytes(keyBytes) {
    _checkId(accountKeyId, 'accountKeyId');
  }

  factory AccountKey.generate({RandomBytes random = secureRandomBytes}) =>
      AccountKey(random(idLength), random(keyLength));

  final Uint8List accountKeyId;
  final SecretKeyData key;

  /// MAC key over the key-mail slot list.
  Future<SecretKeyData> kSlots() => deriveSubKey(key, HkdfInfo.slotsMac);

  /// Wrap key for collection keys.
  Future<SecretKeyData> kWrap() => deriveSubKey(key, HkdfInfo.collectionWrap);
}

/// Per collection: random 256-bit key plus a 16-byte random [keyId].
class CollectionKey {
  CollectionKey(this.collectionId, this.keyId, List<int> keyBytes)
      : key = _keyFromBytes(keyBytes) {
    _checkId(keyId, 'keyId');
  }

  factory CollectionKey.generate(
    String collectionId, {
    RandomBytes random = secureRandomBytes,
  }) =>
      CollectionKey(collectionId, random(idLength), random(keyLength));

  final String collectionId;
  final Uint8List keyId;
  final SecretKeyData key;

  /// Object AEAD key.
  Future<SecretKeyData> kObj() => deriveSubKey(key, HkdfInfo.obj);

  /// Item-id HMAC key.
  Future<SecretKeyData> kItem() => deriveSubKey(key, HkdfInfo.itemIdHmac);
}

/// Wrap type of a collection key wrapped under the account's `k_wrap`.
const accountWrapType = 'account';

final _sick1 = Uint8List.fromList(ascii.encode('SICK1'));

/// AAD of a collection-key wrap:
/// `"SICK1" ‖ accountKeyId ‖ enc(collectionId) ‖ keyId ‖ enc(wrapType)`.
Uint8List collectionWrapAad({
  required Uint8List accountKeyId,
  required String collectionId,
  required Uint8List keyId,
  required String wrapType,
}) =>
    buildAad([_sick1, accountKeyId, collectionId, keyId, wrapType]);

/// A collection key wrapped under `k_wrap` (`{type: account, nonce, wrapped}`).
class CollectionKeyWrap {
  const CollectionKeyWrap({required this.nonce, required this.wrapped});

  factory CollectionKeyWrap.fromJson(Map<String, Object?> json) {
    if (json['type'] != accountWrapType) {
      throw const FormatException('not an account wrap');
    }
    return CollectionKeyWrap(
      nonce: readBytesField(json, 'nonce', nonceLength),
      wrapped: readBytesField(json, 'wrapped', null),
    );
  }

  final Uint8List nonce;

  /// `ciphertext ‖ tag(16)`.
  final Uint8List wrapped;

  String get type => accountWrapType;

  Map<String, Object?> toJson() => {
        'type': type,
        'nonce': b64url(nonce),
        'wrapped': b64url(wrapped),
      };
}

/// Wraps [collectionKey] under the `k_wrap` of [accountKey] with a fresh nonce.
Future<CollectionKeyWrap> wrapCollectionKey(
  AccountKey accountKey,
  CollectionKey collectionKey, {
  RandomBytes random = secureRandomBytes,
}) async {
  final nonce = random(nonceLength);
  final wrapped = await aeadSeal(
    key: await accountKey.kWrap(),
    nonce: nonce,
    plaintext: collectionKey.key.bytes,
    aad: collectionWrapAad(
      accountKeyId: accountKey.accountKeyId,
      collectionId: collectionKey.collectionId,
      keyId: collectionKey.keyId,
      wrapType: accountWrapType,
    ),
  );
  return CollectionKeyWrap(nonce: nonce, wrapped: wrapped);
}

/// Unwraps a collection key. Throws [KeyUnwrapException] for a wrong account
/// key or a relabelled `collectionId` / `keyId` / `accountKeyId`.
Future<CollectionKey> unwrapCollectionKey(
  AccountKey accountKey, {
  required String collectionId,
  required Uint8List keyId,
  required CollectionKeyWrap wrap,
}) async {
  final clear = await aeadOpen(
    key: await accountKey.kWrap(),
    nonce: wrap.nonce,
    sealed: wrap.wrapped,
    aad: collectionWrapAad(
      accountKeyId: accountKey.accountKeyId,
      collectionId: collectionId,
      keyId: keyId,
      wrapType: wrap.type,
    ),
  );
  if (clear.length != keyLength) {
    throw const KeyUnwrapException('unwrapped key has wrong length');
  }
  return CollectionKey(collectionId, keyId, clear);
}
