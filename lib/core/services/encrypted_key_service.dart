import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart';

import 'package:sharedinbox/core/encrypted_objects/account_key_store.dart';
import 'package:sharedinbox/core/encrypted_objects/collection_key_mail.dart';
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
import 'package:sharedinbox/core/models/mail_object.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/core/repositories/share_key_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/core/services/share_encryption_service.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;

/// [SyncStates.resourceType] of the key-creation state of an account:
/// JSON `{phase, ownMessageId, committed}`, never key material.
const keyStateResourceType = 'mos:key-state';

/// Where this device is in the key-creation race (4.3).
enum KeyPhase {
  none,

  /// Own key mail appended, the race not decided yet.
  pending,
  won,

  /// Another device's key won; this device dropped its own.
  lost,
}

/// What the personal-data screen shows for an account.
enum PersonalDataStatus {
  /// No key mail on the server, no key here.
  notSetUp,

  /// A key mail exists, but this device has no key: unlock.
  locked,
  unlocked,

  /// Unlocked, but the keys folder also has a key mail of another account
  /// key (4.3: this device never yields; it only warns).
  foreignKeyWarning,

  /// The setup of this device lost the race: unlock with the other
  /// device's recovery key.
  lostRace,

  /// The setup was interrupted before the race was decided.
  setupInterrupted,
}

sealed class CreateKeyResult {
  const CreateKeyResult();
}

/// This device won: show [formatted] once.
final class KeyCreated extends CreateKeyResult {
  const KeyCreated(this.recoveryKey, this.formatted);

  final RecoveryKey recoveryKey;
  final String formatted;
}

/// A key mail exists already; nothing was created.
final class KeyAlreadyExists extends CreateKeyResult {
  const KeyAlreadyExists();
}

/// Another device's key won the race.
final class KeyRaceLost extends CreateKeyResult {
  const KeyRaceLost();
}

enum UnlockFailure {
  badFormat,
  badChecksum,
  noSlotOpens,

  /// The account has no passkey slot.
  noPasskeySlot,
  passkeyCancelled,

  /// The password manager has no PRF.
  passkeyUnsupported,
}

class UnlockFailed implements Exception {
  const UnlockFailed(this.reason);

  final UnlockFailure reason;

  @override
  String toString() => 'UnlockFailed: ${reason.name}';
}

/// The server did not confirm the own key mail.
class KeySetupException implements Exception {
  const KeySetupException(this.message);

  final String message;

  @override
  String toString() => 'KeySetupException: $message';
}

/// Changing the slots needs the server: it was not reachable before the
/// key mail was rewritten, or did not take the new key mail.
class KeyMailOfflineException implements Exception {
  const KeyMailOfflineException(this.cause);

  final Object cause;

  @override
  String toString() => 'KeyMailOfflineException: $cause';
}

/// The passphrase does not meet the minimum strength; nothing was written.
class WeakPassphrase implements Exception {
  const WeakPassphrase(this.weakness);

  final PassphraseWeakness weakness;

  @override
  String toString() => 'WeakPassphrase: ${weakness.name}';
}

/// One account-key mail of the keys folder and its UID (null until the
/// server confirmed it).
typedef KeyMailEntry = ({String messageId, SignedKeyMail mail, int? uid});

/// The `accountKeyId` (base64url) of the group that won the race (4.3):
/// the one whose first key mail has the lowest UID, tie → lowest
/// `accountKeyId`. Mails without a UID take no part. Null if none has one.
String? keyRaceWinner(Iterable<KeyMailEntry> mails) {
  ({int uid, Uint8List id})? best;
  for (final m in mails) {
    final uid = m.uid;
    if (uid == null) continue;
    final id = m.mail.payload.accountKeyId;
    final b = best;
    if (b == null ||
        uid < b.uid ||
        (uid == b.uid && _compareBytes(id, b.id) < 0)) {
      best = (uid: uid, id: id);
    }
  }
  final b = best;
  return b == null ? null : b64url(b.id);
}

int _compareBytes(Uint8List a, Uint8List b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}

/// What a passphrase of [account] must not contain: the email address, its
/// local part and the username.
List<String> passphraseContext(Account account) => [
      account.email,
      account.email.split('@').first,
      account.username,
    ];

/// A pairing request this device shows, and when its key pair expires.
typedef PairingStart = ({String request, DateTime expiresAt});

typedef _KeyState = ({KeyPhase phase, String? ownMessageId, bool committed});

const _noState = (phase: KeyPhase.none, ownMessageId: null, committed: false);

/// Key lifecycle of the encrypted personal data (`ENCRYPTED-OBJECTS.md`
/// 4.2, 4.3, 9): key mail and collection-key mails in `SharedInbox/Keys`
/// via the [MailObjectStore], the key-creation race, the passphrase and
/// passkey slots and unlocking with the recovery key, the passphrase or a
/// passkey. Fills the shared [KeyRing].
///
/// Logs event names, counts and Message-IDs only — never slots, MACs,
/// keys, the recovery key, the passphrase, PRF outputs, credential ids or
/// `accountKeyId`s.
class EncryptedKeyService {
  EncryptedKeyService({
    required AppDatabase db,
    required MailObjectStore store,
    required AccountKeyStore keys,
    required KeyRing ring,
    required Future<bool> Function() betaEnabled,
    Future<void> Function(String accountId)? listFolders,
    ShareKeyRepository? shareKeys,
    Future<Account?> Function(String accountId)? findAccount,
    AppLogger? appLogger,
    DateTime Function()? now,
    PassphraseDeriver deriver = argon2idInIsolate,
    PrfProvider? prf,
  })  : _db = db,
        _store = store,
        _keys = keys,
        _ring = ring,
        _betaEnabled = betaEnabled,
        _listFolders = listFolders,
        _shareKeys = shareKeys,
        _findAccount = findAccount,
        _appLogger = appLogger,
        _now = now ?? DateTime.now,
        _deriver = deriver,
        _prf = prf {
    ring.onWriteKeyUsed = (accountId) {
      unawaited(_markCommitted(accountId));
    };
    ring.keepVanished = keepVanishedKeyMail;
  }

