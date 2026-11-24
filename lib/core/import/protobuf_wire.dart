import 'dart:convert';
import 'dart:typed_data';

/// The fields of one protobuf message in the wire format (#1384), read
/// without generated code: enough for the few scalar fields of an Anki
/// `.apkg` (`meta`, the `media` entries, note type and template configs).
/// Unknown fields are skipped. Throws [FormatException] for a truncated
/// message, a varint longer than 10 bytes, a length past the end, a field
/// number 0 and the deprecated group wire types.
class ProtoReader {
  ProtoReader(Uint8List bytes) {
    var at = 0;
    while (at < bytes.length) {
      final (tag, afterTag) = _varint(bytes, at);
      at = afterTag;
      final field = tag >> 3;
      if (field == 0) throw const FormatException('protobuf: field number 0');
      switch (tag & 7) {
        case 0:
          final (value, next) = _varint(bytes, at);
          _fields.putIfAbsent(field, () => []).add(value);
          at = next;
        case 1:
          at = _skip(bytes, at, 8);
        case 2:
          final (length, start) = _varint(bytes, at);
          if (length < 0 || length > bytes.length - start) {
            throw const FormatException('protobuf: length past the end');
          }
          at = start + length;
          _fields
              .putIfAbsent(field, () => [])
              .add(Uint8List.sublistView(bytes, start, at));
        case 5:
          at = _skip(bytes, at, 4);
        default:
          throw FormatException('protobuf: wire type ${tag & 7}');
      }
    }
  }

  final _fields = <int, List<Object>>{};

  /// The last varint of [field], or null.
  int? varint(int field) {
    final values = _fields[field]?.whereType<int>();
    return values == null || values.isEmpty ? null : values.last;
  }

  /// The last length-delimited value of [field], or null.
  Uint8List? bytes(int field) {
    final values = _fields[field]?.whereType<Uint8List>();
    return values == null || values.isEmpty ? null : values.last;
  }

  /// The last length-delimited value of [field] as UTF-8, or null.
  String? string(int field) {
    final value = bytes(field);
    return value == null ? null : utf8.decode(value);
  }

  /// Every length-delimited value of [field] (a repeated message), in order.
  List<Uint8List> repeated(int field) =>
      [...?_fields[field]?.whereType<Uint8List>()];

  static (int, int) _varint(Uint8List bytes, int at) {
    var value = 0;
    for (var i = 0; i < 10; i++) {
      if (at + i >= bytes.length) {
        throw const FormatException('protobuf: truncated varint');
      }
      final b = bytes[at + i];
      value |= (b & 0x7f) << (7 * i);
      if (b < 0x80) return (value, at + i + 1);
    }
    throw const FormatException('protobuf: varint longer than 10 bytes');
  }

  static int _skip(Uint8List bytes, int at, int length) {
    if (length > bytes.length - at) {
      throw const FormatException('protobuf: truncated fixed field');
    }
    return at + length;
  }
}
