import 'dart:convert';
import 'dart:typed_data';

import 'package:sharedinbox/core/encrypted_objects/key_mail.dart';
import 'package:sharedinbox/core/encrypted_objects/passphrase.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

/// Cheap enough for unit tests.
const _tiny = Argon2idParams(memoryKiB: 64, iterations: 1);

const _good = 'violet tractor sings beneath copper rain';

UnlockSlot _withKdf(UnlockSlot slot, Object? kdf) => UnlockSlot.fromJson({
      ...slot.toJson(),
      'kdf': kdf,
    });

void main() {
  group('slot', () {
    test('round-trips with the passphrase; a wrong one does not open',
        () async {
      final slot =
          await wrapPassphraseSlot(testAccountKey, _good, params: _tiny);
      expect(slot.type, UnlockSlotType.passphrase);

      final key = await unwrapPassphraseSlot(
        slot,
        _good,
        testAccountKey.accountKeyId,
        deriver: argon2id,
      );
      expect(key.key.bytes, testAccountKey.key.bytes);

      await expectLater(
        unwrapPassphraseSlot(
          slot,
          '$_good ',
          testAccountKey.accountKeyId,
          deriver: argon2id,
        ),
        throwsA(isA<KeyUnwrapException>()),
      );
    });

    test('the default deriver runs Argon2id in an isolate', () async {
      final salt = seqBytes(1, 16);
      expect(
        await argon2idInIsolate(utf8.encode(_good), salt, _tiny),
        await argon2id(utf8.encode(_good), salt, _tiny),
      );
    });

    test('salt and params come from the slot, not the defaults', () async {
      const params = Argon2idParams(memoryKiB: 96, iterations: 2);
      final slot =
          await wrapPassphraseSlot(testAccountKey, _good, params: params);
      final seen = <({Uint8List salt, Argon2idParams params})>[];
      Future<Uint8List> spy(
        Uint8List passphrase,
        Uint8List salt,
        Argon2idParams params,
      ) {
        seen.add((salt: salt, params: params));
        return argon2id(passphrase, salt, params);
      }

      final key = await unwrapPassphraseSlot(
        slot,
        _good,
        testAccountKey.accountKeyId,
        deriver: spy,
      );

      expect(key.key.bytes, testAccountKey.key.bytes);
      expect(seen.single.salt, b64urlDecode(slot.extra['salt']! as String));
      expect(seen.single.params.toJson(), params.toJson());
    });

    test('the defaults are m=64 MiB, t=3, p=1 and are stored', () async {
      final seen = <Argon2idParams>[];
      final slot = await wrapPassphraseSlot(
        testAccountKey,
        _good,
        deriver: (passphrase, salt, params) async {
          seen.add(params);
          return Uint8List(32);
        },
      );
      expect(seen.single.toJson(), {
        'alg': 'argon2id',
        'v': 19,
        'm': 65536,
        't': 3,
        'p': 1,
      });
      expect(slot.extra['kdf'], seen.single.toJson());
      expect(b64urlDecode(slot.extra['salt']! as String), hasLength(16));
    });

    test('salt and kdf survive a JSON round trip of the key mail', () async {
      final slot =
          await wrapPassphraseSlot(testAccountKey, _good, params: _tiny);
      final payload = KeyMailPayload(
        accountKeyId: testAccountKey.accountKeyId,
        slotListVersion: 1,
        slots: [slot],
      );
      final parsed = KeyMailPayload.parse(payload.bytes).slots.single;
      expect(parsed.extra, slot.extra);
      final key = await unwrapPassphraseSlot(
        parsed,
        _good,
        testAccountKey.accountKeyId,
        deriver: argon2id,
      );
      expect(key.key.bytes, testAccountKey.key.bytes);
    });

    test('an unknown or out-of-range kdf is a FormatException', () async {
      final slot =
          await wrapPassphraseSlot(testAccountKey, _good, params: _tiny);
      final kdf = _tiny.toJson();
      for (final bad in <Object?>[
        null,
        'argon2id',
        {...kdf, 'alg': 'scrypt'},
        {...kdf, 'v': 16},
        {...kdf, 'm': 262145},
        {...kdf, 'm': 4},
        {...kdf, 't': 11},
        {...kdf, 't': 0},
        {...kdf, 'p': 5},
        {...kdf, 'p': 0},
        {...kdf, 'm': '64'},
      ]) {
        await expectLater(
          unwrapPassphraseSlot(
            _withKdf(slot, bad),
            _good,
            testAccountKey.accountKeyId,
            deriver: (passphrase, salt, params) => fail('derived with $bad'),
          ),
          throwsFormatException,
          reason: '$bad',
        );
      }
      // The caps themselves are fine.
      expect(
        Argon2idParams.fromJson({
          ...kdf,
          'm': Argon2idParams.maxMemoryKiB,
          't': Argon2idParams.maxIterations,
          'p': Argon2idParams.maxParallelism,
        }).memoryKiB,
        Argon2idParams.maxMemoryKiB,
      );
      final noSalt = UnlockSlot.fromJson(
        {...slot.toJson()}..remove('salt'),
      );
      await expectLater(
        unwrapPassphraseSlot(noSalt, _good, testAccountKey.accountKeyId),
        throwsFormatException,
      );
    });
  });

  group('checkPassphraseStrength', () {
    const context = ['alice.smith@example.com', 'alice.smith', 'asmith'];

    PassphraseWeakness? check(String p) =>
        checkPassphraseStrength(p, context: context);

    test('refuses weak passphrases', () {
      expect(check('short words'), PassphraseWeakness.tooShort);
      expect(check('äöüäöüäöüäö'), PassphraseWeakness.tooShort);
      expect(check('password1234'), PassphraseWeakness.common);
      expect(check('Summer2024!!'), PassphraseWeakness.common);
      expect(
        check('Correct Horse Battery Staple'),
        PassphraseWeakness.common,
      );
      expect(check('aaaaaaaaaaaaaaaa'), PassphraseWeakness.repetitive);
      expect(check('xyzzyxyzzyxyzzy'), PassphraseWeakness.repetitive);
      expect(check('ab12ab12ab12ab12'), PassphraseWeakness.repetitive);
      expect(check('123456789012345'), PassphraseWeakness.repetitive);
      expect(check('abcdefghijklmnop'), PassphraseWeakness.repetitive);
      expect(check('qwertasdfg98765'), PassphraseWeakness.repetitive);
      expect(check('zyxwvutsrqponm'), PassphraseWeakness.repetitive);
      expect(
        check('my mail is Alice.Smith'),
        PassphraseWeakness.containsAccountName,
      );
      expect(
        check('hello asmith how are you'),
        PassphraseWeakness.containsAccountName,
      );
    });

    test('accepts a long passphrase of several words', () {
      expect(check(_good), isNull);
      expect(check('gravel-orbit-maple-lantern'), isNull);
      // Short context parts do not count.
      expect(
        checkPassphraseStrength(_good, context: ['in', '', 'ra']),
        isNull,
      );
    });
  });
}