  final AppDatabase _db;
  final MailObjectStore _store;
  final AccountKeyStore _keys;
  final KeyRing _ring;
  final Future<bool> Function() _betaEnabled;
  final Future<void> Function(String accountId)? _listFolders;

  /// The ephemeral key pairs of pairing; null (e.g. in the background
  /// isolate): no pairing mail is opened.
  final ShareKeyRepository? _shareKeys;
  final Future<Account?> Function(String accountId)? _findAccount;
  final AppLogger? _appLogger;
  final DateTime Function() _now;

  /// Argon2id of the passphrase slot; tests inject cheap params or a spy.
  final PassphraseDeriver _deriver;

  /// The platform passkeys with PRF; null where there are none (Linux, the
  /// background isolate): no passkey slot is added or used.
  final PrfProvider? _prf;

  final _changes = StreamController<String>.broadcast();

  // ── Status ────────────────────────────────────────────────────────────────

  Future<PersonalDataStatus> status(String accountId) async {
    final state = await _loadState(accountId);
    if (state.phase == KeyPhase.lost) return PersonalDataStatus.lostRace;
    if (state.phase == KeyPhase.pending) {
      return PersonalDataStatus.setupInterrupted;
    }
    final key = await _localKey(accountId);
    final mails = await _accountKeyMails(accountId);
    if (key == null) {
      return mails.isEmpty
          ? PersonalDataStatus.notSetUp
          : PersonalDataStatus.locked;
    }
    return _foreignCount(mails, key) > 0
        ? PersonalDataStatus.foreignKeyWarning
        : PersonalDataStatus.unlocked;
  }

  /// [status], again on every change of the keys folder or of this
  /// service's state.
  Stream<PersonalDataStatus> watchStatus(String accountId) {
    // Closed by its listener's cancel.
    // ignore: close_sinks
    late final StreamController<PersonalDataStatus> out;
    final subs = <StreamSubscription<Object?>>[];
    var chain = Future<void>.value();
    void emit() {
      chain = chain.then((_) async {
        final s = await status(accountId);
        if (!out.isClosed) out.add(s);
      }).catchError((Object e) {
        if (!out.isClosed) out.addError(e);
      });
    }

    out = StreamController<PersonalDataStatus>(
      onListen: () {
        subs
          ..add(
            _store
                .observe(accountId, MailObjectFolder.keys)
                .listen((_) => emit()),
          )
          ..add(
            _changes.stream
                .where((id) => id == accountId)
                .listen((_) => emit()),
          );
      },
      onCancel: () async {
        for (final s in subs) {
          await s.cancel();
        }
      },
    );
    return out.stream.distinct();
  }

  // ── Sync hook ─────────────────────────────────────────────────────────────

  /// Whether the keys-folder mail [row], gone from the server, is uploaded
  /// again (4.3): the own pending setup's key mail, and the current key
  /// mail and the collection keys of the key this device holds. A race
  /// loser's mail, a replaced slot list and mails of a key this device
  /// does not hold are dropped locally. Never takes the lock: it runs
  /// inside the store's sync.
  Future<bool> keepVanishedKeyMail(String accountId, MailObject row) async {
    final parsed = _parse(row);
    if (parsed == null) return false;
    final state = await _loadState(accountId);
    if (state.phase == KeyPhase.pending &&
        state.ownMessageId == row.messageId) {
      return true;
    }
    final key = await _localKey(accountId);
    if (key == null) return false;
    switch (parsed) {
      case CollectionKeyMailMsg(:final mail):
        return constantTimeEquals(mail.accountKeyId, key.accountKeyId);
      case AccountKeyMailMsg(:final mail):
        if (!constantTimeEquals(mail.payload.accountKeyId, key.accountKeyId)) {
          return false;
        }
        final version = mail.payload.slotListVersion;
        final group = (await _accountKeyMails(accountId)).where(
          (e) => constantTimeEquals(
            e.mail.payload.accountKeyId,
            key.accountKeyId,
          ),
        );
        return !group.any((e) => e.mail.payload.slotListVersion > version);
    }
  }

  /// Fills the ring from the device key and the local keys-folder rows,
  /// e.g. in the background isolate before its sync.
  Future<void> loadKeys(String accountId) async {
    if (!await _betaEnabled()) return;
    final key = await _localKey(accountId);
    if (key == null) return;
    await _loadCollectionKeys(accountId, key, await _keyRows(accountId));
  }

  /// Runs after each object sync. A no-op unless the beta switch is on and
  /// the account has a key, key mails or a setup in progress. Loads new
  /// collection keys and warns about a foreign key mail; in the
  /// [foreground] it also settles an interrupted setup that lost the race
  /// and deletes expired pairing mails. A locked device opens the pairing
  /// mails sent to it. The background never changes the phase and never
  /// deletes.
  Future<void> afterSync(String accountId, {required bool foreground}) async {
    if (!await _betaEnabled()) return;
    await _exclusive(accountId, () async {
      final state = await _loadState(accountId);
      var key = await _localKey(accountId);
      final rows = await _keyRows(accountId);
      if (key == null && rows.isEmpty && state.phase == KeyPhase.none) return;
      if (foreground) await _deleteExpiredPairings(accountId, rows);
      if (key == null && foreground) {
        await _acceptPairingMails(accountId, rows);
        key = await _localKey(accountId);
      }
      if (key != null) {
        if (await _loadCollectionKeys(accountId, key, rows)) {
          await _store.reopen(accountId);
        }
        final foreign = _foreignCount(_parseAccountKeyMails(rows), key);
        if (foreign > 0) {
          unawaited(
            _appLogger?.warn(
              'mos.foreign_key_mail',
              'The keys folder has a key mail of another key; this device '
                  'keeps its own key',
              accountId: accountId,
              data: {'count': foreign},
            ),
          );
        }
      }
      if (foreground && state.phase == KeyPhase.pending) {
        await _settleInterrupted(accountId, state);
      }
    });
    _changed(accountId);
  }

