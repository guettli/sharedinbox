import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:sharedinbox/core/encrypted_objects/passkey_slot.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';

/// The passkeys of one password manager, shared by the devices of a test:
/// credential id (base64url) → PRF secret.
class FakePasskeyVault {
  final secrets = <String, Uint8List>{};
  var _next = 1;

  Uint8List create() {
    final id = Uint8List(16)..fillRange(0, 16, _next++);
    secrets[b64url(id)] = Uint8List(32)..fillRange(0, 32, 0x80 + _next);
    return id;
  }
}

/// A [PrfProvider] whose PRF is HMAC-SHA256(salt) under a secret per
/// credential of its [vault]. The user picks [pick], else the first asked
/// credential the vault has.
class FakePrfProvider implements PrfProvider {
  FakePrfProvider([FakePasskeyVault? vault])
      : vault = vault ?? FakePasskeyVault();

  final FakePasskeyVault vault;

  /// Registers, but gives no PRF output.
  bool noPrf = false;

  /// The user closes the dialog.
  bool cancel = false;

  /// Answers with a credential that was not asked for.
  bool answerOther = false;

  /// The credential id (base64url) the user picks, if it is asked for.
  String? pick;

  final registrations = <({String rpId, String userName})>[];
  final evaluations = <Map<String, Uint8List>>[];

  @override
  Future<PrfRegistration> register({
    required String rpId,
    required Uint8List userId,
    required String userName,
    required Uint8List challenge,
  }) async {
    if (cancel) throw const PrfCancelled('cancelled');
    registrations.add((rpId: rpId, userName: userName));
    return PrfRegistration(vault.create());
  }

  @override
  Future<PrfAssertion> evaluate({
    required String rpId,
    required Uint8List challenge,
    required Map<String, Uint8List> evalByCredential,
  }) async {
    evaluations.add(Map.of(evalByCredential));
    if (cancel) throw const PrfCancelled('cancelled');
    if (noPrf) throw const PrfUnsupported('no PRF');
    if (answerOther) {
      final other = vault.create();
      return PrfAssertion(
        credentialId: other,
        output: await _prf(other, Uint8List(32)),
      );
    }
    final known = evalByCredential.keys.where(vault.secrets.containsKey);
    if (known.isEmpty) throw const PrfNoCredential('no passkey');
    final id = known.contains(pick) ? pick! : known.first;
    final credentialId = b64urlDecode(id);
    return PrfAssertion(
      credentialId: credentialId,
      output: await _prf(credentialId, evalByCredential[id]!),
    );
  }

  Future<Uint8List> _prf(Uint8List credentialId, Uint8List salt) async {
    final mac = await Hmac.sha256().calculateMac(
      salt,
      secretKey: SecretKeyData(vault.secrets[b64url(credentialId)]!),
    );
    return Uint8List.fromList(mac.bytes);
  }
}
