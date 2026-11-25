import 'dart:convert';
import 'dart:typed_data';

import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';

/// Collection-key mail payload (`ENCRYPTED-OBJECTS.md` 4.4, 4.6).
///
/// No separate MAC: the wrap AAD already binds `accountKeyId`,
/// `collectionId`, `keyId` and the wrap type.

const collectionKeyMailKind = 'collection-key';

class CollectionKeyMail {
  factory CollectionKeyMail({
    required Uint8List accountKeyId,
    required String collectionId,
    required Uint8List keyId,
    required List<Map<String, Object?>> wraps,
    Map<String, Object?> extra = const {},
  }) {
    if (extra.keys.any(_known.contains)) {
      throw ArgumentError.value(extra, 'extra', 'overrides a known field');
    }
    final json = {
      'v': 1,
      'kind': collectionKeyMailKind,
      'accountKeyId': b64url(accountKeyId),
      'collectionId': collectionId,
      'keyId': b64url(keyId),
      'wraps': wraps,
      ...extra,
    };
    return CollectionKeyMail._(
      accountKeyId: accountKeyId,
      collectionId: collectionId,
      keyId: keyId,
      wraps: wraps,
      extra: extra,
      bytes: Uint8List.fromList(utf8.encode(jsonEncode(json))),
    );
  }

  CollectionKeyMail._({
    required this.accountKeyId,
    required this.collectionId,
    required this.keyId,
    required List<Map<String, Object?>> wraps,
    required Map<String, Object?> extra,
    required this.bytes,
  })  : wraps = List.unmodifiable(wraps.map(Map<String, Object?>.unmodifiable)),
        extra = Map.unmodifiable(extra);

  /// Parses stored bytes. Throws [FormatException] if they are not a v1
  /// collection-key payload.
  factory CollectionKeyMail.parse(Uint8List bytes) {
    final json = decodeJsonObject(bytes);
    if (json['v'] != 1) {
      throw const FormatException('unsupported collection key mail v');
    }
    if (json['kind'] != collectionKeyMailKind) {
      throw const FormatException('not a collection-key mail');
    }
    final rawWraps = json['wraps'];
    if (rawWraps is! List) throw const FormatException('missing wraps');
    final wraps = [
      for (final w in rawWraps)
        if (w is Map<String, Object?> && w['type'] is String)
          w
        else
          throw const FormatException('wrap without a type'),
    ];
    return CollectionKeyMail._(
      accountKeyId: readBytesField(json, 'accountKeyId', idLength),
      collectionId: readAadStringField(json, 'collectionId'),
      keyId: readBytesField(json, 'keyId', idLength),
      wraps: wraps,
      extra: unknownFields(json, _known),
      bytes: Uint8List.fromList(bytes),
    );
  }

  static const _known = {
    'v',
    'kind',
    'accountKeyId',
    'collectionId',
    'keyId',
    'wraps',
  };

  final Uint8List accountKeyId;
  final String collectionId;
  final Uint8List keyId;

  /// Every wrap as JSON. v1 writes one `{type: account}` wrap; other types
  /// (e.g. a future `x25519`) are preserved and skipped by [unwrapWith].
  final List<Map<String, Object?>> wraps;

  /// Unknown top-level fields; preserved on rewrite.
  final Map<String, Object?> extra;

  /// The bytes as stored, or their JSON encoding for a new payload.
  final Uint8List bytes;

  /// A new mail for [collectionKey] with one account wrap.
  static Future<CollectionKeyMail> create(
    AccountKey accountKey,
    CollectionKey collectionKey, {
    RandomBytes random = secureRandomBytes,
  }) async {
    final wrap = await wrapCollectionKey(
      accountKey,
      collectionKey,
      random: random,
    );
    return CollectionKeyMail(
      accountKeyId: accountKey.accountKeyId,
      collectionId: collectionKey.collectionId,
      keyId: collectionKey.keyId,
      wraps: [wrap.toJson()],
    );
  }

  /// Unwraps the collection key via its `{type: account}` wrap. Throws
  /// [KeyUnwrapException] for another account, a missing account wrap or a
  /// relabelled mail.
  Future<CollectionKey> unwrapWith(AccountKey accountKey) async {
    if (!constantTimeEquals(accountKeyId, accountKey.accountKeyId)) {
      throw const KeyUnwrapException('mail belongs to another account key');
    }
    for (final w in wraps) {
      if (w['type'] != accountWrapType) continue;
      final CollectionKeyWrap wrap;
      try {
        wrap = CollectionKeyWrap.fromJson(w);
      } on FormatException {
        throw const KeyUnwrapException('malformed account wrap');
      }
      return unwrapCollectionKey(
        accountKey,
        collectionId: collectionId,
        keyId: keyId,
        wrap: wrap,
      );
    }
    throw const KeyUnwrapException('no account wrap');
  }
}
