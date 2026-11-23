import 'dart:convert';

import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:sharedinbox/core/storage/secure_storage.dart';

/// Device copy of the unwrapped account key (`ENCRYPTED-OBJECTS.md` 4.2).
///
/// Stored **without a biometric gate** and readable after the first unlock,
/// so the background isolate can decrypt.
///
/// Never wipe the key because `SharedInbox/Keys` is missing — re-upload the
/// key mail from the local copy instead (4.3).
class AccountKeyStore {
  const AccountKeyStore(this._storage);

  final SecureStorage _storage;

  static const _access = SecureStorageAccess.afterFirstUnlockThisDevice;

  static String storageKey(String accountId) => 'enc-account-key/$accountId';

  /// A key created by this device while its key-creation race (4.3) is not
  /// decided yet; moved to [storageKey] on a win, dropped on a loss.
  static String pendingStorageKey(String accountId) =>
      'enc-account-key-pending/$accountId';

  Future<void> save(String accountId, AccountKey accountKey) =>
      _write(storageKey(accountId), accountKey);

  /// The stored key, or null if this device has none.
  ///
  /// Throws [FormatException] if the stored value is corrupt.
  Future<AccountKey?> load(String accountId) => _read(storageKey(accountId));

  Future<void> delete(String accountId) =>
      _storage.delete(key: storageKey(accountId), access: _access);

  Future<void> savePending(String accountId, AccountKey accountKey) =>
      _write(pendingStorageKey(accountId), accountKey);

  Future<AccountKey?> loadPending(String accountId) =>
      _read(pendingStorageKey(accountId));

  Future<void> deletePending(String accountId) =>
      _storage.delete(key: pendingStorageKey(accountId), access: _access);

  Future<void> _write(String key, AccountKey accountKey) => _storage.write(
        key: key,
        value: jsonEncode({
          'accountKeyId': b64url(accountKey.accountKeyId),
          'key': b64url(accountKey.key.bytes),
        }),
        access: _access,
      );

  Future<AccountKey?> _read(String key) async {
    final raw = await _storage.read(key: key, access: _access);
    if (raw == null) return null;
    final json = decodeJsonObject(utf8.encode(raw));
    return AccountKey(
      readBytesField(json, 'accountKeyId', idLength),
      readBytesField(json, 'key', keyLength),
    );
  }
}