  /// An interrupted setup: decide the race from the listing. A loss is
  /// cleaned up here; a win waits for the screen, which shows the new
  /// recovery key ([createKey]).
  Future<void> _settleInterrupted(String accountId, _KeyState state) async {
    final pending = await _keys.loadPending(accountId);
    final own = state.ownMessageId;
    if (pending == null || own == null) {
      await _saveState(accountId, _noState);
      return;
    }
    final entries = await _accountKeyMails(accountId);
    final mine = entries.where((e) => e.messageId == own).firstOrNull;
    if (mine?.uid == null) return;
    if (keyRaceWinner(entries) == b64url(pending.accountKeyId)) return;
    await _lose(accountId, own);
  }

  // ── Setup ─────────────────────────────────────────────────────────────────

  /// Creates the account key (4.3); call in the foreground only. The
  /// recovery key is returned only after the re-list confirmed the win.
  /// Resumes an interrupted setup. Throws when the server is unreachable;
  /// an interrupted setup is then resumed by the next call.
  Future<CreateKeyResult> createKey(String accountId) async {
    final result = await _exclusive(accountId, () => _createKey(accountId));
    _changed(accountId);
    return result;
  }

  Future<CreateKeyResult> _createKey(String accountId) async {
    final state = await _loadState(accountId);
    if (state.phase == KeyPhase.pending) {
      final pending = await _keys.loadPending(accountId);
      final own = state.ownMessageId;
      if (pending != null && own != null) {
        return _decide(accountId, pending, own, null);
      }
      await _saveState(accountId, _noState);
    }
    if (await _localKey(accountId) != null) return const KeyAlreadyExists();
    await _listFolders?.call(accountId);
    await _store.sync(accountId);
    if ((await _accountKeyMails(accountId)).isNotEmpty) {
      return const KeyAlreadyExists();
    }
    final accountKey = AccountKey.generate();
    final recoveryKey = RecoveryKey.generate();
    final payload = KeyMailPayload(
      accountKeyId: accountKey.accountKeyId,
      slotListVersion: 1,
      slots: [await wrapRecoverySlot(accountKey, recoveryKey)],
    );
    final messageId = newMessageId();
    await _keys.savePending(accountId, accountKey);
    await _saveState(
      accountId,
      (phase: KeyPhase.pending, ownMessageId: messageId, committed: false),
    );
    await _store.appendRaw(
      accountId,
      buildKeyMail(
        messageId: messageId,
        mail: await payload.serialize(await accountKey.kSlots()),
        date: _now(),
      ),
    );
    unawaited(
      _appLogger?.info(
        'mos.key_created',
        'Created an encrypted-data key; checking no other device was first',
        accountId: accountId,
        data: {'messageId': messageId},
      ),
    );
    return _decide(accountId, accountKey, messageId, recoveryKey);
  }

  /// Pushes the own key mail until the server confirmed it, re-lists and
  /// settles the race. [recoveryKey] is null for a resumed setup: on a
  /// win it gets a fresh recovery slot.
  Future<CreateKeyResult> _decide(
    String accountId,
    AccountKey accountKey,
    String ownMessageId,
    RecoveryKey? recoveryKey,
  ) async {
    KeyMailEntry? mine;
    for (var i = 0; i < 3 && mine?.uid == null; i++) {
      await _store.sync(accountId);
      mine = (await _accountKeyMails(accountId))
          .where((e) => e.messageId == ownMessageId)
          .firstOrNull;
      if (mine == null) {
        // The own key mail is gone locally: start again.
        await _keys.deletePending(accountId);
        await _saveState(accountId, _noState);
        throw const KeySetupException('the new key mail was lost');
      }
    }
    if (mine?.uid == null) {
      throw const KeySetupException('the server did not confirm the key');
    }
    // The re-list: every key mail with a lower UID is visible now.
    await _store.sync(accountId);
    final entries = await _accountKeyMails(accountId);
    final groupId = b64url(accountKey.accountKeyId);
    if (keyRaceWinner(entries) != groupId) {
      await _lose(accountId, ownMessageId);
      return const KeyRaceLost();
    }
    await _keys.save(accountId, accountKey);
    await _keys.deletePending(accountId);
    _ring.setAccountKey(accountId, accountKey);
    unawaited(
      _appLogger?.info(
        'mos.key_race_won',
        'This device set up the encrypted-data key',
        accountId: accountId,
        data: {'messageId': ownMessageId},
      ),
    );
    final shown =
        recoveryKey ?? await _replaceRecoverySlot(accountId, accountKey);
    await _ensurePersonalCollection(accountId, accountKey);
    await _saveState(
      accountId,
      (phase: KeyPhase.won, ownMessageId: ownMessageId, committed: false),
    );
    return KeyCreated(shown, await shown.format());
  }

  /// A fresh recovery slot in place of the old ones (whose recovery key
  /// was never shown).
  Future<RecoveryKey> _replaceRecoverySlot(
    String accountId,
    AccountKey accountKey,
  ) async {
    final recoveryKey = RecoveryKey.generate();
    final slot = await wrapRecoverySlot(accountKey, recoveryKey);
    await _rewriteKeyMail(
      accountId,
      accountKey,
      (slots) => [
        for (final s in slots)
          if (s.type != UnlockSlotType.recovery) s,
        slot,
      ],
    );
    return recoveryKey;
  }

