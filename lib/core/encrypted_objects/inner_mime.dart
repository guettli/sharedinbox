import 'dart:convert';
import 'dart:typed_data';

import 'package:sharedinbox/core/encrypted_objects/envelope.dart';
import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';

/// Inner MIME of an object (`ENCRYPTED-OBJECTS.md` 5.2, 5.6): a
/// `multipart/related` whose first part is the JSON head.

/// The head version this reader can parse (and therefore edit).
const objectHeadVersion = 1;

/// The JSON head. [itemId], [collectionId], [versionId], [parents] and
/// [deleted] are the `v`-independent prefix every version keeps; everything
/// else (kind fields and unknown fields) sits in [extra] and is written back
/// verbatim.
class ObjectHead {
  ObjectHead({
    this.v = objectHeadVersion,
    required this.itemId,
    required this.collectionId,
    required this.versionId,
    List<Hlc> parents = const [],
    this.deleted = false,
    this.kind,
    Map<String, Object?> extra = const {},
  })  : parents = List.unmodifiable(parents),
        extra = Map.unmodifiable(extra) {
    if (extra.keys.any(_known.contains)) {
      throw ArgumentError.value(extra, 'extra', 'overrides a known field');
    }
  }

  /// Reads the prefix of a head of any `v`. Throws [FormatException] only if
  /// the prefix itself is missing or malformed.
  factory ObjectHead.fromJson(Map<String, Object?> json) {
    final v = json['v'];
    if (v is! int) throw const FormatException('missing head v');
    final rawParents = json['parents'];
    if (rawParents is! List) throw const FormatException('missing parents');
    final deleted = json['deleted'] ?? false;
    if (deleted is! bool) throw const FormatException('deleted is not a bool');
    final kind = json['kind'];
    if (kind != null && kind is! String) {
      throw const FormatException('kind is not a string');
    }
    return ObjectHead(
      v: v,
      itemId: readStringField(json, 'itemId'),
      collectionId: readStringField(json, 'collectionId'),
      versionId: Hlc.parse(readStringField(json, 'versionId')),
      parents: [
        for (final p in rawParents)
          if (p is String)
            Hlc.parse(p)
          else
            throw const FormatException('parent is not a string'),
      ],
      deleted: deleted,
      kind: kind as String?,
      extra: unknownFields(json, _known),
    );
  }

  static const _known = {
    'v',
    'itemId',
    'collectionId',
    'versionId',
    'parents',
    'deleted',
    'kind',
  };

  final int v;
  final String itemId;
  final String collectionId;
  final Hlc versionId;
  final List<Hlc> parents;
  final bool deleted;
  final String? kind;

  /// Kind fields and unknown fields.
  final Map<String, Object?> extra;

  /// False for a head of a newer `v`: shown as "needs a newer app" and never
  /// edited by this reader.
  bool get isParseable => v == objectHeadVersion;

  Map<String, Object?> toJson() => {
        'v': v,
        'itemId': itemId,
        'collectionId': collectionId,
        'versionId': versionId.encode(),
        'parents': [for (final p in parents) p.encode()],
        if (deleted) 'deleted': true,
        if (kind != null) 'kind': kind,
        ...extra,
      };
}

/// A content part (markdown body, `cid:` image, or an unknown part kept as
/// is).
class ObjectPart {
  ObjectPart({
    required this.contentType,
    this.contentId,
    Map<String, String> extraHeaders = const {},
    required this.bytes,
  }) : extraHeaders = Map.unmodifiable(extraHeaders);

  final String contentType;

  /// Without the angle brackets.
  final String? contentId;

  /// Other part headers, by lowercase name.
  final Map<String, String> extraHeaders;
  final Uint8List bytes;
}

class InnerObject {
  InnerObject({required this.head, List<ObjectPart> parts = const []})
      : parts = List.unmodifiable(parts);

  final ObjectHead head;
  final List<ObjectPart> parts;
}

const _crlf = '\r\n';
const _headContentType = 'application/json; charset=utf-8';

