import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';

/// Recovery key (`ENCRYPTED-OBJECTS.md` 4.2, 4.6): 128 random bits plus a
/// 32-bit checksum (first 4 bytes of SHA-256 of the raw 16 bytes), written
/// as 32 Crockford base32 chars in 8 groups of 4.

/// Crockford base32 alphabet (no I, L, O, U).
const crockfordAlphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

const _rawLength = 16;
const _checksumLength = 4;
const _charLength = 32;

/// Why [RecoveryKey.parse] rejected its input.
enum RecoveryKeyFormatError { invalidChar, wrongLength, checksumMismatch }

class RecoveryKeyFormatException implements Exception {
  const RecoveryKeyFormatException(this.reason);

  final RecoveryKeyFormatError reason;

  @override
  String toString() => 'RecoveryKeyFormatException: ${reason.name}';
}

/// [input] as [RecoveryKey.parse] reads it: upper case, without spaces, `-`
/// and `_`, `O` as `0`, `I` and `L` as `1`.
String normalizeRecoveryInput(String input) => input
    .toUpperCase()
    .replaceAll(RegExp(r'[\s\-_]'), '')
    .replaceAll('O', '0')
    .replaceAll(RegExp('[IL]'), '1');

class RecoveryKey {
  RecoveryKey(Uint8List raw) : raw = Uint8List.fromList(raw) {
    if (raw.length != _rawLength) {
      throw ArgumentError.value(raw.length, 'raw', 'must be 16 bytes');
    }
  }

  factory RecoveryKey.generate({RandomBytes random = secureRandomBytes}) =>
      RecoveryKey(random(_rawLength));

  /// Parses a recovery key as typed by a user: case-insensitive; spaces, `-`
  /// and `_` are ignored; `O` reads as `0`, `I` and `L` as `1`.
  static Future<RecoveryKey> parse(String input) async {
    final normalized = normalizeRecoveryInput(input);
    for (final unit in normalized.split('')) {
      if (!crockfordAlphabet.contains(unit)) {
        throw const RecoveryKeyFormatException(
          RecoveryKeyFormatError.invalidChar,
        );
      }
    }
    if (normalized.length != _charLength) {
      throw const RecoveryKeyFormatException(
        RecoveryKeyFormatError.wrongLength,
      );
    }
    final bytes = _decode(normalized);
    final key = RecoveryKey(bytes.sublist(0, _rawLength));
    final expected = await key.checksum();
    if (!constantTimeEquals(expected, bytes.sublist(_rawLength))) {
      throw const RecoveryKeyFormatException(
        RecoveryKeyFormatError.checksumMismatch,
      );
    }
    return key;
  }

  /// The 128 random bits.
  final Uint8List raw;

  /// First 4 bytes of SHA-256(raw).
  Future<Uint8List> checksum() async {
    final hash = await Sha256().hash(raw);
    return Uint8List.fromList(hash.bytes.sublist(0, _checksumLength));
  }

  /// `XXXX-XXXX-…` (8 groups of 4).
  Future<String> format() async {
    final chars = _encode(Uint8List.fromList([...raw, ...await checksum()]));
    final groups = [
      for (var i = 0; i < chars.length; i += 4) chars.substring(i, i + 4),
    ];
    return groups.join('-');
  }

  /// KEK of the recovery slot: HKDF(raw, `sharedinbox-kek-recovery-v1`).
  Future<SecretKeyData> kek() =>
      deriveSubKey(SecretKeyData(raw), HkdfInfo.kekRecovery);
}

// 20 bytes = 160 bits = exactly 32 five-bit groups, most significant first.
String _encode(Uint8List bytes) {
  final out = StringBuffer();
  var buffer = 0;
  var bits = 0;
  for (final byte in bytes) {
    buffer = ((buffer << 8) | byte) & 0xfff;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out.write(crockfordAlphabet[(buffer >> bits) & 0x1f]);
    }
  }
  return out.toString();
}

Uint8List _decode(String chars) {
  final out = BytesBuilder();
  var buffer = 0;
  var bits = 0;
  for (final unit in chars.split('')) {
    buffer = ((buffer << 5) | crockfordAlphabet.indexOf(unit)) & 0xfff;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out.addByte((buffer >> bits) & 0xff);
    }
  }
  return out.toBytes();
}