  /// Changes the slots (4.2): pulls the keys folder, appends a key mail at
  /// `slotListVersion + 1` with the slots [edit] returns (unknown fields
  /// kept), and deletes the group's old mails once the server has the new
  /// one. Throws [KeyMailOfflineException] if the server cannot be reached
  /// first — nothing is written then — or did not take the new mail; the
  /// old mails stay in that case (the highest version wins, and the next
  /// rewrite cleans up).
  Future<void> _rewriteKeyMail(
    String accountId,
    AccountKey accountKey,
    List<UnlockSlot> Function(List<UnlockSlot> slots) edit,
  ) async {
    try {
      await _listFolders?.call(accountId);
      await _store.sync(accountId);
    } catch (e) {
      throw KeyMailOfflineException(e);
    }
    final group = [
      for (final e in await _accountKeyMails(accountId))
        if (constantTimeEquals(
          e.mail.payload.accountKeyId,
          accountKey.accountKeyId,
        ))
          e,
    ];
    final current = await selectWinner(group.map((e) => e.mail), accountKey);
    if (current == null) {
      throw const KeySetupException('the own key mail does not verify');
    }
    final payload = KeyMailPayload(
      accountKeyId: accountKey.accountKeyId,
      slotListVersion: current.payload.slotListVersion + 1,
      slots: edit(current.payload.slots),
      extra: current.payload.extra,
    );
    final messageId = newMessageId();
    await _store.appendRaw(
      accountId,
      buildKeyMail(
        messageId: messageId,
        mail: await payload.serialize(await accountKey.kSlots()),
        date: _now(),
      ),
    );
    try {
      await _store.sync(accountId);
    } catch (e) {
      throw KeyMailOfflineException(e);
    }
    for (final e in group) {
      await _store.deleteRaw(accountId, e.messageId);
    }
    try {
      await _store.sync(accountId);
    } catch (_) {
      // Offline: the next foreground sync deletes them.
    }
  }

  /// A write key for [collectionId] (e.g. a new deck, #1379): unless one
  /// is known, a new collection key, its collection-key mail appended and
  /// the key set as the write key. Other devices load it from the mail
  /// ([_loadCollectionKeys]). Throws [StateError] while locked.
  Future<void> ensureCollection(String accountId, String collectionId) =>
      _exclusive(accountId, () async {
        final key = await _localKey(accountId);
        if (key == null) throw StateError('no account key: locked');
        await _ensureCollection(accountId, key, collectionId);
      });

  /// The `personal` collection key: created by the race winner only.
  Future<void> _ensurePersonalCollection(
    String accountId,
    AccountKey accountKey,
  ) =>
      _ensureCollection(accountId, accountKey, personalCollectionId);

  Future<void> _ensureCollection(
    String accountId,
    AccountKey accountKey,
    String collectionId,
  ) async {
    final rows = await _keyRows(accountId);
    await _loadCollectionKeys(accountId, accountKey, rows);
    if (_ring.hasWriteKey(accountId, collectionId)) return;
    final key = CollectionKey.generate(collectionId);
    await _store.appendRaw(
      accountId,
      buildCollectionKeyMail(
        messageId: newMessageId(),
        mail: await CollectionKeyMail.create(accountKey, key),
        date: _now(),
      ),
    );
    _ring.setWriteKey(accountId, key);
    try {
      await _store.sync(accountId);
    } catch (_) {
      // Offline: the collection-key mail goes up with the next sync.
    }
    await _store.reopen(accountId);
  }

  /// Lost the race: never keep the key, never show its recovery key; the
  /// own key mail is removed from the server by the foreground sync.
  Future<void> _lose(String accountId, String ownMessageId) async {
    await _saveState(
      accountId,
      (phase: KeyPhase.lost, ownMessageId: ownMessageId, committed: false),
    );
    await _keys.deletePending(accountId);
    await _store.deleteRaw(accountId, ownMessageId);
    unawaited(
      _appLogger?.info(
        'mos.key_race_lost',
        'Another device set up the encrypted-data key first; this device '
            'dropped its own',
        accountId: accountId,
        data: {'messageId': ownMessageId},
      ),
    );
    try {
      await _store.sync(accountId);
    } catch (_) {
      // Offline: the next foreground sync deletes it.
    }
  }

  // ── Unlock ────────────────────────────────────────────────────────────────

  /// Unlocks with a recovery key as typed by the user: tries every key
  /// mail of the folder; the slot list of the matching key must verify.
  /// Throws [UnlockFailed].
  Future<void> unlockWithRecoveryKey(String accountId, String input) async {
    final RecoveryKey recoveryKey;
    try {
      recoveryKey = await RecoveryKey.parse(input);
    } on RecoveryKeyFormatException catch (e) {
      _logUnlockFailed(accountId, e.reason.name, via: 'recovery');
      throw UnlockFailed(
        e.reason == RecoveryKeyFormatError.checksumMismatch
            ? UnlockFailure.badChecksum
            : UnlockFailure.badFormat,
      );
    }
    await _unlock(
      accountId,
      UnlockSlotType.recovery,
      (slot, accountKeyId) =>
          unwrapRecoverySlot(slot, recoveryKey, accountKeyId),
      via: 'recovery',
    );
  }

  /// Unlocks with the passphrase as typed (exact bytes): tries the
  /// passphrase slot of every key mail, with the salt and params stored in
  /// it. Throws [UnlockFailed].
  Future<void> unlockWithPassphrase(String accountId, String passphrase) {
    // Old key mails of a group repeat the slot: derive each KEK once.
    final keks = <String, Future<SecretKeyData>>{};
    return _unlock(
      accountId,
      UnlockSlotType.passphrase,
      (slot, accountKeyId) async {
        final kdf = passphraseSlotKdf(slot);
        final kek = keks.putIfAbsent(
          '${b64url(kdf.salt)} ${canonicalJson(kdf.params.toJson())}',
          () => derivePassphraseKek(
            passphrase,
            kdf.salt,
            kdf.params,
            deriver: _deriver,
          ),
        );
        return unwrapSlot(slot, await kek, accountKeyId);
      },
      via: 'passphrase',
    );
  }