/// Writes [object] as `multipart/related` with CRLF line endings and
/// `Content-Transfer-Encoding: binary` parts (they are inside the
/// ciphertext). The boundary is `si-` + base64url of 12 random bytes.
Uint8List buildInnerMime(
  InnerObject object, {
  RandomBytes random = secureRandomBytes,
}) {
  final head = utf8.encode(jsonEncode(object.head.toJson()));
  final bodies = [head, for (final p in object.parts) p.bytes];
  var boundary = 'si-${b64url(random(12))}';
  while (bodies.any((b) => _indexOf(b, ascii.encode(boundary), 0) >= 0)) {
    boundary = 'si-${b64url(random(12))}';
  }
  final out = BytesBuilder(copy: false)
    ..add(
      ascii.encode(
        'Content-Type: multipart/related; boundary="$boundary"; '
        'type="application/json"$_crlf'
        'MIME-Version: 1.0$_crlf$_crlf',
      ),
    );
  void addPart(Map<String, String> headers, List<int> bytes) {
    out.add(ascii.encode('--$boundary$_crlf'));
    for (final h in headers.entries) {
      out.add(utf8.encode('${h.key}: ${h.value}$_crlf'));
    }
    out
      ..add(ascii.encode('Content-Transfer-Encoding: binary$_crlf$_crlf'))
      ..add(bytes)
      ..add(ascii.encode(_crlf));
  }

  addPart({'Content-Type': _headContentType}, head);
  for (final p in object.parts) {
    final headers = {
      'Content-Type': p.contentType,
      if (p.contentId != null) 'Content-ID': '<${p.contentId}>',
      for (final h in p.extraHeaders.entries)
        if (!_partHeaders.contains(h.key)) h.key: h.value,
    };
    addPart(headers, p.bytes);
  }
  out.add(ascii.encode('--$boundary--$_crlf'));
  return out.toBytes();
}

const _partHeaders = {
  'content-type',
  'content-id',
  'content-transfer-encoding',
};

/// Parses inner MIME bytes. Accepts `binary`, `8bit`, `7bit` and `base64`
/// parts. Unknown kinds and unknown parts are kept.
///
/// Throws [FormatException].
InnerObject parseInnerMime(Uint8List bytes) {
  final top = _splitHeaders(bytes, 0);
  final contentType = top.headers['content-type'];
  if (contentType == null) {
    throw const FormatException('missing Content-Type');
  }
  final (mediaType, params) = _parseContentType(contentType);
  if (mediaType != 'multipart/related') {
    throw const FormatException('not multipart/related');
  }
  final boundary = params['boundary'];
  if (boundary == null || boundary.isEmpty) {
    throw const FormatException('missing boundary');
  }
  final parts = _splitMultipart(bytes, top.bodyStart, boundary);
  if (parts.isEmpty) throw const FormatException('no head part');
  final headPart = parts.first;
  if (_parseContentType(headPart.contentType).$1 != 'application/json') {
    throw const FormatException('first part is not application/json');
  }
  return InnerObject(
    head: ObjectHead.fromJson(decodeJsonObject(headPart.bytes)),
    parts: parts.skip(1).toList(),
  );
}

/// Builds the inner MIME of [object] and seals it under [key]. Returns the
/// item HMAC (for `X-SharedInbox-Item`) and the envelope blob.
///
/// Throws [EnvelopeException] if the head's `collectionId` is not the one of
/// [key], or [ObjectTooLargeException].
Future<({Uint8List itemHmac, Uint8List blob})> sealObject({
  required CollectionKey key,
  required InnerObject object,
  RandomBytes random = secureRandomBytes,
  int maxBytes = maxEnvelopeBytes,
}) async {
  if (object.head.collectionId != key.collectionId) {
    throw const EnvelopeException(
      EnvelopeFailure.collectionMismatch,
      'head collectionId is not the collection of the key',
    );
  }
  final hmac = await itemHmac(key, object.head.itemId);
  final blob = await sealEnvelope(
    key: key,
    itemHmac: hmac,
    innerMime: buildInnerMime(object, random: random),
    random: random,
    maxBytes: maxBytes,
  );
  return (itemHmac: hmac, blob: blob);
}

/// Opens an envelope and parses its inner MIME. Rejects an object whose
/// itemId does not match the item header (`itemMismatch`) and one whose head
/// `collectionId` differs from the collection of its `keyId`
/// (`collectionMismatch`, 4.1).
///
/// Throws [EnvelopeException] or [FormatException].
Future<({CollectionKey key, InnerObject object})> openObject({
  required Uint8List blob,
  required Uint8List itemHmacFromHeader,
  required CollectionKey? Function(Uint8List keyId) keyLookup,
  int maxBytes = maxEnvelopeBytes,
}) async {
  final opened = await openEnvelope(
    blob: blob,
    itemHmacFromHeader: itemHmacFromHeader,
    keyLookup: keyLookup,
    maxBytes: maxBytes,
  );
  final object = parseInnerMime(opened.innerMime);
  final expected = await itemHmac(opened.key, object.head.itemId);
  if (!constantTimeEquals(expected, itemHmacFromHeader)) {
    throw const EnvelopeException(
      EnvelopeFailure.itemMismatch,
      'itemId does not match X-SharedInbox-Item',
    );
  }
  if (object.head.collectionId != opened.key.collectionId) {
    throw const EnvelopeException(
      EnvelopeFailure.collectionMismatch,
      'head collectionId is not the collection of the keyId',
    );
  }
  return (key: opened.key, object: object);
}

