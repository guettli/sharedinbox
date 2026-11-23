// Backend tests for entries (#1373) against a real Stalwart: two devices of
// one account, the key set up on A and unlocked on B with the recovery key;
// an entry created, edited and deleted on one shows on the other. Each
// device has its own database, secure storage, key ring, store with the
// entry projection, and entry repository.
// Run via: task test-backend

import 'dart:convert';
import 'dart:typed_data';

import 'package:sharedinbox/core/encrypted_objects/account_key_store.dart';
import 'package:sharedinbox/core/encrypted_objects/entry_object.dart';
import 'package:sharedinbox/core/encrypted_objects/envelope.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/encrypted_objects/key_ring.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/object_mail.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:sharedinbox/core/models/entry.dart';
import 'package:sharedinbox/core/services/encrypted_key_service.dart';
import 'package:sharedinbox/data/repositories/entry_projector.dart';
import 'package:sharedinbox/data/repositories/entry_repository_impl.dart';
import 'package:sharedinbox/data/repositories/share_key_repository_impl.dart';
import 'package:test/test.dart';

import 'mail_object_harness.dart';

const _dataPath = 'SharedInbox/Data';

void main() {
  late PoolImapAccount pool;

  setUpAll(() {
    configureSqliteForTests();
    pool = PoolImapAccount();
  });

  setUp(
    () => pool.deleteFolders([_dataPath, 'SharedInbox/Keys', 'SharedInbox']),
  );

  Future<_EntryDevice> device() async {
    final d = _EntryDevice(pool.account);
    addTearDown(() async {
      await d.store.waitForIdle();
      d.service.dispose();
      await d.db.close();
    });
    await d.accounts.addAccount(pool.account, pool.user.password);
    return d;
  }

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
        for (final raw in (await pool.rawMails(_dataPath)).values)
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
    await a.store.put(
      a.id,
      InnerObject(
        head: ObjectHead(
          itemId: itemId,
          collectionId: personalCollectionId,
          versionId: clock.send(),
          kind: entryKind,
          extra: const {
            'title': 'Plan',
            'tags': ['work'],
            'date': '2026-11-23',
            'task': {'done': false, 'due': '2026-12-01'},
            'links': ['<m1@example.com>'],
          },
        ),
        parts: [
          ObjectPart(
            contentType: 'text/markdown; charset=utf-8',
            bytes: Uint8List.fromList(utf8.encode('old')),
          ),
        ],
      ),
    );
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

class _EntryDevice {
  _EntryDevice(this.account) {
    accounts = AccountRepositoryImpl(db, storage);
    mailboxes = MailboxRepositoryImpl(
      db,
      accounts,
      imapConnect: testImapConnect,
    );
    store = MailObjectStoreImap(
      db,
      accounts,
      mailboxes,
      storage,
      imapConnect: testImapConnect,
      keyLookup: ring.lookup,
      writeKey: ring.writeKey,
      keepVanishedKeyMail: ring.keepVanishedKeyMail,
      appLogger: AppLogger(logs),
      projectors: [EntryProjector(db)],
    );
    service = EncryptedKeyService(
      db: db,
      store: store,
      keys: AccountKeyStore(storage),
      ring: ring,
      betaEnabled: () async => true,
      listFolders: (id) => mailboxes.syncMailboxes(id),
      shareKeys: ShareKeyRepositoryImpl(db),
      findAccount: accounts.getAccount,
      appLogger: AppLogger(logs),
    );
    repo = EntryRepositoryImpl(db, store);
  }

  final Account account;
  final AppDatabase db = openTestDatabase();
  final storage = FakeSecureStorage();
  final ring = KeyRing();
  final logs = RecordingAppLogRepository();
  late final AccountRepositoryImpl accounts;
  late final MailboxRepositoryImpl mailboxes;
  late final MailObjectStoreImap store;
  late final EncryptedKeyService service;
  late final EntryRepositoryImpl repo;

  String get id => account.id;

  /// The folder listing the mail sync runs first, then the store's sync and
  /// the key lifecycle after it.
  Future<void> listAndSync() async {
    await mailboxes.syncMailboxes(id);
    await store.sync(id);
    await store.waitForIdle();
    await service.afterSync(id, foreground: true);
  }

  Future<List<Entry>> entries() => repo.observeEntries(id).first;
}