  /// Unlocks with a passkey: one passkey dialog for the passkey slots of
  /// every key mail (`evalByCredential`), then the slots of the credential
  /// that answered. Works offline from the key mails seen before. Throws
  /// [UnlockFailed] and [StateError] without passkeys.
  Future<void> unlockWithPasskey(String accountId) {
    final prf = _requirePrf();
    late final PrfAssertion answer;
    return _unlock(
      accountId,
      UnlockSlotType.passkeyPrf,
      (slot, accountKeyId) {
        final info = PasskeySlotInfo.parse(slot);
        if (!constantTimeEquals(info.credentialId, answer.credentialId)) {
          throw const KeyUnwrapException('another passkey');
        }
        return unwrapPasskeySlot(slot, answer.output, accountKeyId);
      },
      via: 'passkey',
      prepare: (entries) async {
        // Old key mails of a group repeat a slot: one salt per credential.
        final salts = <String, Uint8List>{};
        for (final e in entries) {
          for (final slot in e.mail.payload.slots) {
            final info = PasskeySlotInfo.tryParse(slot);
            if (info == null || info.rpId != passkeyRpId) continue;
            salts.putIfAbsent(info.credentialIdB64, () => info.prfSalt);
          }
        }
        if (salts.isEmpty) {
          _unlockFailed(accountId, UnlockFailure.noPasskeySlot, via: 'passkey');
        }
        try {
          answer = await prf.evaluate(
            rpId: passkeyRpId,
            challenge: secureRandomBytes(passkeyChallengeLength),
            evalByCredential: salts,
          );
        } on PrfCancelled {
          _unlockFailed(
            accountId,
            UnlockFailure.passkeyCancelled,
            via: 'passkey',
          );
        } on PrfUnsupported {
          _unlockFailed(
            accountId,
            UnlockFailure.passkeyUnsupported,
            via: 'passkey',
          );
        } on PrfNoCredential {
          _unlockFailed(accountId, UnlockFailure.noSlotOpens, via: 'passkey');
        }
      },
    );
  }

  /// [prepare] runs on the key mails before the slots are tried; it may
  /// throw [UnlockFailed].
  Future<void> _unlock(
    String accountId,
    String slotType,
    Future<AccountKey> Function(UnlockSlot slot, Uint8List accountKeyId)
        unwrap, {
    required String via,
    Future<void> Function(List<KeyMailEntry> entries)? prepare,
  }) async {
    await _exclusive(accountId, () async {
      try {
        await _listFolders?.call(accountId);
        await _store.sync(accountId);
      } catch (_) {
        // Offline first: the key mails seen before are enough.
      }
      final entries = await _accountKeyMails(accountId);
      await prepare?.call(entries);
      final accountKey = await _openWith(accountId, entries, slotType, unwrap);
      if (accountKey == null) {
        _unlockFailed(accountId, UnlockFailure.noSlotOpens, via: via);
      }
      await _adopt(accountId, accountKey, via: via);
    });
    _changed(accountId);
  }

  /// Keeps [accountKey] on this device: saves it, fills the ring, loads the
  /// collection keys and opens what they open. Clears a lost race.
  Future<void> _adopt(
    String accountId,
    AccountKey accountKey, {
    required String via,
  }) async {
    await _keys.save(accountId, accountKey);
    _ring.setAccountKey(accountId, accountKey);
    final rows = await _keyRows(accountId);
    await _loadCollectionKeys(accountId, accountKey, rows);
    await _store.reopen(accountId);
    final state = await _loadState(accountId);
    if (state.phase == KeyPhase.lost) await _saveState(accountId, _noState);
    unawaited(
      _appLogger?.info(
        'mos.key_unlocked',
        'Unlocked the encrypted data',
        accountId: accountId,
        data: {'via': via},
      ),
    );
  }

  Future<AccountKey?> _openWith(
    String accountId,
    List<KeyMailEntry> entries,
    String slotType,
    Future<AccountKey> Function(UnlockSlot slot, Uint8List accountKeyId) unwrap,
  ) async {
    for (final e in entries) {
      final payload = e.mail.payload;
      for (final slot in payload.slots) {
        if (slot.type != slotType) continue;
        final AccountKey key;
        try {
          key = await unwrap(slot, payload.accountKeyId);
        } on KeyUnwrapException {
          continue;
        } on FormatException catch (err) {
          unawaited(
            _appLogger?.warn(
              'mos.unlock_slot_skipped',
              'Skipped a malformed unlock slot',
              accountId: accountId,
              data: {
                'type': slotType,
                'messageId': e.messageId,
                'error': err.message,
              },
            ),
          );
          continue;
        }
        final group = [
          for (final o in entries)
            if (constantTimeEquals(
              o.mail.payload.accountKeyId,
              payload.accountKeyId,
            ))
              o.mail,
        ];
        if (await selectWinner(group, key) != null) return key;
      }
    }
    return null;
  }

  void _logUnlockFailed(
    String accountId,
    String reason, {
    required String via,
  }) =>
      unawaited(
        _appLogger?.info(
          'mos.key_unlock_failed',
          'The recovery key, passphrase or passkey did not unlock the '
              'encrypted data',
          accountId: accountId,
          data: {'reason': reason, 'via': via},
        ),
      );

  Never _unlockFailed(
    String accountId,
    UnlockFailure reason, {
    required String via,
  }) {
    _logUnlockFailed(accountId, reason.name, via: via);
    throw UnlockFailed(reason);
  }

  // ── Passphrase slot ───────────────────────────────────────────────────────

  /// Adds a passphrase slot, or replaces the one there is: at most one per
  /// account. Needs an unlocked device and the server. Throws
  /// [WeakPassphrase] before anything is derived or written,
  /// [KeySetupException] on a locked device and [KeyMailOfflineException].
  Future<void> addPassphraseSlot(String accountId, String passphrase) async {
    final account = await _findAccount?.call(accountId);
    final weakness = checkPassphraseStrength(
      passphrase,
      context: account == null ? const [] : passphraseContext(account),
    );
    if (weakness != null) throw WeakPassphrase(weakness);
    await _exclusive(accountId, () async {
      final key = await _requireLocalKey(accountId);
      final slot = await wrapPassphraseSlot(
        key,
        passphrase,
        deriver: _deriver,
      );
      await _rewriteKeyMail(
        accountId,
        key,
        (slots) => [
          for (final s in slots)
            if (s.type != UnlockSlotType.passphrase) s,
          slot,
        ],
      );
      unawaited(
        _appLogger?.info(
          'mos.passphrase_slot_added',
          'Added a passphrase to unlock the encrypted data',
          accountId: accountId,
        ),
      );
    });
    _changed(accountId);
  }

  /// Removes the passphrase slot; the recovery slot always stays. Removing
  /// is not revocation (4.2). Throws like [addPassphraseSlot].
  Future<void> removePassphraseSlot(String accountId) async {
    await _exclusive(accountId, () async {
      final key = await _requireLocalKey(accountId);
      await _rewriteKeyMail(
        accountId,
        key,
        (slots) => [
          for (final s in slots)
            if (s.type != UnlockSlotType.passphrase) s,
        ],
      );
      unawaited(
        _appLogger?.info(
          'mos.passphrase_slot_removed',
          'Removed the passphrase of the encrypted data',
          accountId: accountId,
        ),
      );
    });
    _changed(accountId);
  }

