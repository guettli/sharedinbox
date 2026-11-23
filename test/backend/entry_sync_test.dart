// Backend tests for entries (#1373) against a real Stalwart: two devices of
// one account, the key set up on A and unlocked on B with the recovery key;
// an entry created, edited and deleted on one shows on the other. Each
// device has its own database, secure storage, key ring, store with the
// entry projection, and entry repository.
// Run via: task test-backend

import 'package:sharedinbox/core/encrypted_objects/envelope.dart';
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
}

/// A [KeyDevice] whose store writes the entry projection, with the entry
/// repository on top.
class _EntryDevice extends KeyDevice {
  _EntryDevice(super.account) : super(projectors: (db) => [EntryProjector(db)]);

  late final repo = EntryRepositoryImpl(db, store);

  /// The folder listing the mail sync runs first, then the store's sync and
  /// the key lifecycle after it.
  @override
  Future<void> listAndSync() async {
    await super.listAndSync();
    await service.afterSync(id, foreground: true);
  }

  Future<List<Entry>> entries() => repo.observeEntries(id).first;
}
