import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  const device = 'a-b_c-d';

  test('newDeviceId is base64url of 16 bytes', () {
    expect(newDeviceId(random: counterRandom()), hasLength(22));
    expect(newDeviceId(), isNot(newDeviceId()));
  });

  test('encodes and parses, also with a deviceId containing -', () {
    final hlc = Hlc(1700000000123, 0xab, device);
    expect(hlc.encode(), '1700000000123-00ab-a-b_c-d');
    expect(hlc.toString(), hlc.encode());
    final back = Hlc.parse(hlc.encode());
    expect(back.wallMs, 1700000000123);
    expect(back.counter, 0xab);
    expect(back.deviceId, device);
    expect(back, hlc);
    expect(back.hashCode, hlc.hashCode);
  });

  test('rejects malformed strings and out-of-range fields', () {
    for (final s in [
      '',
      '170000000012-00ab-x',
      '1700000000123-00AB-x',
      '1700000000123-00ab-',
      '1700000000123_00ab-x',
    ]) {
      expect(() => Hlc.parse(s), throwsFormatException, reason: s);
    }
    expect(() => Hlc(-1, 0, 'x'), throwsArgumentError);
    expect(() => Hlc(0, 0x10000, 'x'), throwsArgumentError);
    expect(() => Hlc(0, 0, ''), throwsArgumentError);
  });

  test('string order is (wallMs, counter, deviceId) order', () {
    final sorted = [
      Hlc(999, 0, 'z'),
      Hlc(1000, 0, 'a'),
      Hlc(1000, 0, 'b'),
      Hlc(1000, 1, 'a'),
      Hlc(1000, 0x10, 'a'),
      Hlc(10000, 0, 'a'),
    ];
    final shuffled = [...sorted.reversed]..sort();
    expect(shuffled, sorted);
    expect(sorted[1] > sorted[0], isTrue);
    expect(sorted[0] <= sorted[0], isTrue);
  });

  test('send is monotonic even if the wall clock stalls or goes back', () {
    var now = 1000;
    final clock = HlcClock('me', nowMs: () => now);
    expect(clock.high, isNull);
    expect(clock.send(), Hlc(1000, 0, 'me'));
    expect(clock.send(), Hlc(1000, 1, 'me'));
    now = 900;
    expect(clock.send(), Hlc(1000, 2, 'me'));
    now = 2000;
    expect(clock.send(), Hlc(2000, 0, 'me'));
    expect(clock.high, Hlc(2000, 0, 'me'));
  });

  test('receive advances past a remote timestamp', () {
    const now = 1000;
    final clock = HlcClock('me', nowMs: () => now);
    clock.receive(Hlc(1500, 7, 'other'));
    expect(clock.send(), Hlc(1500, 8, 'me'));
    clock.receive(Hlc(1200, 0, 'other'));
    expect(clock.send(), Hlc(1500, 9, 'me'));
  });

  test('a remote timestamp more than 5 min ahead does not advance', () {
    const now = 1000;
    final clock = HlcClock('me', nowMs: () => now);
    clock.receive(Hlc(now + HlcClock.maxSkewMs + 1, 0, 'other'));
    expect(clock.send(), Hlc(1000, 0, 'me'));
    clock.receive(Hlc(now + HlcClock.maxSkewMs, 0, 'other'));
    expect(clock.send(), Hlc(now + HlcClock.maxSkewMs, 1, 'me'));
  });

  test('counter overflow bumps wallMs', () {
    final clock = HlcClock(
      'me',
      nowMs: () => 1000,
      high: Hlc(1000, Hlc.maxCounter - 1, 'me'),
    );
    expect(clock.send(), Hlc(1000, Hlc.maxCounter, 'me'));
    expect(clock.send(), Hlc(1001, 0, 'me'));
  });

  test('advancePast has no skew guard and seq advances', () {
    final clock = HlcClock('me', nowMs: () => 1000, seqHigh: 4);
    clock.advancePast([Hlc(5000000, 3, 'me'), Hlc(10, 0, 'me')]);
    expect(clock.send(), Hlc(5000000, 4, 'me'));
    expect(clock.nextSeq(), 5);
    clock
      ..advanceSeqPast(41)
      ..advanceSeqPast(7);
    expect(clock.seqHigh, 41);
    expect(clock.nextSeq(), 42);
  });
}