  /// Whether the account has a passphrase slot: in the current key mail of
  /// this device's key, or — while locked — in any key mail (slot types
  /// are plaintext).
  Future<bool> hasPassphraseSlot(String accountId) async =>
      (await _currentSlots(accountId))
          .any((s) => s.type == UnlockSlotType.passphrase);

  /// The slots of the current key mail of this device's key; while locked
  /// those of every key mail, once per `slotId`.
  Future<List<UnlockSlot>> _currentSlots(String accountId) async {
    final entries = await _accountKeyMails(accountId);
    final key = await _localKey(accountId);
    if (key == null) {
      final seen = <String>{};
      return [
        for (final e in entries)
          for (final s in e.mail.payload.slots)
            if (seen.add(s.slotIdB64)) s,
      ];
    }
    final current = await selectWinner(
      [
        for (final e in entries)
          if (constantTimeEquals(
            e.mail.payload.accountKeyId,
            key.accountKeyId,
          ))
            e.mail,
      ],
      key,
    );
    return current?.payload.slots ?? const [];
  }

  Future<AccountKey> _requireLocalKey(String accountId) async =>
      await _localKey(accountId) ??
      (throw const KeySetupException('this device is locked'));

  // ── Passkey slots ─────────────────────────────────────────────────────────

  /// Whether this device can add and use passkey slots (Android).
  bool get passkeysAvailable => _prf != null;

  /// Adds a `passkey-prf` slot for a new passkey; every call adds one more.
  /// Creates the passkey, evaluates its PRF right away and checks that the
  /// new slot opens before it is written. Needs an unlocked device and the
  /// server. Throws [PrfUnsupported] for a password manager without PRF and
  /// [PrfCancelled] — nothing is written then, but a created passkey stays
  /// in the password manager — [KeySetupException] on a locked device and
  /// [KeyMailOfflineException].
  Future<PasskeySlotInfo> addPasskeySlot(
    String accountId, {
    String label = '',
  }) async {
    final prf = _requirePrf();
    final info = await _exclusive(accountId, () async {
      final key = await _requireLocalKey(accountId);
      // Before the passkey is created: offline, no orphan passkey.
      try {
        await _listFolders?.call(accountId);
        await _store.sync(accountId);
      } catch (e) {
        throw KeyMailOfflineException(e);
      }
      final account = await _findAccount?.call(accountId);
      final registration = await prf.register(
        rpId: passkeyRpId,
        userId: secureRandomBytes(passkeyUserIdLength),
        userName: account?.email ?? accountId,
        challenge: secureRandomBytes(passkeyChallengeLength),
      );
      final credentialId = registration.credentialId;
      final salt = secureRandomBytes(prfSaltLength);
      final answer = await prf.evaluate(
        rpId: passkeyRpId,
        challenge: secureRandomBytes(passkeyChallengeLength),
        evalByCredential: {b64url(credentialId): salt},
      );
      if (!constantTimeEquals(answer.credentialId, credentialId) ||
          answer.output.length != prfOutputLength) {
        throw const PrfUnsupported('the new passkey gave no PRF output');
      }
      final slot = await wrapPasskeySlot(
        key,
        answer.output,
        credentialId: credentialId,
        salt: salt,
        label: label.trim(),
      );
      final back = await unwrapPasskeySlot(
        slot,
        answer.output,
        key.accountKeyId,
      );
      if (!constantTimeEquals(back.key.bytes, key.key.bytes)) {
        throw StateError('the new passkey slot does not open');
      }
      await _rewriteKeyMail(accountId, key, (slots) => [...slots, slot]);
      unawaited(
        _appLogger?.info(
          'mos.passkey_slot_added',
          'Added a passkey to unlock the encrypted data',
          accountId: accountId,
        ),
      );
      return PasskeySlotInfo.parse(slot);
    });
    _changed(accountId);
    return info;
  }

  /// Removes the passkey slot [slotId] (base64url); the other slots stay.
  /// Throws [ArgumentError] — before anything is written — for a slot that
  /// is not a passkey slot of the current key mail, so the recovery slot
  /// always stays; otherwise like [addPasskeySlot]. Removing is not
  /// revocation (4.2).
  Future<void> removePasskeySlot(String accountId, String slotId) async {
    await _exclusive(accountId, () async {
      final key = await _requireLocalKey(accountId);
      await _rewriteKeyMail(accountId, key, (slots) {
        final found = slots.any(
          (s) => s.slotIdB64 == slotId && s.type == UnlockSlotType.passkeyPrf,
        );
        if (!found) {
          throw ArgumentError.value(slotId, 'slotId', 'no passkey slot');
        }
        return [
          for (final s in slots)
            if (s.slotIdB64 != slotId) s,
        ];
      });
      unawaited(
        _appLogger?.info(
          'mos.passkey_slot_removed',
          'Removed a passkey of the encrypted data',
          accountId: accountId,
        ),
      );
    });
    _changed(accountId);
  }

  /// The passkey slots, like [hasPassphraseSlot] sees them; malformed ones
  /// are left out.
  Future<List<PasskeySlotInfo>> passkeySlots(String accountId) async => [
        for (final s in await _currentSlots(accountId))
          if (PasskeySlotInfo.tryParse(s) case final info?) info,
      ];

  PrfProvider _requirePrf() =>
      _prf ?? (throw StateError('passkeys are not available here'));

  // ── Pairing ───────────────────────────────────────────────────────────────

  /// Pairing mails this run already rejected: not opened and logged again.
  final _rejectedPairings = <String>{};

