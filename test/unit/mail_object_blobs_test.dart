import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/encrypted_objects/envelope.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/mail_object_store_base.dart';

import 'db_test_helper.dart';
import 'helpers/mail_object_rig.dart';

const _deck = 'deck-1';
const _png = 'image/png';

Uint8List _bytes(int size, [int fill = 7]) =>
    Uint8List(size)..fillRange(0, size, fill);

void main() {
  setUpAll(configureSqliteForTests);

  for (final transport in ObjectTransport.values) {
    test(
        '${transport.name}: a blob over 256 KiB is downloaded on demand, '
        'cached, and downloaded again after an eviction', () async {
      final rig = ObjectRig(transport);
      final a = await rig.device();
      final b = await rig.device(budgetBytes: 500 * 1024);
      final image = _bytes(400 * 1024);
      final itemId = await a.blobs.putBlob(a.accountId, _deck, image, _png);
      await a.store.waitForIdle();

      await b.listAndSync();
      final row = (await b.rows()).single;
      expect(row.payload, isNull);
      expect(row.sizeBytes, greaterThan(mailObjectEagerBodyLimit));

      final got = (await b.blobs.blob(b.accountId, _deck, itemId))!;
      expect(got.bytes, image);
      expect(got.contentType, _png);
      expect((await b.rows()).single.payload, isNotNull);
      // A cache hit: no download.
      expect((await b.blobs.blob(b.accountId, _deck, itemId))!.bytes, image);

      // A second blob pushes the first out of the 500 KiB budget.
      final other = await a.blobs
          .putBlob(a.accountId, _deck, _bytes(300 * 1024, 9), _png);
      await a.store.waitForIdle();
      await b.sync();
      await b.blobs.blob(b.accountId, _deck, other);
      final first = (await b.rows()).firstWhere((r) => r.itemId == itemId);
      expect(first.payload, isNull);

      expect((await b.blobs.blob(b.accountId, _deck, itemId))!.bytes, image);
    });
  }

  test(
      'evicts the least recently used confirmed blob; a pending one stays; '
      'only one over 256 KiB loses its ciphertext', () async {
    final rig = ObjectRig(ObjectTransport.imap);
    final a = await rig.device(budgetBytes: 700 * 1024);
    Future<String> put(int kib) =>
        a.blobs.putBlob(a.accountId, _deck, _bytes(kib * 1024), _png);
    Future<Set<String>> cached() async => {
          for (final r in await a.db.select(a.db.mailObjectBlobs).get())
            r.itemId,
        };
    Future<MailObjectRow> rowOf(String itemId) async =>
        (await a.rows()).firstWhere((r) => r.itemId == itemId);
    final big = await put(300);
    final small = await put(100);
    await a.store.waitForIdle();
    // Offline: these stay pending upload, so they are never evicted.
    a.offline = true;
    final pending = await put(200);
    await a.blobs.blob(a.accountId, _deck, big);

    final pending2 = await put(200);

    expect(await cached(), {big, pending, pending2});
    expect((await rowOf(small)).payload, isNotNull);

    // Read again from the local ciphertext: now the big one is the least
    // recently used confirmed blob.
    expect(await a.blobs.blob(a.accountId, _deck, small), isNotNull);
    expect(await cached(), {small, pending, pending2});
    expect((await rowOf(big)).payload, isNull);
    expect((await rowOf(pending)).payload, isNotNull);
    expect(await a.blobs.blob(a.accountId, _deck, big), isNull);

    a.offline = false;
    expect(
      (await a.blobs.blob(a.accountId, _deck, big))!.bytes,
      _bytes(300 * 1024),
    );
  });

  test('a blob not known or not downloadable now is null', () async {
    final rig = ObjectRig(ObjectTransport.imap);
    final a = await rig.device();
    final b = await rig.device();
    final itemId =
        await a.blobs.putBlob(a.accountId, _deck, _bytes(300 * 1024), _png);
    await a.store.waitForIdle();
    await b.listAndSync();

    expect(await b.blobs.blob(b.accountId, _deck, 'unknown'), isNull);
    b.offline = true;
    expect(await b.blobs.blob(b.accountId, _deck, itemId), isNull);
    b.offline = false;
    expect(await b.blobs.blob(b.accountId, _deck, itemId), isNotNull);
  });

  test('a blob is immutable and limited to 8 MiB', () async {
    final rig = ObjectRig(ObjectTransport.imap);
    final a = await rig.device();
    final itemId = await a.blobs.putBlob(a.accountId, _deck, _bytes(10), _png);
    final clock = await a.store.clockFor(a.accountId);

    await expectLater(
      a.store.put(
        a.accountId,
        InnerObject(
          head: ObjectHead(
            itemId: itemId,
            collectionId: _deck,
            versionId: clock.send(),
            kind: 'blob',
          ),
          parts: [ObjectPart(contentType: _png, bytes: _bytes(11))],
        ),
      ),
      throwsStateError,
    );
    final rowsBefore = await a.messageIds();
    final cachedBefore = await a.db.select(a.db.mailObjectBlobs).get();
    await expectLater(
      a.blobs.putBlob(a.accountId, _deck, _bytes(maxEnvelopeBytes), _png),
      throwsA(isA<ObjectTooLargeException>()),
    );
    expect(
      (await a.rows()).where((r) => r.itemId == itemId),
      hasLength(1),
    );
    // Refused before anything is written (#1377).
    expect(await a.messageIds(), rowsBefore);
    expect(
      (await a.db.select(a.db.mailObjectBlobs).get()).map((r) => r.itemId),
      cachedBefore.map((r) => r.itemId),
    );
  });
}
