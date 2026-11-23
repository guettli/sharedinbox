// Backend tests for the key lifecycle (#1366) against a real Stalwart: key
// mail round trip, two devices racing, unlocking a second device and a
// keys folder deleted while unlocked. Each device has its own database,
// secure storage, key ring and store.
// Run via: task test-backend

import 'dart:convert';

import 'package:sharedinbox/core/encrypted_objects/account_key_store.dart';
import 'package:sharedinbox/core/encrypted_objects/key_mail_message.dart';
import 'package:sharedinbox/core/encrypted_objects/key_ring.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/mail_object.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/core/services/encrypted_key_service.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mail_object_store_imap.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';
import 'package:test/test.dart';

import '../unit/db_test_helper.dart';
import '../unit/encrypted_objects/test_helpers.dart';
import '../unit/helpers/fake_secure_storage.dart';
import '../unit/recording_app_log_repository.dart';
import 'stalwart_harness.dart';

const _keysPath = 'SharedInbox/Keys';

void main() {
  late PoolImapAccount pool;

  setUpAll(() {
    configureSqliteForTests();
    pool = PoolImapAccount();
  });

  setUp(
    () => pool.deleteFolders(['SharedInbox/Data', _keysPath, 'SharedInbox']),
  );

  Future<_KeyDevice> device() async {
    final d = _KeyDevice(pool.account);
    addTearDown(() async {
      await d.store.waitForIdle();
      d.service.dispose();
      await d.db.close();
    });
    await d.accounts.addAccount(pool.account, pool.user.password);
    return d;
  }

  /// The account-key mails on the server, by Message-ID.
  Future<Map<String, AccountKeyMailMsg>> keyMailsOnServer() async => {
        for (final MapEntry(:key, :value)
            in (await pool.rawMails(_keysPath)).entries)
          if (parseKeyMailMessage(value) case final AccountKeyMailMsg m) key: m,
      };

  test('key round trip: a second device sees the same bytes; the MAC verifies',
      () async {
    final a = await device();
    expect(await a.service.createKey(a.id), isA<KeyCreated>());
    await a.store.waitForIdle();
    final ownRows = {
      for (final r in await a.keyRows()) r.messageId: r.payload,
    };

    final b = await device();
    await b.listAndSync();

    final server = await pool.rawMails(_keysPath);
    expect(server.keys.toSet(), ownRows.keys.toSet());
    expect(server, hasLength(2));
    final seen = await b.keyRows();
    expect(seen.map((r) => r.messageId).toSet(), ownRows.keys.toSet());
    for (final r in seen) {
      expect(r.payload, ownRows[r.messageId], reason: 'bytes unchanged');
      expect(server[r.messageId], ownRows[r.messageId]);
    }
    final kinds = [for (final r in seen) parseKeyMailMessage(r.payload!)];
    expect(kinds.whereType<CollectionKeyMailMsg>(), hasLength(1));
    final keyMail = kinds.whereType<AccountKeyMailMsg>().single;
    final key = (await a.keys.load(a.id))!;
    expect(await keyMail.mail.verify(await key.kSlots()), isTrue);
    expect(await b.service.status(b.id), PersonalDataStatus.locked);
  });

  test('two devices racing: one wins, the loser deletes its key mail',
      () async {
    final a = await device();
    final b = await device();

    final results = await Future.wait([
      a.service.createKey(a.id),
      b.service.createKey(b.id),
    ]);

    final won = results.whereType<KeyCreated>().toList();
    expect(won, hasLength(1), reason: 'exactly one recovery key is shown');
    final winner = results[0] is KeyCreated ? a : b;
    final loser = identical(winner, a) ? b : a;
    expect(
      results.where((r) => r is KeyRaceLost || r is KeyAlreadyExists),
      hasLength(1),
    );
    // The loser's foreground sync removes its key mail from the server.
    await loser.sync();
    await winner.sync();
    final winnerKey = (await winner.keys.load(winner.id))!;
    expect(
      [
        for (final m in (await keyMailsOnServer()).values)
          b64url(m.mail.payload.accountKeyId),
      ],
      [b64url(winnerKey.accountKeyId)],
    );
    expect(await loser.keys.load(loser.id), isNull);
    expect(
      await loser.service.status(loser.id),
      anyOf(PersonalDataStatus.lostRace, PersonalDataStatus.locked),
    );
  });

  test(
      'a second device unlocks with the recovery key: the identical key, '
      'and an object of the first device opens', () async {
    final a = await device();
    final created = await a.service.createKey(a.id) as KeyCreated;
    final clock = await a.store.clockFor(a.id);
    final put = await a.store.put(
      a.id,
      testObject(
        itemId: 'key-test-${DateTime.now().microsecondsSinceEpoch}',
        collectionId: personalCollectionId,
        versionId: clock.send(),
        body: 'secret note',
      ),
    );
    await a.store.waitForIdle();

    final b = await device();
    await b.listAndSync();
    expect(await b.store.item(b.id, put.itemHmac!), isNull);

    await b.service.unlockWithRecoveryKey(b.id, created.formatted);

    final ka = (await a.keys.load(a.id))!;
    final kb = (await b.keys.load(b.id))!;
    expect(kb.accountKeyId, ka.accountKeyId);
    expect(kb.key.bytes, ka.key.bytes);
    final item = await b.store.item(b.id, put.itemHmac!);
    expect(utf8.decode(item!.display.parts.first.bytes), 'secret note');
    expect(await b.service.status(b.id), PersonalDataStatus.unlocked);
  });

  test(
      'the keys folder deleted while unlocked: made again, the same mails '
      'uploaded, the key kept', () async {
    final a = await device();
    await a.service.createKey(a.id);
    await a.store.waitForIdle();
    final before = await pool.rawMails(_keysPath);

    await pool.deleteFolders([_keysPath]);
    await a.listAndSync();
    await a.service.afterSync(a.id, foreground: true);

    final after = await pool.rawMails(_keysPath);
    expect(after.keys.toSet(), before.keys.toSet());
    for (final id in before.keys) {
      expect(after[id], before[id]);
    }
    expect(await a.keys.load(a.id), isNotNull);
    expect(await a.service.status(a.id), PersonalDataStatus.unlocked);
  });

  test('a foreign key mail after the first write only warns', () async {
    final a = await device();
    await a.service.createKey(a.id);
    final own = (await a.keys.load(a.id))!;
    await a.store.put(
      a.id,
      testObject(
        itemId: 'key-test-${DateTime.now().microsecondsSinceEpoch}',
        collectionId: personalCollectionId,
        versionId: (await a.store.clockFor(a.id)).send(),
      ),
    );
    await a.store.waitForIdle();
    final foreign = await foreignKeyMailForTest();
    await pool.withClient(
      (c) => c.appendMessageText(
        ascii.decode(foreign.mail),
        targetMailboxPath: _keysPath,
      ),
    );

    await a.sync();
    await a.service.afterSync(a.id, foreground: true);

    expect(await a.service.isCommitted(a.id), isTrue);
    expect(await a.service.status(a.id), PersonalDataStatus.foreignKeyWarning);
    expect((await a.keys.load(a.id))!.accountKeyId, own.accountKeyId);
    expect(
      a.logs.rows.map((r) => r.event),
      contains('mos.foreign_key_mail'),
    );
  });
}

/// One install with the key lifecycle wired like the app's.
class _KeyDevice {
  _KeyDevice(this.account) {
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
    );
    service = EncryptedKeyService(
      db: db,
      store: store,
      keys: keys,
      ring: ring,
      betaEnabled: () async => true,
      listFolders: (id) => mailboxes.syncMailboxes(id),
      appLogger: AppLogger(logs),
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
