import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/recovery_key.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

Matcher _formatError(RecoveryKeyFormatError reason) => throwsA(
      isA<RecoveryKeyFormatException>()
          .having((e) => e.reason, 'reason', reason),
    );

void main() {
  final key = RecoveryKey(seqBytes(0x40, 16));

  test('formats as 8 groups of 4 Crockford chars', () async {
    final s = await key.format();
    expect(
      s,
      matches(RegExp(r'^([0-9A-HJKMNP-TV-Z]{4}-){7}[0-9A-HJKMNP-TV-Z]{4}$')),
    );
  });

  test('round-trips', () async {
    final back = await RecoveryKey.parse(await key.format());
    expect(back.raw, key.raw);
  });

  test('generate gives a fresh 16-byte key that round-trips', () async {
    final a = RecoveryKey.generate();
    expect(a.raw, hasLength(16));
    expect(a.raw, isNot(RecoveryKey.generate().raw));
    expect((await RecoveryKey.parse(await a.format())).raw, a.raw);
  });

  test('accepts lowercase, spaces, underscores and no separators', () async {
    final s = await key.format();
    for (final variant in [
      s.toLowerCase(),
      s.replaceAll('-', ' '),
      s.replaceAll('-', '_'),
      s.replaceAll('-', ''),
      ' ${s.replaceAll('-', '  ')} ',
    ]) {
      expect((await RecoveryKey.parse(variant)).raw, key.raw, reason: variant);
    }
  });

  test('reads O as 0 and I, L as 1', () async {
    // A key whose encoding contains both 0 and 1.
    final s = await _keyWith01();
    final aliased =
        s.replaceAll('0', 'o').replaceFirst('1', 'I').replaceAll('1', 'l');
    expect(aliased, isNot(s));
    expect(
      (await RecoveryKey.parse(aliased)).raw,
      (await RecoveryKey.parse(s)).raw,
    );
  });

  test('every single-char substitution is a checksum mismatch', () async {
    final s = (await key.format()).replaceAll('-', '');
    for (var i = 0; i < s.length; i++) {
      final other =
          crockfordAlphabet[(crockfordAlphabet.indexOf(s[i]) + 1) % 32];
      final typo = s.replaceRange(i, i + 1, other);
      // 160 bits = 32 × 5: every char carries payload, none is padding.
      await expectLater(
        RecoveryKey.parse(typo),
        _formatError(RecoveryKeyFormatError.checksumMismatch),
        reason: 'position $i',
      );
    }
  });

  test('rejects invalid chars such as U', () async {
    final s = await key.format();
    await expectLater(
      RecoveryKey.parse('U${s.substring(1)}'),
      _formatError(RecoveryKeyFormatError.invalidChar),
    );
    await expectLater(
      RecoveryKey.parse('${s.substring(1)}!'),
      _formatError(RecoveryKeyFormatError.invalidChar),
    );
  });

  test('rejects a wrong length', () async {
    final s = await key.format();
    await expectLater(
      RecoveryKey.parse(s.substring(0, s.length - 1)),
      _formatError(RecoveryKeyFormatError.wrongLength),
    );
    await expectLater(
      RecoveryKey.parse('${s}0'),
      _formatError(RecoveryKeyFormatError.wrongLength),
    );
  });

  test('rejects a raw key of the wrong length', () {
    expect(() => RecoveryKey(seqBytes(0, 15)), throwsArgumentError);
  });

  test('the KEK is HKDF of the raw 16 bytes only', () async {
    final kek = await key.kek();
    expect(kek.bytes, hasLength(32));
    expect(kek.bytes, isNot(key.raw));
    final other = await RecoveryKey(seqBytes(0x41, 16)).kek();
    expect(other.bytes, isNot(kek.bytes));
    expect(HkdfInfo.kekRecovery, 'sharedinbox-kek-recovery-v1');
  });

  test('exception describes its reason', () {
    expect(
      const RecoveryKeyFormatException(RecoveryKeyFormatError.wrongLength)
          .toString(),
      contains('wrongLength'),
    );
  });
}

Future<String> _keyWith01() async {
  for (var start = 0;; start++) {
    final s = await RecoveryKey(seqBytes(start, 16)).format();
    if (s.contains('0') && s.contains('1')) return s;
  }
}
