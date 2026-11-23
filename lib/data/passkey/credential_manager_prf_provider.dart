import 'dart:convert';

import 'package:flutter/services.dart';

import 'package:sharedinbox/core/encrypted_objects/passkey_slot.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';

/// [PrfProvider] on Android's Credential Manager, via `PasskeyBridge.kt`.
/// The WebAuthn JSON goes through as is; Credential Manager hands the PRF
/// extension to the password manager.
class CredentialManagerPrfProvider implements PrfProvider {
  const CredentialManagerPrfProvider({
    MethodChannel channel = const MethodChannel(passkeyChannel),
  }) : _channel = channel;

  static const passkeyChannel = 'de.sharedinbox.mua/passkey';

  final MethodChannel _channel;

  @override
  Future<PrfRegistration> register({
    required String rpId,
    required Uint8List userId,
    required String userName,
    required Uint8List challenge,
  }) async {
    final response = await _call('create', {
      'challenge': b64url(challenge),
      'rp': {'id': rpId, 'name': 'SharedInbox'},
      'user': {
        'id': b64url(userId),
        'name': userName,
        'displayName': userName,
      },
      'pubKeyCredParams': [
        {'type': 'public-key', 'alg': -7},
        {'type': 'public-key', 'alg': -257},
      ],
      'attestation': 'none',
      'authenticatorSelection': {
        'residentKey': 'required',
        'requireResidentKey': true,
        'userVerification': 'required',
      },
      'extensions': {'prf': <String, Object?>{}},
    });
    final prf = _prfResults(response);
    if (prf?['enabled'] == false) {
      throw const PrfUnsupported('the password manager has no PRF');
    }
    return PrfRegistration(_credentialId(response));
  }

  @override
  Future<PrfAssertion> evaluate({
    required String rpId,
    required Uint8List challenge,
    required Map<String, Uint8List> evalByCredential,
  }) async {
    final response = await _call('get', {
      'challenge': b64url(challenge),
      'rpId': rpId,
      // evalByCredential only takes credentials of allowCredentials.
      'allowCredentials': [
        for (final id in evalByCredential.keys)
          {'type': 'public-key', 'id': id},
      ],
      'userVerification': 'required',
      'extensions': {
        'prf': {
          'evalByCredential': {
            for (final e in evalByCredential.entries)
              e.key: {'first': b64url(e.value)},
          },
        },
      },
    });
    final credentialId = _credentialId(response);
    final results = _prfResults(response)?['results'];
    final first = results is Map ? results['first'] : null;
    if (first is! String) {
      throw const PrfUnsupported('the passkey gave no PRF output');
    }
    final Uint8List output;
    try {
      output = b64urlDecode(first);
    } on FormatException {
      throw const PrfFailed('the PRF output is not base64url');
    }
    if (output.length != prfOutputLength) {
      throw const PrfUnsupported('the PRF output has the wrong length');
    }
    return PrfAssertion(credentialId: credentialId, output: output);
  }

  Future<Map<String, Object?>> _call(
    String method,
    Map<String, Object?> request,
  ) async {
    final String? json;
    try {
      json = await _channel.invokeMethod<String>(method, {
        'requestJson': jsonEncode(request),
      });
    } on MissingPluginException {
      throw const PrfUnsupported('no passkey bridge on this platform');
    } on PlatformException catch (e) {
      final message = e.message ?? e.code;
      throw switch (e.code) {
        'cancelled' => PrfCancelled(message),
        'noCredential' => PrfNoCredential(message),
        'unsupported' => PrfUnsupported(message),
        _ => PrfFailed(message),
      };
    }
    if (json == null) throw const PrfFailed('empty response');
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      throw const PrfFailed('the response is not JSON');
    }
    if (decoded is! Map<String, Object?>) {
      throw const PrfFailed('the response is not a JSON object');
    }
    return decoded;
  }

  static Map<String, Object?>? _prfResults(Map<String, Object?> response) {
    final ext = response['clientExtensionResults'];
    if (ext is! Map<String, Object?>) return null;
    final prf = ext['prf'];
    return prf is Map<String, Object?> ? prf : null;
  }

  static Uint8List _credentialId(Map<String, Object?> response) {
    final id = response['rawId'] ?? response['id'];
    if (id is! String || id.isEmpty) {
      throw const PrfFailed('the response has no credential id');
    }
    try {
      return b64urlDecode(id);
    } on FormatException {
      throw const PrfFailed('the credential id is not base64url');
    }
  }
}
