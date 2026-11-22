import 'dart:convert';
import 'dart:typed_data';

import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/encrypted_objects/merge.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  final a = hlcAt(1000);
  final b = hlcAt(2000);
  final c = hlcAt(3000, 'devC');
  final d = hlcAt(4000, 'devB');

  Future<ObjectVersion> version(
    Hlc id, {
    List<Hlc> parents = const [],
    bool deleted = false,
    String body = 'x',
    int v = objectHeadVersion,
  }) =>
      ObjectVersion.of(
        testObject(
          versionId: id,
          parents: parents,
          deleted: deleted,
          body: body,
          v: v,
        ),
        ref: id.encode(),
      );

  List<Hlc> ids(Iterable<ObjectVersion> vs) =>
      [for (final v in vs) v.versionId];

  test('A←B←D plus an offline C(parent A) is a conflict of {C, D}', () async {
    final result = mergeItem(
      known: const [],
      incoming: [
        await version(d, parents: [b], body: 'd'),
        await version(a, body: 'a'),
        await version(c, parents: [a], body: 'c'),
        await version(b, parents: [a], body: 'b'),
      ],
      vv: const {},
    );
    expect(result.state, MergeState.conflict);
    expect(ids(result.heads), [c, d]);
    expect(ids(result.distinctHeads), [c, d]);
    expect(result.display!.versionId, d);
    expect(result.display!.ref, d.encode());
    expect(ids(result.superseded), [a, b]);
    expect(result.ignored, isEmpty);
    expect(result.parentsForNextWrite, [c, d]);
    expect(result.vv, {'devA': b, 'devB': d, 'devC': c});
    expect(result.editable, isTrue);
  });

  test('a crash leftover B next to D(parent B) is superseded', () async {
    final result = mergeItem(
      known: [await version(b, parents: [a])],
      incoming: [await version(d, parents: [b], body: 'd')],
      vv: {'devA': b},
    );
    expect(result.state, MergeState.live);
    expect(ids(result.heads), [d]);
    expect(ids(result.superseded), [b]);
  });

  test('a replayed old version with hlc ≤ vv is ignored', () async {
    final vv = {'devA': b, 'devB': d};
    final known = [await version(d, parents: [b], body: 'd')];
    final result = mergeItem(
      known: known,
      incoming: [await version(a, body: 'a'), ...known],
      vv: vv,
    );
    expect(result.state, MergeState.live);
    expect(ids(result.ignored), [a]);
    expect(ids(result.heads), [d]);
    expect(result.vv, vv);
    expect(vv, {'devA': b, 'devB': d}, reason: 'input vv is not modified');
  });

  test('edit vs delete is a normal conflict', () async {
    final result = mergeItem(
      known: [await version(a)],
      incoming: [
        await version(b, parents: [a], body: 'edited'),
        await version(d, parents: [a], deleted: true),
      ],
      vv: const {},
    );
    expect(result.state, MergeState.conflict);
    expect(ids(result.heads), [b, d]);
    expect(ids(result.superseded), [a]);
  });

  test('heads with identical content are one logical head', () async {
    final result = mergeItem(
      known: [await version(a)],
      incoming: [
        await version(b, parents: [a], body: 'same'),
        await version(d, parents: [a], body: 'same'),
      ],
      vv: const {},
    );
    expect(result.state, MergeState.live);
    expect(ids(result.heads), [b, d]);
    expect(ids(result.distinctHeads), [d]);
    expect(result.parentsForNextWrite, [b, d]);
  });

  test('a single tombstone is deleted', () async {
    final result = mergeItem(
      known: [await version(a)],
      incoming: [await version(b, parents: [a], deleted: true)],
      vv: const {},
    );
    expect(result.state, MergeState.deleted);
    expect(ids(result.heads), [b]);
  });

  test('no accepted version is empty', () {
    final result = mergeItem(known: const [], incoming: const [], vv: const {});
    expect(result.state, MergeState.empty);
    expect(result.display, isNull);
  });

  test('contentDigest ignores versionId and parents only', () async {
    final x = await version(a, body: 'same');
    final y = await version(d, parents: [a], body: 'same');
    final z = await version(d, parents: [a], body: 'other');
    final t = await version(d, parents: [a], body: 'same', deleted: true);
    expect(x.contentDigest, y.contentDigest);
    expect(x.contentDigest, isNot(z.contentDigest));
    expect(x.contentDigest, isNot(t.contentDigest));
  });

  group('writes', () {
    final base = testObject(
      versionId: b,
      parents: [a],
      extra: {'title': 'T', 'future': 1},
    );

    test('edit collapses all heads and keeps unknown fields', () async {
      final result = mergeItem(
        known: [await version(a)],
        incoming: [
          await version(b, parents: [a], body: 'same'),
          await version(d, parents: [a], body: 'same'),
        ],
        vv: const {},
      );
      final clock = HlcClock('devA', nowMs: () => 100);
      final next = edit(
        base: base,
        merge: result,
        clock: clock,
        fields: {'title': 'New'},
        parts: [
          ObjectPart(
            contentType: 'text/markdown',
            bytes: Uint8List.fromList(utf8.encode('new')),
          ),
        ],
      );
      expect(next.head.parents, [b, d]);
      expect(next.head.versionId > d, isTrue);
      expect(next.head.versionId.deviceId, 'devA');
      expect(next.head.extra, {'title': 'New', 'future': 1});
      expect(next.head.kind, 'entry');
      expect(next.head.deleted, isFalse);
      expect(utf8.decode(next.parts.single.bytes), 'new');
      final kept = edit(base: base, merge: result, clock: clock);
      expect(kept.parts.single.bytes, base.parts.single.bytes);
    });

    test('tombstone drops parts and keeps fields', () async {
      final result = mergeItem(
        known: const [],
        incoming: [await version(b, parents: [a])],
        vv: const {},
      );
      final next = tombstone(
        base: base,
        merge: result,
        clock: HlcClock('devA', nowMs: () => 5000),
      );
      expect(next.head.deleted, isTrue);
      expect(next.head.parents, [b]);
      expect(next.head.versionId, hlcAt(5000));
      expect(next.parts, isEmpty);
      expect(next.head.extra, base.head.extra);
    });

    test('an unparseable head is not editable', () async {
      final result = mergeItem(
        known: [await version(a)],
        incoming: [await version(b, parents: [a], v: 2)],
        vv: const {},
      );
      expect(result.editable, isFalse);
      final clock = HlcClock('devA');
      expect(
        () => edit(base: base, merge: result, clock: clock),
        throwsA(isA<NotEditableException>()),
      );
      expect(
        () => tombstone(base: base, merge: result, clock: clock),
        throwsA(isA<NotEditableException>()),
      );
      expect(
        const NotEditableException('x').toString(),
        'NotEditableException: x',
      );
    });
  });
}
