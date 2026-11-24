import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/import/protobuf_wire.dart';

ProtoReader _read(List<int> bytes) => ProtoReader(Uint8List.fromList(bytes));

void main() {
  test('varints, strings and bytes by field number', () {
    final reader = _read([
      0x08, 0x03, // 1: 3
      0x10, 0xac, 0x02, // 2: 300
      0x1a, 0x03, ...utf8.encode('cat'), // 3: "cat"
      0x22, 0x02, 0xff, 0x00, // 4: bytes
    ]);
    expect(reader.varint(1), 3);
    expect(reader.varint(2), 300);
    expect(reader.string(3), 'cat');
    expect(reader.bytes(4), [0xff, 0x00]);
    expect(reader.varint(5), isNull);
    expect(reader.string(1), isNull);
    expect(reader.varint(3), isNull);
  });

  test('a two-byte tag (field 255)', () {
    // (255 << 3) | 0 = 2040 = 0xf8 0x0f.
    expect(_read([0xf8, 0x0f, 0x07]).varint(255), 7);
  });

  test('repeated messages in order, the last scalar wins', () {
    final reader = _read([
      0x0a, 0x02, 0x08, 0x01, //
      0x08, 0x05, //
      0x0a, 0x02, 0x08, 0x02, //
      0x08, 0x06, //
    ]);
    expect(
      reader.repeated(1).map((m) => ProtoReader(m).varint(1)),
      [1, 2],
    );
    expect(reader.varint(1), 6);
    expect(reader.repeated(2), isEmpty);
  });

  test('skips unknown fixed64 and fixed32 fields', () {
    final reader = _read([
      0x09, 1, 2, 3, 4, 5, 6, 7, 8, // 1: fixed64
      0x15, 1, 2, 3, 4, // 2: fixed32
      0x18, 0x09, // 3: 9
    ]);
    expect(reader.varint(3), 9);
  });

  test('an empty message has no fields', () {
    expect(_read([]).varint(1), isNull);
  });

  test('malformed input is a FormatException', () {
    for (final bytes in [
      [0x08], // value missing
      [0x08, 0x80], // truncated varint
      [0x08, ...List.filled(10, 0x80), 0x01], // varint longer than 10 bytes
      [0x0a, 0x05, 0x01], // length past the end
      [0x0a, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01],
      [0x09, 1, 2, 3], // truncated fixed64
      [0x15, 1], // truncated fixed32
      [0x00, 0x01], // field number 0
      [0x0b], // start group
    ]) {
      expect(() => _read(bytes), throwsFormatException, reason: '$bytes');
    }
  });

  test('invalid UTF-8 in a string is a FormatException', () {
    expect(() => _read([0x0a, 0x01, 0xff]).string(1), throwsFormatException);
  });
}