  /// New device: a fresh key pair, stored for [ShareKeyMaterial.lifetime],
  /// and the request to show as QR code and text (4.2).
  Future<PairingStart> startPairing(String accountId) async {
    final id = await _identity(accountId);
    final pair = await _requireShareKeys().createKeyPair();
    return (
      request: encodePairingRequest(
        PairingRequest(
          keyId: pair.keyId,
          publicKey: pair.publicKeyBytes,
          server: id.server,
          username: id.username,
        ),
      ),
      expiresAt:
          pair.expiresAt ?? _now().toUtc().add(ShareKeyMaterial.lifetime),
    );
  }

  /// Unlocked device: encrypts the account key to [requestText] and stores
  /// it as a pairing mail, uploaded like every keys-folder mail (offline
  /// first). Returns the paste code of the same payload. Throws
  /// [PairingRejected] for a bad request or one of another account — before
  /// anything is encrypted — and [StateError] without a local key.
  Future<String> sendPairing(String accountId, String requestText) async {
    final request = parsePairingRequest(requestText);
    if (request == null) {
      _logPairingRejected(accountId, PairingRejection.badFormat);
      throw const PairingRejected(PairingRejection.badFormat);
    }
    return _exclusive(accountId, () async {
      final key = await _localKey(accountId);
      if (key == null) throw StateError('this device has no key to send');
      final id = await _identity(accountId);
      if (request.server != id.server || request.username != id.username) {
        _logPairingRejected(accountId, PairingRejection.wrongAccount);
        throw const PairingRejected(PairingRejection.wrongAccount);
      }
      final ecies = await sealPairing(
        request: request,
        accountKey: key,
        issuedAt: _now(),
      );
      final messageId = newMessageId();
      await _store.appendRaw(
        accountId,
        buildPairingMail(messageId: messageId, ecies: ecies, date: _now()),
      );
      unawaited(
        _appLogger?.info(
          'mos.pairing_sent',
          'Sent the encrypted-data key to a new device',
          accountId: accountId,
          data: {'messageId': messageId},
        ),
      );
      return encodePairingCode(ecies);
    });
  }

  /// New device: pulls the keys folder and opens a pairing mail sent to it.
  /// The pairing view calls it while it waits. Offline: a no-op.
  Future<void> checkPairing(String accountId) async {
    try {
      await _store.sync(accountId);
    } catch (_) {
      // Offline: the next call tries again.
      return;
    }
    await afterSync(accountId, foreground: true);
  }

  /// New device: unlocks with a pasted pairing code. Throws
  /// [PairingRejected].
  Future<void> acceptPairingCode(String accountId, String text) async {
    final Uint8List ecies;
    try {
      ecies = parsePairingCode(text);
    } on PairingRejected catch (e) {
      _logPairingRejected(accountId, e.reason);
      rethrow;
    }
    await _exclusive(accountId, () async {
      try {
        await _store.sync(accountId);
      } catch (_) {
        // Offline first: the key mails seen before are enough.
      }
      final key = await _openPairing(accountId, ecies);
      await _adopt(accountId, key, via: 'pairing');
      _logPairingAccepted(accountId, null);
    });
    _changed(accountId);
  }

  /// Opens the pairing mails addressed to a key pair of this device: the
  /// first that verifies unlocks it and is deleted. Mails of other devices
  /// stay until they expire.
  Future<void> _acceptPairingMails(
    String accountId,
    List<MailObject> rows,
  ) async {
    final shareKeys = _shareKeys;
    if (shareKeys == null || _findAccount == null) return;
    for (final (row, mail) in _pairingMails(rows)) {
      if (_rejectedPairings.contains(row.messageId)) continue;
      if (mail.ecies.length < idLength) continue;
      final keyId = mail.ecies.sublist(0, idLength);
      if (await shareKeys.findByKeyId(keyId) == null) continue;
      final AccountKey key;
      try {
        key = await _openPairing(accountId, mail.ecies);
      } on PairingRejected {
        _rejectedPairings.add(row.messageId);
        continue;
      }
      await _adopt(accountId, key, via: 'pairing');
      await _store.deleteRaw(accountId, row.messageId);
      _logPairingAccepted(accountId, row.messageId);
      try {
        await _store.sync(accountId);
      } catch (_) {
        // Offline: the next foreground sync deletes it.
      }
      return;
    }
  }

  /// [openPairing], then the key must be the one of the winning key-mail
  /// group (4.3) and verify its slot-list MAC. Throws [PairingRejected].
  Future<AccountKey> _openPairing(String accountId, Uint8List ecies) async {
    try {
      final id = await _identity(accountId);
      final key = await openPairing(
        ecies: ecies,
        keys: _requireShareKeys(),
        server: id.server,
        username: id.username,
        now: _now(),
      );
      final entries = await _accountKeyMails(accountId);
      final groupId = b64url(key.accountKeyId);
      final group = [
        for (final e in entries)
          if (b64url(e.mail.payload.accountKeyId) == groupId) e.mail,
      ];
      if (keyRaceWinner(entries) != groupId ||
          await selectWinner(group, key) == null) {
        throw const PairingRejected(PairingRejection.keyMismatch);
      }
      return key;
    } on PairingRejected catch (e) {
      _logPairingRejected(accountId, e.reason);
      rethrow;
    }
  }

  /// Deletes the pairing mails older than [ShareKeyMaterial.lifetime] plus
  /// [pairingClockSkew] (foreground only).
  Future<void> _deleteExpiredPairings(
    String accountId,
    List<MailObject> rows,
  ) async {
    final cutoff =
        _now().subtract(ShareKeyMaterial.lifetime + pairingClockSkew);
    var count = 0;
    for (final (row, mail) in _pairingMails(rows)) {
      final date = mail.date;
      if (date == null || !date.isBefore(cutoff)) continue;
      await _store.deleteRaw(accountId, row.messageId);
      count++;
    }
    if (count == 0) return;
    unawaited(
      _appLogger?.info(
        'mos.pairing_expired_deleted',
        'Deleted expired pairing mails',
        accountId: accountId,
        data: {'count': count},
      ),
    );
  }

  static Iterable<(MailObject, PairingMail)> _pairingMails(
    List<MailObject> rows,
  ) sync* {
    for (final row in rows) {
      final payload = row.payload;
      if (payload == null) continue;
      final PairingMail mail;
      try {
        mail = parsePairingMail(payload);
      } on FormatException {
        continue;
      }
      yield (row, mail);
    }
  }

