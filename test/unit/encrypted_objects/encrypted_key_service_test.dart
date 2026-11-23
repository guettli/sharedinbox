import 'dart:io';
import 'dart:typed_data';

import 'package:sharedinbox/core/encrypted_objects/account_key_store.dart';
import 'package:sharedinbox/core/encrypted_objects/key_mail.dart';
import 'package:sharedinbox/core/encrypted_objects/key_mail_message.dart';
import 'package:sharedinbox/core/encrypted_objects/key_ring.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/object_mail.dart';
import 'package:sharedinbox/core/encrypted_objects/pairing.dart';
import 'package:sharedinbox/core/encrypted_objects/passkey_slot.dart';
import 'package:sharedinbox/core/encrypted_objects/passphrase.dart';
import 'package:sharedinbox/core/encrypted_objects/recovery_key.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/core/services/encrypted_key_service.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/share_key_repository_impl.dart';
import 'package:test/test.dart';

import '../db_test_helper.dart';
import '../helpers/fake_secure_storage.dart';
import '../recording_app_log_repository.dart';
import 'fake_keys_store.dart';
import 'fake_prf_provider.dart';
import 'test_helpers.dart';

const _acc = 'acc';

const _account = Account(
  id: _acc,
  displayName: 'Alice',
  email: 'alice@example.com',
  imapHost: 'mail.example.com',
);

/// One install: its own database, secure storage, store and key ring.
class _Device {
  _Device(
    this.server, {
    this.beta = true,
    this.account = _account,
    this.prf,
  }) {
    service = EncryptedKeyService(
      db: db,
      store: store,
      keys: keys,
      ring: ring,
      betaEnabled: () async => beta,
      shareKeys: ShareKeyRepositoryImpl(db),
      findAccount: (id) async => id == _acc ? account : null,
      appLogger: AppLogger(logs),
      deriver: _cheapArgon2id,
      prf: prf,
    );
    store.keepVanished = (row) => ring.keepVanishedKeyMail(_acc, row);
  }

  final FakeKeysServer server;
  bool beta;
  final Account account;
  final FakePrfProvider? prf;
  final AppDatabase db = openTestDatabase();
  final storage = FakeSecureStorage();
  late final store = FakeKeysStore(server);
  final ring = KeyRing();
  late final keys = AccountKeyStore(storage);
  final logs = RecordingAppLogRepository();
  late final EncryptedKeyService service;

  Future<PersonalDataStatus> status() => service.status(_acc);

  List<String> get events => [for (final r in logs.rows) r.event];
}

/// Argon2id with tiny params, whatever the slot says.
Future<Uint8List> _cheapArgon2id(
  Uint8List passphrase,
  Uint8List salt,
  Argon2idParams params,
) =>
    argon2id(
      passphrase,
      salt,
      const Argon2idParams(memoryKiB: 64, iterations: 1),
    );

const _passphrase = 'violet tractor sings beneath copper rain';

List<AccountKeyMailMsg> _accountKeyMails(FakeKeysServer server) => [
      for (final m in server.mails.values)
        if (parseKeyMailMessage(m.mail) case final AccountKeyMailMsg a) a,
    ];

