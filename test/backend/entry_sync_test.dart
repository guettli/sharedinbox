// Backend tests for entries (#1373) against a real Stalwart: two devices of
// one account, the key set up on A and unlocked on B with the recovery key;
// an entry created, edited and deleted on one shows on the other. Each
// device has its own database, secure storage, key ring, store with the
// entry projection, and entry repository. Concurrent edits on both are a
// conflict on both; resolving it on one (#1374) clears it on both. The same
// todo ticked on both at once is identical content: done, no conflict
// (#1357).
// Run via: task test-backend

import 'package:sharedinbox/core/encrypted_objects/envelope.dart';
import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/object_mail.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:sharedinbox/core/models/entry.dart';
import 'package:sharedinbox/core/services/encrypted_key_service.dart';
import 'package:sharedinbox/data/repositories/entry_projector.dart';
import 'package:sharedinbox/data/repositories/entry_repository_impl.dart';
import 'package:test/test.dart';

import 'key_device_harness.dart';

void main() {
  final pool = setUpKeyPool();

  Future<_EntryDevice> device() =>
      addKeyDevice(pool(), _EntryDevice(pool().account));

  /// A with a new key, B unlocked with its recovery key.
  Future<(_EntryDevice, _EntryDevice)> twoDevices() async {
    final a = await device();
    final created = await a.service.createKey(a.id) as KeyCreated;
    await a.store.waitForIdle();
    final b = await device();
    await b.listAndSync();
    await b.service.unlockWithRecoveryKey(b.id, created.formatted);
    expect(await b.service.status(b.id), PersonalDataStatus.unlocked);
    return (a, b);
  }

  /// The item HMACs of the mails in the Data folder.
  Future<List<String>> itemsOnServer() async => [
        for (final raw in (await pool().rawMails(dataPath)).values)
          b64url(parseObjectMail(raw).itemHmac),
      ];

  test('an entry created on A appears on B', () async {
    final (a, b) = await twoDevices();
    final created = await a.repo.create(a.id, body: 'Buy milk\nand eggs');
    await a.store.waitForIdle();
    await a.listAndSync();

    await b.listAndSync();
    final onB = (await b.entries()).single;
    expect(onB.itemId, created.itemId);
    expect(onB.title, isNull);
    expect(onB.displayTitle, 'Buy milk');
    expect(onB.body, 'Buy milk\nand eggs');
    expect(onB.hasConflict, isFalse);
  });

  test('an edit on B reaches A and keeps the other fields', () async {
    final (a, b) = await twoDevices();
    final clock = await a.store.clockFor(a.id);
    final itemId = newItemId();
    await a.store.put(a.id, plannedEntryObject(itemId, clock.send()));
    await a.store.waitForIdle();
    await a.listAndSync();
    await b.listAndSync();
    expect((await b.entries()).single.title, 'Plan');

    await b.repo.update(b.id, itemId, title: 'Plan v2', body: 'new body');
    await b.store.waitForIdle();
    await b.listAndSync();
    await a.listAndSync();

    final onA = (await a.entries()).single;
    expect(onA.title, 'Plan v2');
    expect(onA.body, 'new body');
    expect(onA.tags, ['work']);
    expect(onA.date, '2026-11-23');
    expect(onA.task!.due, '2026-12-01');
    expect(onA.links, ['<m1@example.com>']);
    expect(onA.hasConflict, isFalse);
    // Only the new version is left on the server.
    expect(await itemsOnServer(), [onA.itemHmac]);
  });

  test('a delete on A removes the entry on B; the tombstone stays', () async {
    final (a, b) = await twoDevices();
    final created = await a.repo.create(a.id, body: 'short-lived');
    await a.store.waitForIdle();
    await a.listAndSync();
    await b.listAndSync();
    expect(await b.entries(), hasLength(1));

    await a.repo.delete(a.id, created.itemId);
    await a.store.waitForIdle();
    await a.listAndSync();
    expect(await a.entries(), isEmpty);
    await b.listAndSync();
    expect(await b.entries(), isEmpty);

    expect(await itemsOnServer(), [created.itemHmac]);
    final item = await b.store.item(b.id, created.itemHmac);
    expect(item!.display.head.deleted, isTrue);
  });

  /// Both edit [created] at once with different bodies: a conflict on both
  /// once A, B and A synced. Returns B's version.
  Future<Hlc> concurrentEdits(
    _EntryDevice a,
    _EntryDevice b,
    Entry created,
  ) async {
    await a.repo.update(a.id, created.itemId, body: 'from A');
    await b.repo.update(b.id, created.itemId, body: 'from B');
    await a.store.waitForIdle();
    await b.store.waitForIdle();
    await a.listAndSync();
    await b.listAndSync();
    await a.listAndSync();
    for (final d in [a, b]) {
      expect((await d.entries()).single.hasConflict, isTrue);
      final listed = await d.store.observeConflicts(d.id).first;
      expect(listed.single.itemHmac, created.itemHmac);
      final item = await d.store.item(d.id, created.itemHmac);
      expect(item!.versions, hasLength(2));
    }
    final bDevice = (await b.store.clockFor(b.id)).deviceId;
    final item = (await a.store.item(a.id, created.itemHmac))!;
    return item.merge.distinctHeads
        .firstWhere((h) => h.versionId.deviceId == bDevice)
        .versionId;
  }

  Future<Entry> sharedEntry(_EntryDevice a, _EntryDevice b) async {
    final created = await a.repo.create(a.id, body: 'base');
    await a.store.waitForIdle();
    await a.listAndSync();
    await b.listAndSync();
    expect(await b.entries(), hasLength(1));
    return created;
  }

  test('a conflict resolved on A is gone on both', () async {
    final (a, b) = await twoDevices();
    final created = await sharedEntry(a, b);
    final fromB = await concurrentEdits(a, b, created);

    await a.store.resolve(a.id, created.itemHmac, keep: fromB);
    await a.store.waitForIdle();
    await a.listAndSync();
    await b.listAndSync();

    for (final d in [a, b]) {
      final entry = (await d.entries()).single;
      expect(entry.hasConflict, isFalse);
      expect(entry.body, 'from B');
      expect(await d.store.observeConflicts(d.id).first, isEmpty);
    }
    expect(await itemsOnServer(), [created.itemHmac]);
  });

  test('a todo ticked on A and B at once is done on both, no conflict',
      () async {
    final (a, b) = await twoDevices();
    final created = await a.repo.create(
      a.id,
      body: 'Call Bob',
      task: const EntryTask(due: '2026-11-23'),
    );
    await a.store.waitForIdle();
    await a.listAndSync();
    await b.listAndSync();
    expect((await b.entries()).single.task!.done, isFalse);

    for (final d in [a, b]) {
      final todo = (await d.entries()).single;
      await d.repo.setTask(d.id, todo.itemId, todo.task!.copyWith(done: true));
      await d.store.waitForIdle();
    }
    for (var round = 0; round < 2; round++) {
      await a.listAndSync();
      await b.listAndSync();
    }

    for (final d in [a, b]) {
      final todo = (await d.entries()).single;
      expect(todo.task!.done, isTrue);
      expect(todo.task!.due, '2026-11-23');
      expect(todo.hasConflict, isFalse);
      expect(await d.store.observeConflicts(d.id).first, isEmpty);
      final item = (await d.store.item(d.id, created.itemHmac))!;
      expect(item.merge.distinctHeads, hasLength(1));
    }
  });

  test('"keep both" on A leaves two entries on both', () async {
    final (a, b) = await twoDevices();
    final created = await sharedEntry(a, b);
    final fromB = await concurrentEdits(a, b, created);

    await a.store.keepAll(a.id, created.itemHmac, keep: fromB);
    await a.store.waitForIdle();
    await a.listAndSync();
    await b.listAndSync();

    for (final d in [a, b]) {
      final entries = await d.entries();
      expect(
        [for (final e in entries) e.body],
        unorderedEquals(['from A', 'from B']),
      );
      expect(entries.where((e) => e.hasConflict), isEmpty);
      expect(await d.store.observeConflicts(d.id).first, isEmpty);
    }
    expect(await itemsOnServer(), hasLength(2));
  });
}

/// A [KeyDevice] whose store writes the entry projection, with the entry
/// repository on top.
class _EntryDevice extends ProjectingKeyDevice {
  _EntryDevice(super.account) : super(projectors: (db) => [EntryProjector(db)]);

  late final repo = EntryRepositoryImpl(db, store);

  Future<List<Entry>> entries() => repo.observeEntries(id).first;
}
