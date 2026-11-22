import 'dart:typed_data';

import 'package:sharedinbox/core/encrypted_objects/wire.dart';

/// `start, start+1, …` as [length] bytes.
Uint8List seqBytes(int start, int length) =>
    Uint8List.fromList([for (var i = 0; i < length; i++) (start + i) & 0xff]);

/// Deterministic [RandomBytes]: each call returns the next counter value
/// repeated, so every draw differs.
RandomBytes counterRandom([int seed = 1]) {
  var next = seed;
  return (length) => Uint8List(length)..fillRange(0, length, next++ & 0xff);
}

/// [RandomBytes] returning [draws] in order.
RandomBytes queuedRandom(List<Uint8List> draws) {
  final queue = [...draws];
  return (length) {
    final draw = queue.removeAt(0);
    if (draw.length != length) {
      throw StateError('expected a draw of $length bytes');
    }
    return draw;
  };
}

Uint8List hexBytes(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

String toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
