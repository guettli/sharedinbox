import 'dart:typed_data';

import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:sharedinbox/core/models/mail_object.dart';

/// The unlocked keys of this device, in memory (`ENCRYPTED-OBJECTS.md` 4.1).
///
/// One instance is shared by the key service, which fills it, and the
/// object store, which reads it synchronously through [lookup] and
/// [writeKey]. Never logged.
class KeyRing {
  KeyRing({this.onWriteKeyUsed});

  /// Called on the first [writeKey] hit per account: this device is about
  /// to write objects with its key and must never yield it (4.3).
  void Function(String accountId)? onWriteKeyUsed;

  /// Set by the key lifecycle; decides [keepVanishedKeyMail].
  Future<bool> Function(String accountId, MailObject row)? keepVanished;

  final Map<String, AccountKey> _accountKeys = {};
  final Map<String, Map<String, CollectionKey>> _byKeyId = {};
  final Map<String, Map<String, CollectionKey>> _writeKeys = {};
  final Set<String> _used = {};

  AccountKey? accountKey(String accountId) => _accountKeys[accountId];

  /// Sets the account key of [accountId]. Collection keys of another
  /// account key are dropped.
  void setAccountKey(String accountId, AccountKey key) {
    final known = _accountKeys[accountId];
    if (known != null &&
        !constantTimeEquals(known.accountKeyId, key.accountKeyId)) {
      _byKeyId.remove(accountId);
      _writeKeys.remove(accountId);
    }
    _accountKeys[accountId] = key;
  }

  /// Adds a collection key for reading; returns false if it was known.
  bool addCollectionKey(String accountId, CollectionKey key) {
    final keys = _byKeyId.putIfAbsent(accountId, () => {});
    final id = b64url(key.keyId);
    if (keys.containsKey(id)) return false;
    keys[id] = key;
    return true;
  }

  /// The key new versions of [key]'s collection are written with.
  void setWriteKey(String accountId, CollectionKey key) {
    addCollectionKey(accountId, key);
    _writeKeys.putIfAbsent(accountId, () => {})[key.collectionId] = key;
  }

  /// Every collection key of [accountId] by `keyId` (base64url).
  Map<String, CollectionKey> collectionKeys(String accountId) =>
      Map.unmodifiable(_byKeyId[accountId] ?? const {});

  /// Whether [collectionId] has a write key, without counting as a use.
  bool hasWriteKey(String accountId, String collectionId) =>
      _writeKeys[accountId]?.containsKey(collectionId) ?? false;

  /// [CollectionKeyLookup] of the object store.
  CollectionKey? lookup(String accountId, Uint8List keyId) =>
      _byKeyId[accountId]?[b64url(keyId)];

  /// [WriteKeyLookup] of the object store.
  CollectionKey? writeKey(String accountId, String collectionId) {
    final key = _writeKeys[accountId]?[collectionId];
    if (key != null && _used.add(accountId)) onWriteKeyUsed?.call(accountId);
    return key;
  }

  /// `KeepVanishedKeyMail` of the object store: without a key lifecycle,
  /// every vanished key mail is uploaded again.
  Future<bool> keepVanishedKeyMail(String accountId, MailObject row) =>
      keepVanished?.call(accountId, row) ?? Future.value(true);

  void clear(String accountId) {
    _accountKeys.remove(accountId);
    _byKeyId.remove(accountId);
    _writeKeys.remove(accountId);
    _used.remove(accountId);
  }
}
