import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/flashcards/seeded_random.dart';

void main() {
  group('SeededRandom', () {
    // Golden values: a change here changes every fuzzed due date on replay.
    // Computed with the reference mulberry32 (same as the JavaScript
    // original: mulberry32(42)() == 0.6011037519201636).
    test('mulberry32 outputs are frozen for seed 42', () {
      final r = SeededRandom(42);
      expect(
        [for (var i = 0; i < 5; i++) r.nextUint32()],
        [2581720956, 1925393290, 3661312704, 2876485805, 750819978],
      );
    });

    test('mulberry32 outputs are frozen for seed 0', () {
      final r = SeededRandom(0);
      expect(
        [for (var i = 0; i < 3; i++) r.nextUint32()],
        [1144304738, 1416247, 958946056],
      );
    });

    test('nextDouble is the 32-bit output scaled to [0, 1)', () {
      expect(SeededRandom(42).nextDouble(), 2581720956 / 4294967296.0);
      final r = SeededRandom(7);
      for (var i = 0; i < 1000; i++) {
        final d = r.nextDouble();
        expect(d, greaterThanOrEqualTo(0));
        expect(d, lessThan(1));
      }
    });

    test('seed is reduced to 32 bits', () {
      expect(
        SeededRandom(0x100000000 + 42).nextUint32(),
        SeededRandom(42).nextUint32(),
      );
    });
  });

  group('fnv1a32', () {
    test('matches the FNV-1a reference values', () {
      expect(fnv1a32(''), 0x811c9dc5);
      expect(fnv1a32('a'), 0xe40c292c);
    });

    test('is frozen for a (cardId, h) seed string', () {
      expect(fnv1a32('card-1\u0000h1'), 2363512684);
    });

    test('hashes UTF-8 bytes', () {
      expect(fnv1a32('ä'), isNot(fnv1a32('a')));
      expect(fnv1a32('ä'), fnv1a32('ä'));
    });
  });
}
