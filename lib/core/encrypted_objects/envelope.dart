import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';

/// Object envelope: the bytes of the `application/octet-stream` part of an
/// object mail (`ENCRYPTED-OBJECTS.md` 5.1, 5.6).
///
/// ```text
/// "SIE1" ‖ keyId (16) ‖ nonce (24) ‖ AEAD_k_obj(u32be len ‖ innerMIME ‖ zeros)
/// AAD = "SIE1" ‖ keyId ‖ itemHmac (32)
/// ```

final envelopeMagic = Uint8List.fromList(ascii.encode('SIE1'));

/// Upper bound of a whole envelope blob (5.1): 8 MiB.
const maxEnvelopeBytes = 8 * 1024 * 1024;

/// Length of an item HMAC.
const itemHmacLength = 32;

const _tagLength = 16;
const _headerLength = 4 + idLength + nonceLength;

/// Smallest padded plaintext bucket.
const _minBucket = 1024;
const _bucketStep = 64 * 1024;

enum EnvelopeFailure {
  badMagic,
  tooLarge,
  unknownKey,
  authFailed,
  badLength,
  itemMismatch,
  collectionMismatch,
}

/// Thrown when an envelope cannot be sealed or opened.
class EnvelopeException implements Exception {
  const EnvelopeException(this.reason, this.message);

  final EnvelopeFailure reason;
  final String message;

  @override
  String toString() => 'EnvelopeException(${reason.name}): $message';
}

/// Thrown when an object does not fit into [maxEnvelopeBytes] (or a smaller
/// provider limit such as JMAP `maxSizeUpload`); shown to the user.
class ObjectTooLargeException extends EnvelopeException {
  const ObjectTooLargeException(this.size, this.limit)
      : super(EnvelopeFailure.tooLarge, 'object of $size bytes > $limit');

  final int size;
  final int limit;
}

/// A new random itemId: base64url (no padding) of 16 random bytes.
String newItemId({RandomBytes random = secureRandomBytes}) =>
    b64url(random(idLength));

/// `HMAC-SHA256(k_item, utf8(itemId))` — the `X-SharedInbox-Item` value.
Future<Uint8List> itemHmac(CollectionKey key, String itemId) async {
  final mac = await Hmac.sha256().calculateMac(
    utf8.encode(itemId),
    secretKey: await key.kItem(),
  );
  return Uint8List.fromList(mac.bytes);
}

/// Padded plaintext length for `P = 4 + len(innerMIME)`:
/// `max(1024, nextPow2(P))` if `P ≤ 64 KiB`, else `ceil(P / 64 KiB) · 64 KiB`.
int paddedLength(int p) {
  if (p < 0) throw ArgumentError.value(p, 'p', 'must not be negative');
  if (p > _bucketStep) {
    return (p + _bucketStep - 1) ~/ _bucketStep * _bucketStep;
  }
  var bucket = _minBucket;
  while (bucket < p) {
    bucket *= 2;
  }
  return bucket;
}

/// AAD of an envelope: `"SIE1" ‖ keyId ‖ itemHmac`.
Uint8List envelopeAad(Uint8List keyId, Uint8List itemHmac) =>
    buildAad([envelopeMagic, keyId, itemHmac]);

/// Encrypts [innerMime] for the item whose HMAC is [itemHmac].
///
/// Throws [ObjectTooLargeException] if the blob would exceed [maxBytes].
Future<Uint8List> sealEnvelope({
  required CollectionKey key,
  required Uint8List itemHmac,
  required Uint8List innerMime,
  RandomBytes random = secureRandomBytes,
  int maxBytes = maxEnvelopeBytes,
}) async {
  if (itemHmac.length != itemHmacLength) {
    throw ArgumentError.value(itemHmac.length, 'itemHmac', 'must be 32 bytes');
  }
  final padded = paddedLength(4 + innerMime.length);
  final size = _headerLength + padded + _tagLength;
  final limit = maxBytes < maxEnvelopeBytes ? maxBytes : maxEnvelopeBytes;
  if (size > limit) throw ObjectTooLargeException(size, limit);
  final plaintext = Uint8List(padded)
    ..buffer.asByteData().setUint32(0, innerMime.length)
    ..setRange(4, 4 + innerMime.length, innerMime);
  final nonce = random(nonceLength);
  final sealed = await aeadSeal(
    key: await key.kObj(),
    nonce: nonce,
    plaintext: plaintext,
    aad: envelopeAad(key.keyId, itemHmac),
  );
  return (BytesBuilder(copy: false)
        ..add(envelopeMagic)
        ..add(key.keyId)
        ..add(nonce)
        ..add(sealed))
      .toBytes();
}

/// Decrypts an envelope [blob]. The AAD is built from the parsed `keyId` and
/// [itemHmacFromHeader] (the decoded `X-SharedInbox-Item`), never from raw
/// header bytes. [keyLookup] returns the collection key of a `keyId`, or null.
///
/// Throws [EnvelopeException]. Padding is not checked: the AEAD covers it.
Future<({CollectionKey key, Uint8List innerMime})> openEnvelope({
  required Uint8List blob,
  required Uint8List itemHmacFromHeader,
  required CollectionKey? Function(Uint8List keyId) keyLookup,
  int maxBytes = maxEnvelopeBytes,
}) async {
  if (blob.length < _headerLength + _tagLength + 4 ||
      !constantTimeEquals(blob.sublist(0, 4), envelopeMagic)) {
    throw const EnvelopeException(EnvelopeFailure.badMagic, 'not SIE1');
  }
  final limit = maxBytes < maxEnvelopeBytes ? maxBytes : maxEnvelopeBytes;
  if (blob.length > limit) throw ObjectTooLargeException(blob.length, limit);
  final keyId = blob.sublist(4, 4 + idLength);
  final key = keyLookup(keyId);
  if (key == null) {
    throw const EnvelopeException(EnvelopeFailure.unknownKey, 'unknown keyId');
  }
  final Uint8List plaintext;
  try {
    plaintext = await aeadOpen(
      key: await key.kObj(),
      nonce: blob.sublist(4 + idLength, _headerLength),
      sealed: blob.sublist(_headerLength),
      aad: envelopeAad(keyId, itemHmacFromHeader),
    );
  } on KeyUnwrapException {
    throw const EnvelopeException(
      EnvelopeFailure.authFailed,
      'envelope does not authenticate',
    );
  }
  final len = plaintext.buffer.asByteData().getUint32(0);
  if (len > plaintext.length - 4) {
    throw const EnvelopeException(EnvelopeFailure.badLength, 'bad length');
  }
  return (key: key, innerMime: plaintext.sublist(4, 4 + len));
}
