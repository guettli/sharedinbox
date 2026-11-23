import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

import 'package:sharedinbox/core/encrypted_objects/common_passwords.dart';
import 'package:sharedinbox/core/encrypted_objects/key_mail.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';

/// Passphrase unlock slot (`ENCRYPTED-OBJECTS.md` 4.2): KEK =
/// HKDF(Argon2id(passphrase, salt), `sharedinbox-kek-passphrase-v1`). The
/// salt and the Argon2id params are stored in the slot, next to the known
/// fields: `salt` (16 bytes, base64url) and
/// `kdf: {alg: "argon2id", v: 19, m, t, p}`.

/// Length of the random salt of a passphrase slot.
const passphraseSaltLength = 16;

/// Minimum length of a passphrase, in characters (runes).
const minPassphraseLength = 12;

const _argon2Alg = 'argon2id';

/// Argon2 version 1.3.
const _argon2Version = 19;

/// Argon2id cost parameters of a passphrase slot.
class Argon2idParams {
  const Argon2idParams({
    this.memoryKiB = 65536,
    this.iterations = 3,
    this.parallelism = 1,
  });

  /// Reads the `kdf` field of a slot. Throws [FormatException] for another
  /// algorithm or version, and for params outside the caps: the slot MAC
  /// can only be checked after the unwrap, so a server could otherwise
  /// plant params that exhaust the device's memory or time.
  factory Argon2idParams.fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const FormatException('missing or non-object field "kdf"');
    }
    if (json['alg'] != _argon2Alg) {
      throw const FormatException('unsupported kdf alg');
    }
    if (json['v'] != _argon2Version) {
      throw const FormatException('unsupported argon2 version');
    }
    final m = json['m'];
    final t = json['t'];
    final p = json['p'];
    if (m is! int || t is! int || p is! int) {
      throw const FormatException('argon2 params must be integers');
    }
    if (p < 1 || p > maxParallelism) {
      throw const FormatException('argon2 p out of range');
    }
    if (t < 1 || t > maxIterations) {
      throw const FormatException('argon2 t out of range');
    }
    if (m < 8 * p || m > maxMemoryKiB) {
      throw const FormatException('argon2 m out of range');
    }
    return Argon2idParams(memoryKiB: m, iterations: t, parallelism: p);
  }

  /// 256 MiB.
  static const maxMemoryKiB = 262144;
  static const maxIterations = 10;
  static const maxParallelism = 4;

  final int memoryKiB;
  final int iterations;
  final int parallelism;

  Map<String, Object?> toJson() => {
        'alg': _argon2Alg,
        'v': _argon2Version,
        'm': memoryKiB,
        't': iterations,
        'p': parallelism,
      };
}

/// Raw Argon2id: 32 bytes of [passphrase] (UTF-8) under [salt]. Injectable
/// so tests can spy on it or skip the cost.
typedef PassphraseDeriver = Future<Uint8List> Function(
  Uint8List passphrase,
  Uint8List salt,
  Argon2idParams params,
);

/// Default [PassphraseDeriver]: the pure-Dart Argon2id of `cryptography`,
/// in an isolate so the UI keeps running.
Future<Uint8List> argon2idInIsolate(
  Uint8List passphrase,
  Uint8List salt,
  Argon2idParams params,
) =>
    Isolate.run(() => argon2id(passphrase, salt, params));

/// Argon2id in the current isolate.
Future<Uint8List> argon2id(
  Uint8List passphrase,
  Uint8List salt,
  Argon2idParams params,
) async {
  final key = await DartArgon2id(
    parallelism: params.parallelism,
    memory: params.memoryKiB,
    iterations: params.iterations,
    hashLength: keyLength,
  ).deriveKey(secretKey: SecretKeyData(passphrase), nonce: salt);
  return Uint8List.fromList(await key.extractBytes());
}

/// KEK of a passphrase slot. The passphrase is used as its exact UTF-8
/// bytes: no trimming, no normalization.
Future<SecretKeyData> derivePassphraseKek(
  String passphrase,
  Uint8List salt,
  Argon2idParams params, {
  PassphraseDeriver deriver = argon2idInIsolate,
}) async {
  final raw = await deriver(
    Uint8List.fromList(utf8.encode(passphrase)),
    salt,
    params,
  );
  return deriveSubKey(SecretKeyData(raw), HkdfInfo.kekPassphrase);
}