void main() {
  setUpAll(configureSqliteForTests);

  late FakeKeysServer server;
  final devices = <_Device>[];

  Future<_Device> device({
    bool beta = true,
    Account account = _account,
    FakePrfProvider? prf,
  }) async {
    final d = _Device(server, beta: beta, account: account, prf: prf);
    devices.add(d);
    await seedAccountRow(d.db, _acc);
    return d;
  }

  setUp(() => server = FakeKeysServer());
  tearDown(() async {
    for (final d in devices) {
      d.service.dispose();
      await d.db.close();
    }
    devices.clear();
  });

  group('keyRaceWinner', () {
    Future<KeyMailEntry> entry(AccountKey key, int? uid, {int v = 1}) async {
      final payload = KeyMailPayload(
        accountKeyId: key.accountKeyId,
        slotListVersion: v,
        slots: const [],
      );
      return (
        messageId: '<$uid-$v>',
        mail: await payload.serialize(await key.kSlots()),
        uid: uid,
      );
    }

    final a = AccountKey(seqBytes(0x10, 16), seqBytes(0, 32));
    final b = AccountKey(seqBytes(0x20, 16), seqBytes(1, 32));

    test('the group whose first mail has the lowest UID wins', () async {
      expect(
        keyRaceWinner([await entry(b, 4), await entry(a, 2)]),
        b64url(a.accountKeyId),
      );
      expect(keyRaceWinner(const []), isNull);
    });

    test('a later slot-change mail of a group does not affect the race',
        () async {
      // a's first mail is UID 1; its slot change got UID 9; b has UID 5.
      expect(
        keyRaceWinner([
          await entry(b, 5),
          await entry(a, 9, v: 2),
          await entry(a, 1),
        ]),
        b64url(a.accountKeyId),
      );
    });

    test('mails without a UID take no part; a tie goes to the lowest id',
        () async {
      expect(
        keyRaceWinner([await entry(a, null), await entry(b, 3)]),
        b64url(b.accountKeyId),
      );
      expect(
        keyRaceWinner([await entry(b, 3), await entry(a, 3)]),
        b64url(a.accountKeyId),
      );
    });
  });

  test('setup on an empty server: key mail, personal key, recovery key',
      () async {
    final a = await device();
    expect(await a.status(), PersonalDataStatus.notSetUp);

    final result = await a.service.createKey(_acc);

    expect(result, isA<KeyCreated>());
    final created = result as KeyCreated;
    expect(created.formatted, await created.recoveryKey.format());
    expect(server.mails, hasLength(2));
    final keyMail = _accountKeyMails(server).single;
    final stored = (await a.keys.load(_acc))!;
    expect(keyMail.mail.payload.accountKeyId, stored.accountKeyId);
    expect(await keyMail.mail.verify(await stored.kSlots()), isTrue);
    expect(await a.keys.loadPending(_acc), isNull);
    expect(a.ring.hasWriteKey(_acc, personalCollectionId), isTrue);
    expect(await a.status(), PersonalDataStatus.unlocked);
    expect(a.store.reopens, greaterThan(0));
    expect(a.events, containsAll(['mos.key_created', 'mos.key_race_won']));
  });

  test('a device finding a key mail creates nothing and is locked', () async {
    final a = await device();
    await a.service.createKey(_acc);
    final c = await device();

    expect(await c.service.createKey(_acc), isA<KeyAlreadyExists>());
    expect(server.mails, hasLength(2));
    expect(await c.status(), PersonalDataStatus.locked);
    expect(await c.keys.loadPending(_acc), isNull);
  });

  test('a key mail appended between our pull and push wins; ours goes',
      () async {
    final a = await device();
    final foreign = await foreignKeyMailForTest();
    var appended = false;
    a.store.betweenPullAndPush = () {
      // Only once our own mail waits for its upload.
      if (appended || !a.store.rows.any((r) => r.pendingUpload)) return;
      appended = true;
      server.append(foreign.messageId, foreign.mail);
    };

    final result = await a.service.createKey(_acc);

    expect(result, isA<KeyRaceLost>());
    expect(server.messageIds, [foreign.messageId]);
    expect(await a.keys.load(_acc), isNull);
    expect(await a.keys.loadPending(_acc), isNull);
    expect(await a.status(), PersonalDataStatus.lostRace);
    expect(a.events, contains('mos.key_race_lost'));
  });

  test('two devices racing: exactly one wins and shows a recovery key',
      () async {
    final a = await device();
    final b = await device();

    final results = await Future.wait([
      a.service.createKey(_acc),
      b.service.createKey(_acc),
    ]);

    final won = results.whereType<KeyCreated>().toList();
    expect(won, hasLength(1));
    final loser = results[0] is KeyCreated ? b : a;
    final winner = identical(loser, a) ? b : a;
    expect(
      results.where((r) => r is KeyRaceLost || r is KeyAlreadyExists),
      hasLength(1),
    );
    final winnerKey = (await winner.keys.load(_acc))!;
    expect(
      _accountKeyMails(server).map((m) => b64url(m.mail.payload.accountKeyId)),
      [b64url(winnerKey.accountKeyId)],
    );
    expect(await loser.keys.load(_acc), isNull);
    expect(
      await loser.status(),
      anyOf(PersonalDataStatus.lostRace, PersonalDataStatus.locked),
    );

    // The loser unlocks with the winner's recovery key.
    await loser.service.unlockWithRecoveryKey(_acc, won.single.formatted);
    expect((await loser.keys.load(_acc))!.key.bytes, winnerKey.key.bytes);
    expect(await loser.status(), PersonalDataStatus.unlocked);
  });

  test('a second device unlocks with the recovery key: the same keys',
      () async {
    final a = await device();
    final created = await a.service.createKey(_acc) as KeyCreated;
    final b = await device();
    await b.store.sync(_acc);
    expect(await b.status(), PersonalDataStatus.locked);

    // Typed lower case with spaces: the lenient rules apply.
    await b.service.unlockWithRecoveryKey(
      _acc,
      created.formatted.toLowerCase().replaceAll('-', ' '),
    );

    final ka = (await a.keys.load(_acc))!;
    final kb = (await b.keys.load(_acc))!;
    expect(kb.accountKeyId, ka.accountKeyId);
    expect(kb.key.bytes, ka.key.bytes);
    expect(
      b.ring.writeKey(_acc, personalCollectionId)!.keyId,
      a.ring.writeKey(_acc, personalCollectionId)!.keyId,
    );
    expect(b.store.reopens, greaterThan(0));
    expect(await b.status(), PersonalDataStatus.unlocked);
    expect(b.events, contains('mos.key_unlocked'));
  });

  test('unlock errors are typed', () async {
    final a = await device();
    final created = await a.service.createKey(_acc) as KeyCreated;
    final b = await device();
    final last = created.formatted.substring(created.formatted.length - 1);
    final typo = created.formatted.substring(0, created.formatted.length - 1) +
        (last == 'A' ? 'B' : 'A');

    Future<UnlockFailure> failure(String input) async {
      try {
        await b.service.unlockWithRecoveryKey(_acc, input);
      } on UnlockFailed catch (e) {
        return e.reason;
      }
      fail('unlocked with "$input"');
    }

    expect(await failure('hello'), UnlockFailure.badFormat);
    expect(await failure(typo), UnlockFailure.badChecksum);
    expect(
      await failure(await RecoveryKey.generate().format()),
      UnlockFailure.noSlotOpens,
    );
    expect(await b.keys.load(_acc), isNull);
    expect(b.events, contains('mos.key_unlock_failed'));
  });

  test('an interrupted setup that won resumes with a new recovery key',
      () async {
    final a = await device();
    a.store.betweenPullAndPush = () => a.store.offline = true;

    await expectLater(
      a.service.createKey(_acc),
      throwsA(isA<SocketException>()),
    );
    expect(await a.status(), PersonalDataStatus.setupInterrupted);
    expect(await a.keys.loadPending(_acc), isNotNull);
    expect(server.mails, isEmpty);

    // The background never decides.
    a.store
      ..betweenPullAndPush = null
      ..offline = false;
    await a.service.afterSync(_acc, foreground: false);
    expect(await a.status(), PersonalDataStatus.setupInterrupted);

    final created = await a.service.createKey(_acc) as KeyCreated;

    final keyMail = _accountKeyMails(server).single;
    expect(keyMail.mail.payload.slotListVersion, 2);
    expect(server.mails, hasLength(2));
    expect(await a.status(), PersonalDataStatus.unlocked);
    final b = await device();
    await b.service.unlockWithRecoveryKey(_acc, created.formatted);
    expect(
      (await b.keys.load(_acc))!.key.bytes,
      (await a.keys.load(_acc))!.key.bytes,
    );
  });

  test(
      'an interrupted setup that lost is cleaned up by a foreground sync '
      'only, after the re-list', () async {
    final a = await device();
    a.store.betweenPullAndPush = () => a.store.offline = true;
    await expectLater(a.service.createKey(_acc), throwsA(anything));
    final foreign = await foreignKeyMailForTest();
    server.append(foreign.messageId, foreign.mail);
    a.store
      ..betweenPullAndPush = null
      ..offline = false;
    // The app's object sync uploads the own mail after the foreign one.
    await a.store.sync(_acc);
    expect(server.mails, hasLength(2));

    await a.service.afterSync(_acc, foreground: false);
    expect(server.mails, hasLength(2));
    expect(await a.status(), PersonalDataStatus.setupInterrupted);

    await a.service.afterSync(_acc, foreground: true);
    expect(server.messageIds, [foreign.messageId]);
    expect(await a.status(), PersonalDataStatus.lostRace);
    expect(await a.keys.loadPending(_acc), isNull);
  });

  test('a committed device keeps its key when a foreign key mail appears',
      () async {
    final a = await device();
    await a.service.createKey(_acc);
    final own = (await a.keys.load(_acc))!;
    expect(a.ring.writeKey(_acc, personalCollectionId), isNotNull);
    // Recorded in the background of the lookup.
    for (var i = 0; i < 100 && !await a.service.isCommitted(_acc); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(await a.service.isCommitted(_acc), isTrue);

    final foreign = await foreignKeyMailForTest();
    server.append(foreign.messageId, foreign.mail);
    await a.store.sync(_acc);
    await a.service.afterSync(_acc, foreground: true);

    expect(await a.status(), PersonalDataStatus.foreignKeyWarning);
    expect((await a.keys.load(_acc))!.accountKeyId, own.accountKeyId);
    expect(a.ring.accountKey(_acc)!.accountKeyId, own.accountKeyId);
    final warning =
        a.logs.rows.firstWhere((r) => r.event == 'mos.foreign_key_mail');
    expect(warning.dataJson, contains('"count":1'));
  });

  test('the keys folder emptied on the server: the mails go up again',
      () async {
    final a = await device();
    await a.service.createKey(_acc);
    final ids = server.messageIds;
    server.mails.clear();

    await a.store.sync(_acc);
    await a.service.afterSync(_acc, foreground: true);

    expect(server.messageIds.toSet(), ids.toSet());
    expect(await a.keys.load(_acc), isNotNull);
    expect(await a.status(), PersonalDataStatus.unlocked);
  });

  test('only the mails of the held key are uploaded again when they vanish',
      () async {
    final a = await device();
    await a.service.createKey(_acc);
    final foreign = await foreignKeyMailForTest();
    server.append(foreign.messageId, foreign.mail);
    await a.store.sync(_acc);
    final b = await device();
    await b.store.sync(_acc);

    Future<Map<String, bool>> kept(_Device d) async => {
          for (final r in d.store.rows)
            r.messageId: await d.service.keepVanishedKeyMail(_acc, r),
        };

    final byA = await kept(a);
    expect(byA[foreign.messageId], isFalse);
    expect(byA.values.where((k) => k), hasLength(2));
    // A device without the key keeps nothing.
    expect((await kept(b)).values, everyElement(isFalse));
  });

  test('with the beta switch off the hook does nothing', () async {
    final a = await device();
    await a.service.createKey(_acc);
    final reopens = a.store.reopens;
    final b = await device(beta: false);
    await b.store.sync(_acc);
    await b.service.loadKeys(_acc);
    await b.service.afterSync(_acc, foreground: true);
    a.beta = false;
    await a.service.afterSync(_acc, foreground: true);

    expect(a.store.reopens, reopens);
    expect(b.ring.accountKey(_acc), isNull);
    expect(b.logs.rows, isEmpty);
  });

  test('loadKeys fills the ring of a fresh install from the device key',
      () async {
    final a = await device();
    await a.service.createKey(_acc);
    final b = await device();
    await b.storage.write(
      key: AccountKeyStore.storageKey(_acc),
      value: await a.storage.read(key: AccountKeyStore.storageKey(_acc)),
    );
    await b.store.sync(_acc);

    await b.service.loadKeys(_acc);

    expect(b.ring.hasWriteKey(_acc, personalCollectionId), isTrue);
    await b.service.afterSync(_acc, foreground: false);
    expect(b.store.reopens, 0, reason: 'nothing new since loadKeys');
  });

  test('watchStatus follows the setup', () async {
    final a = await device();
    final statuses = a.service.watchStatus(_acc);
    final expectation = expectLater(
      statuses,
      emitsInOrder([
        PersonalDataStatus.notSetUp,
        emitsThrough(PersonalDataStatus.unlocked),
      ]),
    );
    await Future<void>.delayed(Duration.zero);
    await a.service.createKey(_acc);
    await expectation;
  });

  test('no key material reaches the logs', () async {
    final a = await device();
    final created = await a.service.createKey(_acc) as KeyCreated;
    final b = await device();
    try {
      await b.service.unlockWithRecoveryKey(
        _acc,
        await RecoveryKey.generate().format(),
      );
    } on UnlockFailed {
      // Logged.
    }
    await b.service.unlockWithRecoveryKey(_acc, created.formatted);
    await b.service.afterSync(_acc, foreground: true);

    final key = (await a.keys.load(_acc))!;
    final slot = _accountKeyMails(server).single.mail.payload.slots.single;
    final secrets = [
      created.formatted,
      normalizeRecoveryInput(created.formatted),
      b64url(created.recoveryKey.raw),
      b64url(key.key.bytes),
      b64url(key.accountKeyId),
      b64url(slot.wrapped),
    ];
    final logged = [
      for (final d in [a, b])
        for (final r in d.logs.rows) '${r.message} ${r.dataJson ?? ''}',
    ];
    expect(logged, isNotEmpty);
    for (final line in logged) {
      for (final secret in secrets) {
        expect(line, isNot(contains(secret)));
      }
    }
  });

  group('passphrase', () {
    List<String> slotTypes() => [
          for (final s in _accountKeyMails(server).single.mail.payload.slots)
            s.type,
        ];

    Future<_Device> unlocked() async {
      final a = await device();
      await a.service.createKey(_acc);
      return a;
    }

    test('adding writes version + 1 and deletes the old key mail', () async {
      final a = await unlocked();
      final before = _accountKeyMails(server).single;
      expect(await a.service.hasPassphraseSlot(_acc), isFalse);

      await a.service.addPassphraseSlot(_acc, _passphrase);

      final after = _accountKeyMails(server).single;
      expect(
        after.mail.payload.slotListVersion,
        before.mail.payload.slotListVersion + 1,
      );
      expect(slotTypes(), [UnlockSlotType.recovery, UnlockSlotType.passphrase]);
      expect(
        await after.mail.verify(await (await a.keys.load(_acc))!.kSlots()),
        isTrue,
      );
      expect(await a.service.hasPassphraseSlot(_acc), isTrue);
      expect(a.events, contains('mos.passphrase_slot_added'));
    });

    test('changing replaces the slot: still exactly one', () async {
      final a = await unlocked();
      await a.service.addPassphraseSlot(_acc, _passphrase);
      await a.service.addPassphraseSlot(_acc, 'gravel orbit maple lantern');

      expect(slotTypes(), [UnlockSlotType.recovery, UnlockSlotType.passphrase]);
      final b = await device();
      await expectLater(
        b.service.unlockWithPassphrase(_acc, _passphrase),
        throwsA(isA<UnlockFailed>()),
      );
      await b.service.unlockWithPassphrase(_acc, 'gravel orbit maple lantern');
      expect(await b.status(), PersonalDataStatus.unlocked);
    });

    test('a fresh device unlocks with it; a wrong one fails', () async {
      final a = await unlocked();
      await a.service.addPassphraseSlot(_acc, _passphrase);
      final b = await device();
      await b.store.sync(_acc);
      expect(await b.status(), PersonalDataStatus.locked);
      expect(await b.service.hasPassphraseSlot(_acc), isTrue);

      await expectLater(
        b.service.unlockWithPassphrase(_acc, '$_passphrase!'),
        throwsA(
          isA<UnlockFailed>()
              .having((e) => e.reason, 'reason', UnlockFailure.noSlotOpens),
        ),
      );
      expect(await b.keys.load(_acc), isNull);

      await b.service.unlockWithPassphrase(_acc, _passphrase);

      final ka = (await a.keys.load(_acc))!;
      final kb = (await b.keys.load(_acc))!;
      expect(kb.accountKeyId, ka.accountKeyId);
      expect(kb.key.bytes, ka.key.bytes);
      expect(await b.status(), PersonalDataStatus.unlocked);
      expect(
        b.logs.rows.where((r) => r.event == 'mos.key_unlocked').single.dataJson,
        contains('passphrase'),
      );
      // Never the passphrase in the logs.
      for (final d in [a, b]) {
        for (final r in d.logs.rows) {
          expect('${r.message} ${r.dataJson ?? ''}', isNot(contains('violet')));
        }
      }
    });

    test('a weak passphrase is refused; nothing is written', () async {
      final a = await unlocked();
      final ids = server.messageIds;
      final syncs = a.store.syncs;

      for (final (weak, reason) in [
        ('short', PassphraseWeakness.tooShort),
        ('password1234', PassphraseWeakness.common),
        ('alice@example.com rocks', PassphraseWeakness.containsAccountName),
      ]) {
        await expectLater(
          a.service.addPassphraseSlot(_acc, weak),
          throwsA(
            isA<WeakPassphrase>().having((e) => e.weakness, 'weakness', reason),
          ),
        );
      }
      expect(server.messageIds, ids);
      expect(a.store.syncs, syncs);
      expect(a.store.rows.where((r) => r.pendingUpload), isEmpty);
    });

    test('removing keeps the recovery slot', () async {
      final a = await unlocked();
      await a.service.addPassphraseSlot(_acc, _passphrase);

      await a.service.removePassphraseSlot(_acc);

      expect(slotTypes(), [UnlockSlotType.recovery]);
      expect(_accountKeyMails(server).single.mail.payload.slotListVersion, 3);
      expect(await a.service.hasPassphraseSlot(_acc), isFalse);
      expect(a.events, contains('mos.passphrase_slot_removed'));
    });

    test('a locked device cannot change slots', () async {
      await unlocked();
      final b = await device();
      await b.store.sync(_acc);
      await expectLater(
        b.service.addPassphraseSlot(_acc, _passphrase),
        throwsA(isA<KeySetupException>()),
      );
      await expectLater(
        b.service.removePassphraseSlot(_acc),
        throwsA(isA<KeySetupException>()),
      );
    });

    test('offline: nothing is appended', () async {
      final a = await unlocked();
      final rows = a.store.rows.length;
      a.store.offline = true;

      await expectLater(
        a.service.addPassphraseSlot(_acc, _passphrase),
        throwsA(isA<KeyMailOfflineException>()),
      );
      expect(a.store.rows, hasLength(rows));
      expect(a.store.rows.where((r) => r.pendingUpload), isEmpty);
    });

    test('the server not taking the new mail keeps the old one', () async {
      final a = await unlocked();
      final old = _accountKeyMails(server).single.messageId;
      var syncs = 0;
      a.store.betweenPullAndPush = () {
        // The first sync pulls; the one after the append fails.
        if (++syncs == 2) throw const SocketException('offline');
      };

      await expectLater(
        a.service.addPassphraseSlot(_acc, _passphrase),
        throwsA(isA<KeyMailOfflineException>()),
      );
      expect(server.messageIds, contains(old));
      expect(a.store.rows.map((r) => r.messageId), contains(old));
      expect(a.store.rows.where((r) => r.pendingDelete), isEmpty);
    });

    test('a slot with params above the caps is skipped', () async {
      final a = await unlocked();
      final key = (await a.keys.load(_acc))!;
      final current = _accountKeyMails(server).single;
      final slot = await wrapPassphraseSlot(
        key,
        _passphrase,
        params: const Argon2idParams(memoryKiB: 1 << 22),
        deriver: _cheapArgon2id,
      );
      final payload = current.mail.payload.withSlotAdded(slot);
      final messageId = newMessageId();
      server.append(
        messageId,
        buildKeyMail(
          messageId: messageId,
          mail: await payload.serialize(await key.kSlots()),
          date: DateTime.now(),
        ),
      );
      final b = await device();

      await expectLater(
        b.service.unlockWithPassphrase(_acc, _passphrase),
        throwsA(isA<UnlockFailed>()),
      );
      expect(b.events, contains('mos.unlock_slot_skipped'));
    });
  });

  group('passkey', () {
    late FakePasskeyVault vault;
    setUp(() => vault = FakePasskeyVault());

    List<String> slotTypes() => [
          for (final s in _accountKeyMails(server).single.mail.payload.slots)
            s.type,
        ];

    Future<_Device> unlocked() async {
      final a = await device(prf: FakePrfProvider(vault));
      await a.service.createKey(_acc);
      return a;
    }

    Future<UnlockFailure> unlockFailure(_Device d) async {
      try {
        await d.service.unlockWithPasskey(_acc);
      } on UnlockFailed catch (e) {
        return e.reason;
      }
      fail('unlocked');
    }

    test('adding writes version + 1 and keeps the recovery slot', () async {
      final a = await unlocked();
      final before = _accountKeyMails(server).single;
      expect(a.service.passkeysAvailable, isTrue);
      expect(await a.service.passkeySlots(_acc), isEmpty);

      final info = await a.service.addPasskeySlot(_acc, label: ' Phone ');

      final after = _accountKeyMails(server).single;
      expect(
        after.mail.payload.slotListVersion,
        before.mail.payload.slotListVersion + 1,
      );
      expect(slotTypes(), [UnlockSlotType.recovery, UnlockSlotType.passkeyPrf]);
      expect(
        await after.mail.verify(await (await a.keys.load(_acc))!.kSlots()),
        isTrue,
      );
      expect(info.label, 'Phone');
      expect(info.rpId, passkeyRpId);
      final slots = await a.service.passkeySlots(_acc);
      expect(slots.single.slotIdB64, info.slotIdB64);
      expect(a.prf!.registrations.single.rpId, passkeyRpId);
      expect(a.prf!.registrations.single.userName, 'alice@example.com');
      // Checked right after creating: the same credential and salt.
      expect(a.prf!.evaluations.single, {
        info.credentialIdB64: info.prfSalt,
      });
      expect(a.events, contains('mos.passkey_slot_added'));
    });

    test('two passkeys side by side; a second device unlocks with either',
        () async {
      final a = await unlocked();
      final first = await a.service.addPasskeySlot(_acc, label: 'Google');
      final second = await a.service.addPasskeySlot(_acc, label: 'Bitwarden');
      expect(slotTypes(), [
        UnlockSlotType.recovery,
        UnlockSlotType.passkeyPrf,
        UnlockSlotType.passkeyPrf,
      ]);
      expect(
        [for (final p in await a.service.passkeySlots(_acc)) p.label],
        ['Google', 'Bitwarden'],
      );

      final b = await device(prf: FakePrfProvider(vault));
      await b.store.sync(_acc);
      expect(await b.status(), PersonalDataStatus.locked);
      // Locked: the slots of the key mails, for the unlock button.
      expect(await b.service.passkeySlots(_acc), hasLength(2));
      b.prf!.pick = second.credentialIdB64;

      await b.service.unlockWithPasskey(_acc);

      // One dialog for both passkeys.
      expect(b.prf!.evaluations.single, {
        first.credentialIdB64: first.prfSalt,
        second.credentialIdB64: second.prfSalt,
      });
      final ka = (await a.keys.load(_acc))!;
      final kb = (await b.keys.load(_acc))!;
      expect(kb.accountKeyId, ka.accountKeyId);
      expect(kb.key.bytes, ka.key.bytes);
      expect(b.ring.hasWriteKey(_acc, personalCollectionId), isTrue);
      expect(await b.status(), PersonalDataStatus.unlocked);
      expect(
        b.logs.rows.where((r) => r.event == 'mos.key_unlocked').single.dataJson,
        contains('passkey'),
      );

      final c = await device(prf: FakePrfProvider(vault));
      c.prf!.pick = first.credentialIdB64;
      await c.service.unlockWithPasskey(_acc);
      expect((await c.keys.load(_acc))!.key.bytes, ka.key.bytes);
    });

    test('unlocks offline from the key mails seen before', () async {
      final a = await unlocked();
      await a.service.addPasskeySlot(_acc);
      final b = await device(prf: FakePrfProvider(vault));
      await b.store.sync(_acc);
      b.store.offline = true;

      await b.service.unlockWithPasskey(_acc);

      expect(await b.status(), PersonalDataStatus.unlocked);
    });

    test('no PRF: nothing is written', () async {
      final a = await unlocked();
      final ids = server.messageIds;
      a.prf!.noPrf = true;

      await expectLater(
        a.service.addPasskeySlot(_acc),
        throwsA(isA<PrfUnsupported>()),
      );
      a.prf!
        ..noPrf = false
        ..answerOther = true;
      await expectLater(
        a.service.addPasskeySlot(_acc),
        throwsA(isA<PrfUnsupported>()),
      );

      expect(server.messageIds, ids);
      expect(a.store.rows.where((r) => r.pendingUpload), isEmpty);
      expect(await a.service.passkeySlots(_acc), isEmpty);
    });

    test('cancel while adding: nothing is written', () async {
      final a = await unlocked();
      final ids = server.messageIds;
      a.prf!.cancel = true;

      await expectLater(
        a.service.addPasskeySlot(_acc),
        throwsA(isA<PrfCancelled>()),
      );
      expect(server.messageIds, ids);
    });

    test('offline: no passkey is created, nothing is appended', () async {
      final a = await unlocked();
      final rows = a.store.rows.length;
      a.store.offline = true;

      await expectLater(
        a.service.addPasskeySlot(_acc),
        throwsA(isA<KeyMailOfflineException>()),
      );
      expect(a.prf!.registrations, isEmpty);
      expect(a.store.rows, hasLength(rows));
    });

    test('unlock failures are typed', () async {
      final a = await unlocked();
      final b = await device(prf: FakePrfProvider(vault));
      await b.store.sync(_acc);
      expect(await unlockFailure(b), UnlockFailure.noPasskeySlot);
      expect(b.prf!.evaluations, isEmpty);

      final info = await a.service.addPasskeySlot(_acc);
      await b.store.sync(_acc);
      b.prf!.cancel = true;
      expect(await unlockFailure(b), UnlockFailure.passkeyCancelled);
      b.prf!
        ..cancel = false
        ..noPrf = true;
      expect(await unlockFailure(b), UnlockFailure.passkeyUnsupported);
      b.prf!
        ..noPrf = false
        ..answerOther = true;
      expect(await unlockFailure(b), UnlockFailure.noSlotOpens);

      // Deleted from the password manager.
      b.prf!.answerOther = false;
      vault.secrets.remove(info.credentialIdB64);
      expect(await unlockFailure(b), UnlockFailure.noSlotOpens);

      expect(await b.keys.load(_acc), isNull);
      expect(
        [
          for (final r in b.logs.rows)
            if (r.event == 'mos.key_unlock_failed') r.dataJson,
        ],
        everyElement(contains('passkey')),
      );
    });

    test('removing one passkey keeps the others and the recovery slot',
        () async {
      final a = await unlocked();
      final first = await a.service.addPasskeySlot(_acc, label: 'one');
      final second = await a.service.addPasskeySlot(_acc, label: 'two');

      await a.service.removePasskeySlot(_acc, first.slotIdB64);

      expect(slotTypes(), [UnlockSlotType.recovery, UnlockSlotType.passkeyPrf]);
      expect(
        (await a.service.passkeySlots(_acc)).single.slotIdB64,
        second.slotIdB64,
      );
      expect(a.events, contains('mos.passkey_slot_removed'));

      // The removed passkey is no longer asked for.
      final b = await device(prf: FakePrfProvider(vault));
      b.prf!.pick = first.credentialIdB64;
      await b.service.unlockWithPasskey(_acc);
      expect(b.prf!.evaluations.single.keys, [second.credentialIdB64]);
    });

    test('removing the recovery slot is refused; nothing is written', () async {
      final a = await unlocked();
      await a.service.addPasskeySlot(_acc);
      final ids = server.messageIds;
      final recovery = _accountKeyMails(server)
          .single
          .mail
          .payload
          .slots
          .firstWhere((s) => s.type == UnlockSlotType.recovery);

      await expectLater(
        a.service.removePasskeySlot(_acc, recovery.slotIdB64),
        throwsArgumentError,
      );
      await expectLater(
        a.service.removePasskeySlot(_acc, 'nope'),
        throwsArgumentError,
      );
      expect(server.messageIds, ids);
      expect(a.store.rows.where((r) => r.pendingUpload), isEmpty);
    });

    test('a locked device cannot change passkeys', () async {
      await unlocked();
      final b = await device(prf: FakePrfProvider(vault));
      await b.store.sync(_acc);
      await expectLater(
        b.service.addPasskeySlot(_acc),
        throwsA(isA<KeySetupException>()),
      );
      await expectLater(
        b.service.removePasskeySlot(_acc, 'x'),
        throwsA(isA<KeySetupException>()),
      );
      expect(b.prf!.registrations, isEmpty);
    });

    test('without a provider there are no passkeys', () async {
      final a = await device();
      expect(a.service.passkeysAvailable, isFalse);
      await expectLater(
        () => a.service.addPasskeySlot(_acc),
        throwsStateError,
      );
      await expectLater(
        () => a.service.unlockWithPasskey(_acc),
        throwsStateError,
      );
    });

    test('a malformed passkey slot is skipped', () async {
      final a = await unlocked();
      final key = (await a.keys.load(_acc))!;
      final info = await a.service.addPasskeySlot(_acc);
      final current = _accountKeyMails(server).single;
      final good = current.mail.payload.slots.last;
      // Same credential, a salt of the wrong length.
      final bad = UnlockSlot.fromJson({
        ...good.toJson(),
        'slotId': b64url(seqBytes(1, 16)),
        'prfSalt': b64url(seqBytes(1, 8)),
      });
      final payload = current.mail.payload.withSlotAdded(bad);
      final messageId = newMessageId();
      server.append(
        messageId,
        buildKeyMail(
          messageId: messageId,
          mail: await payload.serialize(await key.kSlots()),
          date: DateTime.now(),
        ),
      );
      final b = await device(prf: FakePrfProvider(vault));
      await b.store.sync(_acc);
      expect(await b.service.passkeySlots(_acc), hasLength(1));

      await b.service.unlockWithPasskey(_acc);

      expect(b.prf!.evaluations.single.keys, [info.credentialIdB64]);
      expect(await b.status(), PersonalDataStatus.unlocked);
    });

    test('no PRF output, salt or credential id reaches the logs', () async {
      final a = await unlocked();
      final info = await a.service.addPasskeySlot(_acc, label: 'Phone');
      final b = await device(prf: FakePrfProvider(vault));
      await b.service.unlockWithPasskey(_acc);
      final slot = _accountKeyMails(server).single.mail.payload.slots.last;

      final secrets = [
        info.credentialIdB64,
        b64url(info.prfSalt),
        b64url(slot.wrapped),
        b64url(vault.secrets[info.credentialIdB64]!),
      ];
      for (final d in [a, b]) {
        for (final r in d.logs.rows) {
          final line = '${r.message} ${r.dataJson ?? ''}';
          for (final secret in secrets) {
            expect(line, isNot(contains(secret)));
          }
        }
      }
    });
  });

  group('pairing', () {
    List<String> pairingMailsOnServer() => [
          for (final m in server.mails.values)
            if (_isPairingMail(m.mail)) m.messageId,
        ];

    /// A unlocked, B locked with A's key mails.
    Future<(_Device, _Device)> pair() async {
      final a = await device();
      await a.service.createKey(_acc);
      final b = await device();
      await b.store.sync(_acc);
      expect(await b.status(), PersonalDataStatus.locked);
      return (a, b);
    }

    Matcher rejected(PairingRejection reason) => throwsA(
          isA<PairingRejected>().having((e) => e.reason, 'reason', reason),
        );

    test('via the pairing mail: B gets A’s key, the mail is deleted', () async {
      final (a, b) = await pair();
      final start = await b.service.startPairing(_acc);
      expect(start.expiresAt.isAfter(DateTime.now()), isTrue);

      final code = await a.service.sendPairing(_acc, start.request);
      await a.store.sync(_acc);
      expect(pairingMailsOnServer(), hasLength(1));

      await b.service.checkPairing(_acc);

      final ka = (await a.keys.load(_acc))!;
      final kb = (await b.keys.load(_acc))!;
      expect(kb.accountKeyId, ka.accountKeyId);
      expect(kb.key.bytes, ka.key.bytes);
      expect(
        b.ring.writeKey(_acc, personalCollectionId)!.keyId,
        a.ring.writeKey(_acc, personalCollectionId)!.keyId,
      );
      expect(await b.status(), PersonalDataStatus.unlocked);
      expect(pairingMailsOnServer(), isEmpty);
      expect(a.events, contains('mos.pairing_sent'));
      expect(
        b.events,
        containsAll(['mos.pairing_accepted', 'mos.key_unlocked']),
      );

      // A drops its copy once it is gone from the server.
      await a.store.sync(_acc);
      expect(a.store.rows.where((r) => _isPairingMail(r.payload!)), isEmpty);

      // Neither the request, the code nor the key reach the logs.
      final logged = [
        for (final d in [a, b])
          for (final r in d.logs.rows) '${r.message} ${r.dataJson ?? ''}',
      ];
      for (final line in logged) {
        for (final secret in [
          start.request.substring(pairingRequestPrefix.length),
          code.substring(pairingCodePrefix.length),
          b64url(ka.key.bytes),
          b64url(ka.accountKeyId),
        ]) {
          expect(line, isNot(contains(secret)));
        }
      }
    });

    test('via the paste code, offline', () async {
      final (a, b) = await pair();
      final start = await b.service.startPairing(_acc);
      final code = await a.service.sendPairing(_acc, start.request);
      b.store.offline = true;

      await b.service.acceptPairingCode(_acc, code);

      expect(
        (await b.keys.load(_acc))!.key.bytes,
        (await a.keys.load(_acc))!.key.bytes,
      );
      expect(await b.status(), PersonalDataStatus.unlocked);
    });

    test('a request of another account is refused before sending', () async {
      final (a, _) = await pair();
      final other = await device(
        account: const Account(
          id: _acc,
          displayName: 'Bob',
          email: 'bob@example.com',
          imapHost: 'mail.example.com',
        ),
      );
      final start = await other.service.startPairing(_acc);
      final rows = a.store.rows.length;

      await expectLater(
        a.service.sendPairing(_acc, start.request),
        rejected(PairingRejection.wrongAccount),
      );
      await expectLater(
        a.service.sendPairing(_acc, 'sharedinbox.de:pubkey:v1:AAAA'),
        rejected(PairingRejection.badFormat),
      );
      expect(a.store.rows, hasLength(rows));
      expect(a.events, contains('mos.pairing_rejected'));
    });

    test('sendPairing without a local key throws', () async {
      final (_, b) = await pair();
      final start = await b.service.startPairing(_acc);
      await expectLater(
        b.service.sendPairing(_acc, start.request),
        throwsStateError,
      );
    });

    test('a key of a losing group or failing the MAC is not kept', () async {
      final (a, b) = await pair();
      final winner = (await a.keys.load(_acc))!;
      // A later key mail of another key: a losing group.
      final loser = AccountKey.generate();
      final payload = KeyMailPayload(
        accountKeyId: loser.accountKeyId,
        slotListVersion: 1,
        slots: [await wrapRecoverySlot(loser, RecoveryKey.generate())],
      );
      final loserMail = newMessageId();
      server.append(
        loserMail,
        buildKeyMail(
          messageId: loserMail,
          mail: await payload.serialize(await loser.kSlots()),
          date: DateTime.now(),
        ),
      );
      final start = await b.service.startPairing(_acc);
      final request = parsePairingRequest(start.request)!;

      Future<Uint8List> sealed(AccountKey key) => sealPairing(
            request: request,
            accountKey: key,
            issuedAt: DateTime.now(),
          );

      // Over the paste path.
      for (final key in [
        loser,
        AccountKey(winner.accountKeyId, AccountKey.generate().key.bytes),
      ]) {
        await expectLater(
          b.service
              .acceptPairingCode(_acc, encodePairingCode(await sealed(key))),
          rejected(PairingRejection.keyMismatch),
        );
      }

      // Over the mail path: rejected once, left to expire.
      final messageId = newMessageId();
      server.append(
        messageId,
        buildPairingMail(
          messageId: messageId,
          ecies: await sealed(loser),
          date: DateTime.now(),
        ),
      );
      await b.service.checkPairing(_acc);
      await b.service.checkPairing(_acc);

      expect(await b.keys.load(_acc), isNull);
      expect(await b.status(), PersonalDataStatus.locked);
      expect(pairingMailsOnServer(), [messageId]);
      final rejections =
          b.logs.rows.where((r) => r.event == 'mos.pairing_rejected');
      expect(rejections, hasLength(3));
      expect(rejections.last.dataJson, contains('keyMismatch'));
    });

    test('expired pairing mails are deleted in the foreground only', () async {
      final (a, _) = await pair();
      final stale = newMessageId();
      final fresh = newMessageId();
      final now = DateTime.now();
      for (final (id, date) in [
        (stale, now.subtract(const Duration(minutes: 26))),
        (fresh, now.subtract(const Duration(minutes: 24))),
      ]) {
        server.append(
          id,
          buildPairingMail(
            messageId: id,
            ecies: Uint8List.fromList(List.filled(80, 7)),
            date: date,
          ),
        );
      }
      await a.store.sync(_acc);

      await a.service.afterSync(_acc, foreground: false);
      await a.store.sync(_acc);
      expect(pairingMailsOnServer(), hasLength(2));

      await a.service.afterSync(_acc, foreground: true);
      await a.store.sync(_acc);
      expect(pairingMailsOnServer(), [fresh]);
      final deleted = a.logs.rows
          .singleWhere((r) => r.event == 'mos.pairing_expired_deleted');
      expect(deleted.dataJson, contains('"count":1'));
    });

    test('a vanished pairing mail is never uploaded again', () async {
      final (a, b) = await pair();
      final start = await b.service.startPairing(_acc);
      await a.service.sendPairing(_acc, start.request);
      await a.store.sync(_acc);
      final row = a.store.rows.singleWhere((r) => _isPairingMail(r.payload!));

      expect(await a.service.keepVanishedKeyMail(_acc, row), isFalse);
    });
  });
}

bool _isPairingMail(Uint8List mail) {
  try {
    parsePairingMail(mail);
    return true;
  } on FormatException {
    return false;
  }
}
