import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:sharedinbox/core/encrypted_objects/key_mail.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';

/// Passkey unlock slot (`ENCRYPTED-OBJECTS.md` 4.2): KEK =
/// HKDF(WebAuthn PRF output, `sharedinbox-kek-passkey-v1`). No server: the
/// challenge is made on the device and only the PRF output is used. The
/// slot carries, in clear next to the known fields: `credentialId`
/// (base64url), `prfSalt` (32 bytes, base64url), `rpId` and `label`.

/// The WebAuthn relying party of every passkey slot.
const passkeyRpId = 'sharedinbox.de';

/// Length of the PRF salt of a passkey slot.
const prfSaltLength = 32;

/// Length of the PRF output (`prf.results.first`).
const prfOutputLength = 32;

/// Length of the local WebAuthn challenge and of the user handle.
const passkeyChallengeLength = 32;
const passkeyUserIdLength = 16;

/// WebAuthn caps a credential id at 1023 bytes.
const _maxCredentialIdLength = 1023;

/// A new passkey: the id of its credential.
class PrfRegistration {
  const PrfRegistration(this.credentialId);

  final Uint8List credentialId;
}

/// A passkey's answer: which credential answered and its PRF output.
class PrfAssertion {
  const PrfAssertion({required this.credentialId, required this.output});

  final Uint8List credentialId;

  /// [prfOutputLength] bytes.
  final Uint8List output;
}

/// Why the platform passkey call failed.
sealed class PrfException implements Exception {
  const PrfException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The password manager has no PRF, or passkeys are not available here.
final class PrfUnsupported extends PrfException {
  const PrfUnsupported(super.message);
}

/// The user closed the passkey dialog.
final class PrfCancelled extends PrfException {
  const PrfCancelled(super.message);
}

/// None of the asked passkeys is in the password manager (e.g. deleted).
final class PrfNoCredential extends PrfException {
  const PrfNoCredential(super.message);
}

/// Any other failure of the platform call.
final class PrfFailed extends PrfException {
  const PrfFailed(super.message);
}

/// The platform passkey API with the WebAuthn PRF extension. Throws
/// [PrfException]s.
abstract interface class PrfProvider {
  /// Creates a discoverable passkey for [rpId] with PRF enabled.
  Future<PrfRegistration> register({
    required String rpId,
    required Uint8List userId,
    required String userName,
    required Uint8List challenge,
  });

  /// Asks the user for one of the passkeys in [evalByCredential] (keyed by
  /// the base64url credential id) and evaluates its PRF on that
  /// credential's salt.
  Future<PrfAssertion> evaluate({
    required String rpId,
    required Uint8List challenge,
    required Map<String, Uint8List> evalByCredential,
  });
}

/// KEK of a passkey slot.
Future<SecretKeyData> passkeyKek(Uint8List prfOutput) {
  if (prfOutput.length != prfOutputLength) {
    throw ArgumentError.value(prfOutput.length, 'prfOutput', 'must be 32');
  }
  return deriveSubKey(SecretKeyData(prfOutput), HkdfInfo.kekPasskey);
}

/// Creates a `passkey-prf` slot for the credential [credentialId], whose PRF
/// gave [prfOutput] on [salt].
Future<UnlockSlot> wrapPasskeySlot(
  AccountKey accountKey,
  Uint8List prfOutput, {
  required Uint8List credentialId,
  required Uint8List salt,
  required String label,
  String rpId = passkeyRpId,
  RandomBytes random = secureRandomBytes,
}) async =>
    wrapSlot(
      accountKey,
      await passkeyKek(prfOutput),
      UnlockSlotType.passkeyPrf,
      extra: {
        'credentialId': b64url(credentialId),
        'prfSalt': b64url(salt),
        'rpId': rpId,
        'label': label,
      },
      random: random,
    );

/// Unlocks with the PRF output of the slot's passkey. Throws
/// [KeyUnwrapException] for another output and [FormatException] for a
/// malformed slot.
Future<AccountKey> unwrapPasskeySlot(
  UnlockSlot slot,
  Uint8List prfOutput,
  Uint8List accountKeyId,
) async {
  PasskeySlotInfo.parse(slot);
  if (prfOutput.length != prfOutputLength) {
    throw const KeyUnwrapException('PRF output has the wrong length');
  }
  return unwrapSlot(slot, await passkeyKek(prfOutput), accountKeyId);
}

/// The clear fields of a `passkey-prf` slot.
class PasskeySlotInfo {
  const PasskeySlotInfo({
    required this.slotId,
    required this.credentialId,
    required this.prfSalt,
    required this.rpId,
    required this.label,
  });

  /// Reads a `passkey-prf` slot. Throws [FormatException] for another type
  /// or a missing or malformed field.
  factory PasskeySlotInfo.parse(UnlockSlot slot) {
    if (slot.type != UnlockSlotType.passkeyPrf) {
      throw const FormatException('not a passkey-prf slot');
    }
    final credentialId = readBytesField(slot.extra, 'credentialId', null);
    if (credentialId.isEmpty || credentialId.length > _maxCredentialIdLength) {
      throw const FormatException('credentialId has a bad length');
    }
    final label = slot.extra['label'] ?? '';
    if (label is! String) {
      throw const FormatException('label is not a string');
    }
    return PasskeySlotInfo(
      slotId: slot.slotId,
      credentialId: credentialId,
      prfSalt: readBytesField(slot.extra, 'prfSalt', prfSaltLength),
      rpId: readStringField(slot.extra, 'rpId'),
      label: label,
    );
  }

  /// [PasskeySlotInfo.parse], or null for another type or a malformed slot.
  static PasskeySlotInfo? tryParse(UnlockSlot slot) {
    try {
      return PasskeySlotInfo.parse(slot);
    } on FormatException {
      return null;
    }
  }

  final Uint8List slotId;
  final Uint8List credentialId;
  final Uint8List prfSalt;
  final String rpId;

  /// Chosen by the user, e.g. the name of the password manager.
  final String label;

  String get slotIdB64 => b64url(slotId);
  String get credentialIdB64 => b64url(credentialId);
}
