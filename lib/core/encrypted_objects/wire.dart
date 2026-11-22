import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Shared wire helpers for the encrypted-objects format
/// (`ENCRYPTED-OBJECTS.md` 4.6). Pure Dart, no Flutter imports.

/// Length of every random id (`accountKeyId`, `keyId`, `slotId`).
const idLength = 16;

/// Length of every symmetric key.
const keyLength = 32;

/// XChaCha20-Poly1305 nonce length.
const nonceLength = 24;

/// Source of random bytes. Injectable so tests and vectors are deterministic.
typedef RandomBytes = Uint8List Function(int length);

final _rng = Random.secure();

/// Default [RandomBytes]: `Random.secure()`.
Uint8List secureRandomBytes(int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = _rng.nextInt(256);
  }
  return out;
}

/// base64url without padding — the encoding of every binary JSON value.
String b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

/// Decodes base64url with or without padding.
Uint8List b64urlDecode(String s) => base64Url.decode(base64Url.normalize(s));

/// Builds an AAD: `Uint8List` parts are written raw, `String` parts as
/// `u16be(len) ‖ utf8`.
Uint8List buildAad(List<Object> parts) {
  final out = BytesBuilder(copy: false);
  for (final part in parts) {
    if (part is Uint8List) {
      out.add(part);
      continue;
    }
    if (part is String) {
      final utf = utf8.encode(part);
      if (utf.length > 0xffff) {
        throw ArgumentError.value(part, 'parts', 'string field too long');
      }
      out
        ..addByte(utf.length >> 8)
        ..addByte(utf.length & 0xff)
        ..add(utf);
      continue;
    }
    throw ArgumentError.value(part, 'parts', 'must be Uint8List or String');
  }
  return out.toBytes();
}

/// Thrown when an AEAD-wrapped key does not authenticate: wrong key, or a
/// tampered or relabelled wrap.
class KeyUnwrapException implements Exception {
  const KeyUnwrapException(this.message);

  final String message;

  @override
  String toString() => 'KeyUnwrapException: $message';
}

final _aead = Xchacha20.poly1305Aead();

/// XChaCha20-Poly1305 seal. Returns `ciphertext ‖ tag(16)`.
Future<Uint8List> aeadSeal({
  required SecretKey key,
  required Uint8List nonce,
  required List<int> plaintext,
  required Uint8List aad,
}) async {
  final box = await _aead.encrypt(
    plaintext,
    secretKey: key,
    nonce: nonce,
    aad: aad,
  );
  return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
}

/// XChaCha20-Poly1305 open of `ciphertext ‖ tag(16)`.
///
/// Throws [KeyUnwrapException] if authentication fails.
Future<Uint8List> aeadOpen({
  required SecretKey key,
  required Uint8List nonce,
  required Uint8List sealed,
  required Uint8List aad,
}) async {
  if (nonce.length != nonceLength || sealed.length < 16) {
    throw const KeyUnwrapException('malformed nonce or ciphertext');
  }
  final box = SecretBox(
    sealed.sublist(0, sealed.length - 16),
    nonce: nonce,
    mac: Mac(sealed.sublist(sealed.length - 16)),
  );
  try {
    final clear = await _aead.decrypt(box, secretKey: key, aad: aad);
    return Uint8List.fromList(clear);
  } on SecretBoxAuthenticationError {
    throw const KeyUnwrapException('authentication failed');
  }
}

/// JSON with recursively sorted object keys — used only to order values
/// deterministically (merge tie-breaks), never as MAC input.
String canonicalJson(Object? value) => jsonEncode(_sortKeys(value));

Object? _sortKeys(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k as String).toList()..sort();
    return {for (final k in keys) k: _sortKeys(value[k])};
  }
  if (value is List) return value.map(_sortKeys).toList();
  return value;
}

/// Constant-time comparison of two byte lists.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Reads a required base64url field of a fixed [length] from [json].
Uint8List readBytesField(Map<String, Object?> json, String name, int? length) {
  final value = json[name];
  if (value is! String) {
    throw FormatException('missing or non-string field "$name"');
  }
  final Uint8List bytes;
  try {
    bytes = b64urlDecode(value);
  } on FormatException {
    throw FormatException('field "$name" is not base64url');
  }
  if (length != null && bytes.length != length) {
    throw FormatException('field "$name" must be $length bytes');
  }
  return bytes;
}

/// Reads a required string field from [json].
String readStringField(Map<String, Object?> json, String name) {
  final value = json[name];
  if (value is! String) {
    throw FormatException('missing or non-string field "$name"');
  }
  return value;
}

/// Decodes [bytes] as a UTF-8 JSON object.
Map<String, Object?> decodeJsonObject(Uint8List bytes) {
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } on FormatException {
    throw const FormatException('not UTF-8 JSON');
  }
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('not a JSON object');
  }
  return decoded;
}

/// Copies the entries of [json] whose key is not in [known].
Map<String, Object?> unknownFields(
  Map<String, Object?> json,
  Set<String> known,
) =>
    {
      for (final e in json.entries)
        if (!known.contains(e.key)) e.key: e.value,
    };
