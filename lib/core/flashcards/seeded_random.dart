import 'dart:convert';

/// A small pseudo random number generator (mulberry32) that gives the same
/// numbers on the Dart VM, AOT and the web.
///
/// `dart:math` `Random(seed)` is not used on purpose: its algorithm is not
/// guaranteed to stay the same between SDK versions or platforms, and the
/// interval fuzz of the flash card scheduler must replay identically on every
/// device (ENCRYPTED-OBJECTS.md, section 7).
///
/// Every intermediate value stays in `[0, 2^32)`, and 32-bit products go
/// through [_imul32], so no value ever exceeds 2^53 (the exact integer range
/// of a JavaScript number).
class SeededRandom {
  SeededRandom(int seed) : _state = seed & _mask32;

  int _state;

  /// Returns the next raw 32-bit output in `[0, 2^32)`.
  int nextUint32() {
    _state = (_state + 0x6D2B79F5) & _mask32;
    var t = _state;
    t = _imul32(t ^ (t >> 15), t | 1);
    t = t ^ ((t + _imul32(t ^ (t >> 7), t | 61)) & _mask32);
    return (t ^ (t >> 14)) & _mask32;
  }

  /// Returns a double in `[0, 1)`.
  double nextDouble() => nextUint32() / 4294967296.0;
}

/// FNV-1a 32-bit hash over the UTF-8 bytes of [input].
///
/// Used instead of `String.hashCode`, which may differ between runs and
/// platforms.
int fnv1a32(String input) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(input)) {
    hash ^= byte;
    hash = _imul32(hash, 0x01000193);
  }
  return hash;
}

const _mask32 = 0xFFFFFFFF;

/// 32-bit multiplication modulo 2^32, split into 16-bit halves so every
/// intermediate product stays below 2^53.
int _imul32(int a, int b) {
  final aHi = (a >> 16) & 0xFFFF;
  final aLo = a & 0xFFFF;
  final bHi = (b >> 16) & 0xFFFF;
  final bLo = b & 0xFFFF;
  final cross = ((aHi * bLo + aLo * bHi) & 0xFFFF) * 0x10000;
  return (cross + aLo * bLo) & _mask32;
}
