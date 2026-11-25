import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/encrypted_objects/passkey_slot.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:sharedinbox/data/passkey/credential_manager_prf_provider.dart';

const _channel = MethodChannel(CredentialManagerPrfProvider.passkeyChannel);

final _credentialId = Uint8List.fromList(List.filled(16, 7));
final _salt = Uint8List.fromList(List.filled(32, 9));
final _output = Uint8List.fromList(List.filled(32, 3));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final requests = <(String, Map<String, Object?>)>[];

  /// Answers every call with [reply] (JSON-encoded unless a String or an
  /// exception to throw).
  void answer(Object? reply) {
    Future<Object?> handler(MethodCall call) async {
      final args = call.arguments as Map<Object?, Object?>;
      final json = args['requestJson']! as String;
      requests.add((call.method, jsonDecode(json) as Map<String, Object?>));
      if (reply is Exception) throw reply;
      if (reply == null || reply is String) return reply;
      return jsonEncode(reply);
    }

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, handler);
  }

  setUp(requests.clear);
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null),
  );

  const provider = CredentialManagerPrfProvider();

  Future<PrfRegistration> register() => provider.register(
        rpId: passkeyRpId,
        userId: Uint8List(16),
        userName: 'alice@example.com',
        challenge: Uint8List(32),
      );

  Future<PrfAssertion> evaluate() => provider.evaluate(
        rpId: passkeyRpId,
        challenge: Uint8List(32),
        evalByCredential: {b64url(_credentialId): _salt},
      );

  test('create asks for a discoverable passkey with PRF', () async {
    answer({
      'id': b64url(_credentialId),
      'rawId': b64url(_credentialId),
      'clientExtensionResults': {
        'prf': {'enabled': true},
      },
    });

    final reg = await register();

    expect(reg.credentialId, _credentialId);
    final (method, json) = requests.single;
    expect(method, 'create');
    expect(json['rp'], {'id': 'keys.sharedinbox.de', 'name': 'SharedInbox'});
    expect((json['user']! as Map)['name'], 'alice@example.com');
    expect(json['authenticatorSelection'], {
      'residentKey': 'required',
      'requireResidentKey': true,
      'userVerification': 'required',
    });
    expect(json['extensions'], {'prf': <String, Object?>{}});
  });

  test('create with PRF reported off is unsupported', () async {
    answer({
      'rawId': b64url(_credentialId),
      'clientExtensionResults': {
        'prf': {'enabled': false},
      },
    });
    await expectLater(register(), throwsA(isA<PrfUnsupported>()));
  });

  test('get sends evalByCredential and reads prf.results.first', () async {
    answer({
      'rawId': b64url(_credentialId),
      'clientExtensionResults': {
        'prf': {
          'results': {'first': b64url(_output)},
        },
      },
    });

    final assertion = await evaluate();

    expect(assertion.credentialId, _credentialId);
    expect(assertion.output, _output);
    final (method, json) = requests.single;
    expect(method, 'get');
    expect(json['rpId'], 'keys.sharedinbox.de');
    expect(json['userVerification'], 'required');
    expect(json['allowCredentials'], [
      {'type': 'public-key', 'id': b64url(_credentialId)},
    ]);
    expect(json['extensions'], {
      'prf': {
        'evalByCredential': {
          b64url(_credentialId): {'first': b64url(_salt)},
        },
      },
    });
  });

  test('a missing or short PRF output is unsupported', () async {
    answer({'rawId': b64url(_credentialId)});
    await expectLater(evaluate(), throwsA(isA<PrfUnsupported>()));

    answer({
      'rawId': b64url(_credentialId),
      'clientExtensionResults': {
        'prf': {
          'results': {'first': b64url(Uint8List(16))},
        },
      },
    });
    await expectLater(evaluate(), throwsA(isA<PrfUnsupported>()));
  });

  test('malformed responses fail', () async {
    for (final reply in <Object?>[
      null,
      'not json',
      '[1]',
      {'clientExtensionResults': <String, Object?>{}},
      {'rawId': '!!'},
      {
        'rawId': b64url(_credentialId),
        'clientExtensionResults': {
          'prf': {
            'results': {'first': '!!'},
          },
        },
      },
    ]) {
      answer(reply);
      await expectLater(
        evaluate(),
        throwsA(isA<PrfFailed>()),
        reason: '$reply',
      );
    }
  });

  test('platform error codes map to the PRF exceptions', () async {
    for (final (code, matcher) in [
      ('cancelled', isA<PrfCancelled>()),
      ('noCredential', isA<PrfNoCredential>()),
      ('unsupported', isA<PrfUnsupported>()),
      ('failed', isA<PrfFailed>()),
    ]) {
      answer(PlatformException(code: code, message: 'TYPE'));
      await expectLater(evaluate(), throwsA(matcher), reason: code);
    }
  });

  test('no bridge (not Android) is unsupported', () async {
    await expectLater(register(), throwsA(isA<PrfUnsupported>()));
  });
}