  /// The server and username pairing matches this account by.
  Future<({String server, String username})> _identity(
    String accountId,
  ) async {
    final account = await _findAccount?.call(accountId);
    if (account == null) throw StateError('unknown account $accountId');
    return (server: account.pairingServer, username: account.pairingUsername);
  }

  ShareKeyRepository _requireShareKeys() =>
      _shareKeys ?? (throw StateError('pairing is not available here'));

  void _logPairingAccepted(String accountId, String? messageId) => unawaited(
        _appLogger?.info(
          'mos.pairing_accepted',
          'Unlocked the encrypted data with a key from another device',
          accountId: accountId,
          data: {'messageId': messageId},
        ),
      );

  void _logPairingRejected(String accountId, PairingRejection reason) =>
      unawaited(
        _appLogger?.info(
          'mos.pairing_rejected',
          'A pairing code or mail was not accepted',
          accountId: accountId,
          data: {'reason': reason.name},
        ),
      );

  // ── Keys ──────────────────────────────────────────────────────────────────

  /// The account key of this device, loaded into the ring once.
  Future<AccountKey?> _localKey(String accountId) async {
    final cached = _ring.accountKey(accountId);
    if (cached != null) return cached;
    final AccountKey? stored;
    try {
      stored = await _keys.load(accountId);
    } on FormatException {
      // Corrupt: never wiped (4.3); the user can unlock again.
      return null;
    }
    if (stored == null) return null;
    _ring.setAccountKey(accountId, stored);
    return stored;
  }

  /// Unwraps the collection-key mails of [accountKey] into the ring; the
  /// write key of a collection is the one with the lowest UID. Returns
  /// whether a new key was added.
  Future<bool> _loadCollectionKeys(
    String accountId,
    AccountKey accountKey,
    List<MailObject> rows,
  ) async {
    var added = false;
    final best = <String, (int, String, CollectionKey)>{};
    for (final row in rows) {
      final parsed = _parse(row);
      if (parsed is! CollectionKeyMailMsg) continue;
      final mail = parsed.mail;
      if (!constantTimeEquals(mail.accountKeyId, accountKey.accountKeyId)) {
        continue;
      }
      final CollectionKey key;
      try {
        key = await mail.unwrapWith(accountKey);
      } on KeyUnwrapException {
        continue;
      }
      if (_ring.addCollectionKey(accountId, key)) added = true;
      final rank = int.tryParse(row.serverId ?? '') ?? 1 << 62;
      final known = best[key.collectionId];
      if (known == null ||
          rank < known.$1 ||
          (rank == known.$1 && row.messageId.compareTo(known.$2) < 0)) {
        best[key.collectionId] = (rank, row.messageId, key);
      }
    }
    for (final b in best.values) {
      _ring.setWriteKey(accountId, b.$3);
    }
    return added;
  }

  Future<List<MailObject>> _keyRows(String accountId) =>
      _store.observe(accountId, MailObjectFolder.keys).first;

  Future<List<KeyMailEntry>> _accountKeyMails(String accountId) async =>
      _parseAccountKeyMails(await _keyRows(accountId));

  static List<KeyMailEntry> _parseAccountKeyMails(List<MailObject> rows) => [
        for (final row in rows)
          if (_parse(row) case final AccountKeyMailMsg m)
            (
              messageId: row.messageId,
              mail: m.mail,
              uid: int.tryParse(row.serverId ?? ''),
            ),
      ];

  static ParsedKeyMail? _parse(MailObject row) {
    final payload = row.payload;
    if (payload == null) return null;
    try {
      return parseKeyMailMessage(payload);
    } on FormatException {
      return null;
    }
  }

  static int _foreignCount(List<KeyMailEntry> mails, AccountKey key) => mails
      .where(
        (m) =>
            !constantTimeEquals(m.mail.payload.accountKeyId, key.accountKeyId),
      )
      .length;

  // ── State row ─────────────────────────────────────────────────────────────

  Future<_KeyState> _loadState(String accountId) async {
    final row = await (_db.select(_db.syncStates)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.resourceType.equals(keyStateResourceType),
          ))
        .getSingleOrNull();
    if (row == null) return _noState;
    try {
      final json = jsonDecode(row.state) as Map<String, dynamic>;
      return (
        phase: KeyPhase.values.byName(json['phase'] as String),
        ownMessageId: json['ownMessageId'] as String?,
        committed: json['committed'] as bool? ?? false,
      );
    } catch (_) {
      return _noState;
    }
  }

  Future<void> _saveState(String accountId, _KeyState state) =>
      _db.into(_db.syncStates).insertOnConflictUpdate(
            SyncStatesCompanion.insert(
              accountId: accountId,
              resourceType: keyStateResourceType,
              state: jsonEncode({
                'phase': state.phase.name,
                'ownMessageId': state.ownMessageId,
                'committed': state.committed,
              }),
              syncedAt: _now(),
            ),
          );

  /// The first write with the key: this device never yields it (4.3).
  Future<void> _markCommitted(String accountId) async {
    final state = await _loadState(accountId);
    if (state.committed) return;
    await _saveState(
      accountId,
      (
        phase: state.phase,
        ownMessageId: state.ownMessageId,
        committed: true,
      ),
    );
  }

  /// Whether this device has written objects with its key.
  Future<bool> isCommitted(String accountId) async =>
      (await _loadState(accountId)).committed;

  // ── Serialization ─────────────────────────────────────────────────────────

  final Map<String, Future<void>> _locks = {};

  /// Runs [body] after every earlier call for [accountId] has finished.
  Future<T> _exclusive<T>(String accountId, Future<T> Function() body) async {
    var busy = _locks[accountId];
    while (busy != null) {
      await busy;
      busy = _locks[accountId];
    }
    final done = Completer<void>();
    _locks[accountId] = done.future;
    try {
      return await body();
    } finally {
      _locks.remove(accountId)?.ignore();
      done.complete();
    }
  }

  void _changed(String accountId) {
    if (!_changes.isClosed) _changes.add(accountId);
  }

  void dispose() => unawaited(_changes.close());
}