/// Creates a `passphrase` slot with a fresh salt.
Future<UnlockSlot> wrapPassphraseSlot(
  AccountKey accountKey,
  String passphrase, {
  Argon2idParams params = const Argon2idParams(),
  RandomBytes random = secureRandomBytes,
  PassphraseDeriver deriver = argon2idInIsolate,
}) async {
  final salt = random(passphraseSaltLength);
  return wrapSlot(
    accountKey,
    await derivePassphraseKek(passphrase, salt, params, deriver: deriver),
    UnlockSlotType.passphrase,
    extra: {'salt': b64url(salt), 'kdf': params.toJson()},
    random: random,
  );
}

/// The salt and params of a passphrase [slot], as stored in it. Throws
/// [FormatException] for a malformed or out-of-range slot.
({Uint8List salt, Argon2idParams params}) passphraseSlotKdf(
  UnlockSlot slot,
) =>
    (
      salt: readBytesField(slot.extra, 'salt', passphraseSaltLength),
      params: Argon2idParams.fromJson(slot.extra['kdf']),
    );

/// Unlocks with a passphrase, with the salt and params of the slot. Throws
/// [KeyUnwrapException] for a wrong passphrase and [FormatException] for a
/// malformed slot.
Future<AccountKey> unwrapPassphraseSlot(
  UnlockSlot slot,
  String passphrase,
  Uint8List accountKeyId, {
  PassphraseDeriver deriver = argon2idInIsolate,
}) async {
  final kdf = passphraseSlotKdf(slot);
  return unwrapSlot(
    slot,
    await derivePassphraseKek(
      passphrase,
      kdf.salt,
      kdf.params,
      deriver: deriver,
    ),
    accountKeyId,
  );
}

/// Why [checkPassphraseStrength] refused a passphrase.
enum PassphraseWeakness { tooShort, common, repetitive, containsAccountName }

/// The minimum strength of a passphrase slot: at least
/// [minPassphraseLength] characters, not a common password, no repeats or
/// keyboard/alphabet sequences, and none of the [context] strings (the
/// email address, its local part, the username) of 3 or more characters.
/// Returns null for a passphrase that passes.
PassphraseWeakness? checkPassphraseStrength(
  String passphrase, {
  Iterable<String> context = const [],
}) {
  if (passphrase.runes.length < minPassphraseLength) {
    return PassphraseWeakness.tooShort;
  }
  final lower = passphrase.toLowerCase();
  // A common word dressed up with a few digits or symbols (`Summer2024!!`).
  final letters = lower.replaceAll(RegExp('[^a-z]'), '');
  final dressedUp =
      letters.length * 2 >= lower.length && commonPasswords.contains(letters);
  if (dressedUp ||
      commonPasswords.contains(lower) ||
      commonPasswords.contains(lower.replaceAll(RegExp(r'\s'), ''))) {
    return PassphraseWeakness.common;
  }
  final compact = lower.replaceAll(RegExp(r'[\s\-_.]'), '');
  if (_isRepeated(compact) || _isSequence(compact)) {
    return PassphraseWeakness.repetitive;
  }
  for (final c in context) {
    final part = c.trim().toLowerCase();
    if (part.length >= 3 && lower.contains(part)) {
      return PassphraseWeakness.containsAccountName;
    }
  }
  return null;
}

/// One short unit repeated (`aaaa…`, `abcabc…`, `passwordpassword`), or
/// at most 3 distinct characters.
bool _isRepeated(String s) {
  final runes = s.runes.toList();
  if (runes.toSet().length <= 3) return true;
  for (var unit = 1; unit <= runes.length ~/ 2; unit++) {
    var repeats = true;
    for (var i = unit; i < runes.length && repeats; i++) {
      repeats = runes[i] == runes[i - unit];
    }
    if (repeats) return true;
  }
  return false;
}

const _sequences = [
  '0123456789',
  'abcdefghijklmnopqrstuvwxyz',
  'qwertyuiopasdfghjklzxcvbnm',
  'qwertzuiopasdfghjklyxcvbnm',
  'azertyuiopqsdfghjklmwxcvbn',
  '1qaz2wsx3edc4rfv5tgb6yhn7ujm8ik9ol0p',
  '1234567890qwertyuiop',
];

/// Sequences forward and backward, doubled so they wrap (`7890123`).
final _sequenceText = [
  for (final s in _sequences) ...[
    s + s,
    String.fromCharCodes((s + s).runes.toList().reversed),
  ],
];

/// Made only of runs of 3 or more characters along the alphabet, the
/// digits or a keyboard row (`qwerty123456`, `abcdefghijkl`).
bool _isSequence(String s) {
  var i = 0;
  while (i < s.length) {
    var longest = 0;
    for (var end = s.length; end > i + longest; end--) {
      final piece = s.substring(i, end);
      if (_sequenceText.any((t) => t.contains(piece))) {
        longest = end - i;
        break;
      }
    }
    if (longest < 3) return false;
    i += longest;
  }
  return true;
}
