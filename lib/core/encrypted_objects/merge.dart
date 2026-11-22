import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';

/// Merge rules for document objects (`ENCRYPTED-OBJECTS.md` 5.4, 5.6).

/// One version of an item, as far as the merge needs it.
class ObjectVersion {
  ObjectVersion({
    required this.versionId,
    List<Hlc> parents = const [],
    this.deleted = false,
    this.parseable = true,
    required this.contentDigest,
    this.ref,
  }) : parents = List.unmodifiable(parents);

  /// The version of [object]; [ref] is an opaque caller handle (e.g. a row
  /// or a UID).
  static Future<ObjectVersion> of(InnerObject object, {Object? ref}) async =>
      ObjectVersion(
        versionId: object.head.versionId,
        parents: object.head.parents,
        deleted: object.head.deleted,
        parseable: object.head.isParseable,
        contentDigest: await contentDigestOf(object),
        ref: ref,
      );

  final Hlc versionId;
  final List<Hlc> parents;
  final bool deleted;
  final bool parseable;

  /// [contentDigestOf] the object.
  final String contentDigest;
  final Object? ref;
}

/// SHA-256 over `u32be(len) ‖ bytes` of the canonical JSON of the head without
/// `versionId` and `parents`, then of each part's content type, Content-ID
/// (empty if none) and bytes. Equal digests = identical content. Base64url.
Future<String> contentDigestOf(InnerObject object) async {
  final head = {...object.head.toJson()}
    ..remove('versionId')
    ..remove('parents');
  final out = BytesBuilder(copy: false);
  void add(List<int> bytes) {
    out
      ..add((ByteData(4)..setUint32(0, bytes.length)).buffer.asUint8List())
      ..add(bytes);
  }

  add(utf8.encode(canonicalJson(head)));
  for (final p in object.parts) {
    add(utf8.encode(p.contentType));
    add(utf8.encode(p.contentId ?? ''));
    add(p.bytes);
  }
  final hash = await Sha256().hash(out.toBytes());
  return b64url(hash.bytes);
}

/// Per item: `deviceId → max HLC seen` (the rollback guard).
typedef VersionVector = Map<String, Hlc>;

enum MergeState {
  /// One logical head, not a tombstone.
  live,

  /// Every head is a tombstone.
  deleted,

  /// Several heads with different content.
  conflict,

  /// No accepted version at all.
  empty,
}

class MergeResult {
  MergeResult._({
    required this.state,
    required this.display,
    required this.heads,
    required this.distinctHeads,
    required this.superseded,
    required this.ignored,
    required this.vv,
  });

  final MergeState state;

  /// The head with the newest HLC, or null if [state] is `empty`.
  final ObjectVersion? display;

  /// Every head, oldest first. Never silently dropped.
  final List<ObjectVersion> heads;

  /// One head per distinct content (the newest of each), oldest first —
  /// the entries of the conflict view.
  final List<ObjectVersion> distinctHeads;

  /// Versions some other version names as a parent: eligible for a
  /// foreground expunge.
  final List<ObjectVersion> superseded;

  /// Replays (`hlc ≤ vv[deviceId]`), not accepted.
  final List<ObjectVersion> ignored;

  /// The updated version vector.
  final VersionVector vv;

  /// False if any head has a `v` this reader cannot parse.
  bool get editable => heads.every((h) => h.parseable);

  /// `parents` of the next write: all heads, so it collapses them.
  List<Hlc> get parentsForNextWrite => [for (final h in heads) h.versionId];
}

