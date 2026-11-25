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
    List<MailObjectProjector> Function(AppDatabase db) projectors =
        _noProjectors,
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
      onStep: (step) async => onStep?.call(step),
    );
    service = EncryptedKeyService(
      db: db,
      store: store,
      keys: keys,
      ring: ring,
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

  /// Test seam: called before and after each server write of the store.
  void Function(String step)? onStep;

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

List<MailObjectProjector> _noProjectors(AppDatabase db) => const [];

/// A [KeyDevice] whose store writes projections (#1373, #1379, #1380): its
/// [listAndSync] also runs the key lifecycle after the sync, as the app
/// does, so collection keys that arrived open the new objects.
class ProjectingKeyDevice extends KeyDevice {
  ProjectingKeyDevice(super.account, {required super.projectors});

  /// The folder listing the mail sync runs first, then the store's sync and
  /// the key lifecycle after it.
  @override
  Future<void> listAndSync() async {
    await super.listAndSync();
    await service.afterSync(id, foreground: true);
  }
}