// ── MIME parsing helpers ────────────────────────────────────────────────────

final _crlfBytes = ascii.encode(_crlf);
final _blankLine = ascii.encode('$_crlf$_crlf');

int _indexOf(List<int> haystack, List<int> needle, int start) {
  outer:
  for (var i = start; i <= haystack.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

/// Header block starting at [start]: headers by lowercase name (unfolded)
/// and the offset of the body.
({Map<String, String> headers, int bodyStart}) _splitHeaders(
  Uint8List bytes,
  int start,
) {
  // A part without headers starts with the blank line right away.
  if (start == bytes.length) return (headers: const {}, bodyStart: start);
  if (_startsWith(bytes, start, _crlfBytes)) {
    return (headers: const {}, bodyStart: start + 2);
  }
  final end = _indexOf(bytes, _blankLine, start);
  if (end < 0) throw const FormatException('unterminated header block');
  final text = utf8.decode(bytes.sublist(start, end), allowMalformed: true);
  final lines = <String>[];
  for (final line in text.split(_crlf)) {
    if (lines.isNotEmpty && (line.startsWith(' ') || line.startsWith('\t'))) {
      lines.last = '${lines.last} ${line.trim()}';
      continue;
    }
    lines.add(line);
  }
  final headers = <String, String>{};
  for (final line in lines) {
    final colon = line.indexOf(':');
    if (colon <= 0) throw FormatException('malformed header', line);
    headers[line.substring(0, colon).trim().toLowerCase()] =
        line.substring(colon + 1).trim();
  }
  return (headers: headers, bodyStart: end + 4);
}

/// `type/subtype` (lowercase) and the parameters of a Content-Type value.
(String, Map<String, String>) _parseContentType(String value) {
  final segments = value.split(';');
  final params = <String, String>{};
  for (final s in segments.skip(1)) {
    final eq = s.indexOf('=');
    if (eq <= 0) continue;
    var v = s.substring(eq + 1).trim();
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
      v = v.substring(1, v.length - 1);
    }
    params[s.substring(0, eq).trim().toLowerCase()] = v;
  }
  return (segments.first.trim().toLowerCase(), params);
}

List<ObjectPart> _splitMultipart(Uint8List bytes, int start, String boundary) {
  final dashBoundary = ascii.encode('--$boundary');
  final delimiter = ascii.encode('$_crlf--$boundary');
  // The first delimiter may open the body without a preceding CRLF.
  var at = start + dashBoundary.length;
  if (!_startsWith(bytes, start, dashBoundary)) {
    final first = _indexOf(bytes, delimiter, start);
    if (first < 0) throw const FormatException('missing first boundary');
    at = first + delimiter.length;
  }
  final parts = <ObjectPart>[];
  while (!_startsWith(bytes, at, ascii.encode('--'))) {
    final lineEnd = _indexOf(bytes, _crlfBytes, at);
    if (lineEnd < 0) throw const FormatException('unterminated boundary');
    final partStart = lineEnd + 2;
    final next = _indexOf(bytes, delimiter, partStart);
    if (next < 0) throw const FormatException('missing close boundary');
    parts.add(_parsePart(bytes, partStart, next));
    at = next + delimiter.length;
  }
  return parts;
}

bool _startsWith(Uint8List bytes, int at, List<int> prefix) {
  if (at + prefix.length > bytes.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[at + i] != prefix[i]) return false;
  }
  return true;
}

ObjectPart _parsePart(Uint8List bytes, int start, int end) {
  final split = _splitHeaders(Uint8List.sublistView(bytes, 0, end), start);
  final headers = split.headers;
  final raw = bytes.sublist(split.bodyStart, end);
  final cte = (headers['content-transfer-encoding'] ?? 'binary').toLowerCase();
  final Uint8List body;
  switch (cte) {
    case 'binary' || '8bit' || '7bit':
      body = raw;
    case 'base64':
      try {
        body = base64.decode(ascii.decode(raw).replaceAll(RegExp(r'\s'), ''));
      } on FormatException {
        throw const FormatException('bad base64 part');
      }
    default:
      throw FormatException('unsupported transfer encoding', cte);
  }
  final cid = headers['content-id'];
  return ObjectPart(
    contentType: headers['content-type'] ?? 'text/plain',
    contentId: cid?.replaceAll(RegExp(r'^<|>$'), ''),
    extraHeaders: {
      for (final h in headers.entries)
        if (!_partHeaders.contains(h.key)) h.key: h.value,
    },
    bytes: body,
  );
}
