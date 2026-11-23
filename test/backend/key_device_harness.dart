// What the backend tests of the key lifecycle (#1366) and of entries (#1373)
// share: a pool account with fresh SharedInbox folders and one install with
// the key lifecycle wired like the app's.

import 'package:sharedinbox/core/encrypted_objects/account_key_store.dart';
import 'package:sharedinbox/core/encrypted_objects/key_ring.dart';
import 'package:sharedinbox/core/encrypted_objects/passkey_slot.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/core/services/encrypted_key_service.dart';
import 'package:sharedinbox/data/repositories/share_key_repository_impl.dart';
import 'package:test/test.dart';

import 'mail_object_harness.dart';

export 'mail_object_harness.dart';

const keysPath = 'SharedInbox/Keys';
const dataPath = 'SharedInbox/Data';

/// Sets up the pool account of the test file and deletes its SharedInbox
/// folders before each test. Returns the account once `setUpAll` ran.
PoolImapAccount Function() setUpKeyPool() {
  late PoolImapAccount pool;
  setUpAll(() {
    configureSqliteForTests();
    pool = PoolImapAccount();
  });
  setUp(() => pool.deleteFolders([dataPath, keysPath, 'SharedInbox']));
  return () => pool;
}

/// Adds the account of [pool] to [device] and closes the device after the
/// test.
Future<T> addKeyDevice<T extends KeyDevice>(
  PoolImapAccount pool,
  T device,
) async {
  addTearDown(() async {
    await device.store.waitForIdle();
    device.service.dispose();
    await device.db.close();
  });
  await device.accounts.addAccount(pool.account, pool.user.password);
  return device;
}

/// One install with the key lifecycle wired like the app's.
class KeyDevice {
  /// [projectors] builds the projectors of the store on the device's
  /// database.
  KeyDevice(
    this.account, {
    List<ObjectProjector> Function(AppDatabase db) projectors = _noProjectors,
    PrfProvider? prf,
  }) {
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
      projectors: projectors(db),
    );
    service = EncryptedKeyService(
      db: db,
      store: store,
      keys: keys,
      ring: ring,
      betaEnabled: () async => true,
      listFolders: (id) => mailboxes.syncMailboxes(id),
      shareKeys: ShareKeyRepositoryImpl(db),
      findAccount: accounts.getAccount,
      appLogger: AppLogger(logs),
      prf: prf,
    );
  }

  final Account account;
  final AppDatabase db = openTestDatabase();
  final storage = FakeSecureStorage();
  final ring = KeyRing();
  final logs = RecordingAppLogRepository();
  late final keys = AccountKeyStore(storage);
  late final AccountRepositoryImpl accounts;
  late final MailboxRepositoryImpl mailboxes;
  late final MailObjectStoreImap store;
  late final EncryptedKeyService service;

  String get id => account.id;

  Future<void> sync() async {
    await store.sync(id);
    await store.waitForIdle();
  }

  Future<void> listAndSync() async {
    await mailboxes.syncMailboxes(id);
    await sync();
  }

  Future<List<MailObject>> keyRows() =>
      store.observe(id, MailObjectFolder.keys).first;
}

List<ObjectProjector> _noProjectors(AppDatabase db) => const [];
