import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:sharedinbox/core/encrypted_objects/wire.dart'
    show b64url, idLength;

// Stable ids of imported cards and media (#1383): base64url of the first
// 16 bytes of a SHA-256, the shape of `newItemId()`. Importing the same file
// again gives the same ids, so it updates instead of duplicating.

/// The cardId of card [ord] of the Anki note [noteGuid].
String ankiCardId(String noteGuid, int ord) =>
    _id([utf8.encode('anki-card\u0000$noteGuid\u0000$ord')]);

/// The cardId of a CSV row: its deck and front.
String csvCardId(String deck, String front) =>
    _id([utf8.encode('csv-card\u0000$deck\u0000$front')]);

/// The itemId of a media blob, from its content: the same image is stored
/// once.
String mediaBlobId(Uint8List bytes) => _id([utf8.encode('blob\u0000'), bytes]);

String _id(List<List<int>> chunks) {
  final out = _DigestSink();
  final input = sha256.startChunkedConversion(out);
  chunks.forEach(input.add);
  input.close();
  return b64url(out.digest.bytes.sublist(0, idLength));
}

class _DigestSink implements Sink<Digest> {
  late Digest digest;

  @override
  void add(Digest data) => digest = data;

  @override
  void close() {}
}