/// Merges [incoming] versions of one item into the [known] (already accepted)
/// ones. Pure: [vv] is not modified.
///
/// Incoming versions are taken in ascending HLC order: one named as a parent
/// of any version is superseded; otherwise one with `hlc ≤ vv[deviceId]` is a
/// replay and ignored; otherwise it is accepted. Heads are the accepted
/// versions nobody names as a parent; heads with the same [contentDigest]
/// are one logical head.
MergeResult mergeItem({
  required Iterable<ObjectVersion> known,
  required Iterable<ObjectVersion> incoming,
  required VersionVector vv,
}) {
  final byId = <Hlc, ObjectVersion>{};
  for (final v in known) {
    byId.putIfAbsent(v.versionId, () => v);
  }
  final knownIds = byId.keys.toSet();
  for (final v in incoming) {
    byId.putIfAbsent(v.versionId, () => v);
  }
  final named = {for (final v in byId.values) ...v.parents};
  final nextVv = {...vv};
  final accepted = [for (final id in knownIds) byId[id]!];
  final superseded = <ObjectVersion>[];
  final ignored = <ObjectVersion>[];
  final fresh = byId.values
      .where((v) => !knownIds.contains(v.versionId))
      .toList()
    ..sort((a, b) => a.versionId.compareTo(b.versionId));
  for (final v in fresh) {
    final device = v.versionId.deviceId;
    final seen = nextVv[device];
    if (!named.contains(v.versionId) && seen != null && v.versionId <= seen) {
      ignored.add(v);
      continue;
    }
    if (seen == null || v.versionId > seen) nextVv[device] = v.versionId;
    accepted.add(v);
  }
  accepted.sort((a, b) => a.versionId.compareTo(b.versionId));
  final heads = <ObjectVersion>[];
  for (final v in accepted) {
    if (named.contains(v.versionId)) {
      superseded.add(v);
      continue;
    }
    heads.add(v);
  }
  final byDigest = <String, ObjectVersion>{};
  for (final h in heads) {
    byDigest[h.contentDigest] = h;
  }
  final distinct = byDigest.values.toList()
    ..sort((a, b) => a.versionId.compareTo(b.versionId));
  return MergeResult._(
    state: _state(heads, distinct.length),
    display: heads.isEmpty ? null : heads.last,
    heads: List.unmodifiable(heads),
    distinctHeads: List.unmodifiable(distinct),
    superseded: List.unmodifiable(superseded),
    ignored: List.unmodifiable(ignored),
    vv: Map.unmodifiable(nextVv),
  );
}

MergeState _state(List<ObjectVersion> heads, int distinct) {
  if (heads.isEmpty) return MergeState.empty;
  if (distinct > 1) return MergeState.conflict;
  if (heads.every((h) => h.deleted)) return MergeState.deleted;
  return MergeState.live;
}

/// Thrown when writing over a head this reader cannot parse (5.2).
class NotEditableException implements Exception {
  const NotEditableException(this.message);

  final String message;

  @override
  String toString() => 'NotEditableException: $message';
}

/// A tombstone over [base] (one of the heads of [merge]) with
/// `parents = all heads`. Kind and unknown fields are kept, parts dropped.
InnerObject tombstone({
  required InnerObject base,
  required MergeResult merge,
  required HlcClock clock,
}) =>
    _next(base, merge, clock, deleted: true, parts: const []);

/// An edit of [base] with `parents = all heads`; [fields] are set on top of
/// the kind and unknown fields, [parts] replace the content parts if given.
/// Also resolves a conflict and resurrects a tombstone.
InnerObject edit({
  required InnerObject base,
  required MergeResult merge,
  required HlcClock clock,
  Map<String, Object?> fields = const {},
  List<ObjectPart>? parts,
}) =>
    _next(
      base,
      merge,
      clock,
      deleted: false,
      parts: parts ?? base.parts,
      fields: fields,
    );

InnerObject _next(
  InnerObject base,
  MergeResult merge,
  HlcClock clock, {
  required bool deleted,
  required List<ObjectPart> parts,
  Map<String, Object?> fields = const {},
}) {
  if (!base.head.isParseable || !merge.editable) {
    throw const NotEditableException('a head needs a newer app');
  }
  final parents = merge.parentsForNextWrite;
  for (final p in parents) {
    clock.receive(p);
  }
  final head = base.head;
  return InnerObject(
    head: ObjectHead(
      itemId: head.itemId,
      collectionId: head.collectionId,
      versionId: clock.send(),
      parents: parents,
      deleted: deleted,
      kind: head.kind,
      extra: {...head.extra, ...fields},
    ),
    parts: parts,
  );
}
