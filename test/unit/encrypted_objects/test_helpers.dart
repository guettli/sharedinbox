import 'dart:convert';
import 'dart:typed_data';

import 'package:sharedinbox/core/encrypted_objects/device_identity.dart';
import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';

/// `start, start+1, …` as [length] bytes.
Uint8List seqBytes(int start, int length) =>
    Uint8List.fromList([for (var i = 0; i < length; i++) (start + i) & 0xff]);

/// Fixed account key shared by the unit tests.
final testAccountKey = AccountKey(seqBytes(0xa0, 16), seqBytes(0x00, 32));

/// Fixed non-personal collection key shared by the unit tests.
final testDeckKey =
    CollectionKey('deck-1', seqBytes(0xb0, 16), seqBytes(0x20, 32));

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

/// In-memory [DeviceIdentityDb].
class FakeDeviceIdentityDb implements DeviceIdentityDb {
  final records = <String, DeviceIdentity>{};

  @override
  Future<DeviceIdentity?> load(String accountId) async => records[accountId];

  @override
  Future<void> save(String accountId, DeviceIdentity identity) async =>
      records[accountId] = identity;
}

/// An HLC of [deviceId] at [wallMs].
Hlc hlcAt(int wallMs, [String deviceId = 'devA', int counter = 0]) =>
    Hlc(wallMs, counter, deviceId);

/// A v1 `entry` object of the deck collection with a markdown body.
InnerObject testObject({
  String itemId = 'item-1',
  String collectionId = 'deck-1',
  Hlc? versionId,
  List<Hlc> parents = const [],
  bool deleted = false,
  int v = objectHeadVersion,
  Map<String, Object?> extra = const {'title': 'Hello'},
  String body = '# Hello',
}) =>
    InnerObject(
      head: ObjectHead(
        v: v,
        itemId: itemId,
        collectionId: collectionId,
        versionId: versionId ?? hlcAt(1000),
        parents: parents,
        deleted: deleted,
        kind: 'entry',
        extra: extra,
      ),
      parts: [
        ObjectPart(
          contentType: 'text/markdown; charset=utf-8',
          bytes: Uint8List.fromList(utf8.encode(body)),
        ),
      ],
    );
