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

  Future<void> save(String accountId, AccountKey accountKey) => _storage.write(
        key: storageKey(accountId),
        value: jsonEncode({
          'accountKeyId': b64url(accountKey.accountKeyId),
          'key': b64url(accountKey.key.bytes),
        }),
        access: _access,
      );

  /// The stored key, or null if this device has none.
  ///
  /// Throws [FormatException] if the stored value is corrupt.
  Future<AccountKey?> load(String accountId) async {
    final raw =
        await _storage.read(key: storageKey(accountId), access: _access);
    if (raw == null) return null;
    final json = decodeJsonObject(utf8.encode(raw));
    return AccountKey(
      readBytesField(json, 'accountKeyId', idLength),
      readBytesField(json, 'key', keyLength),
    );
  }

  Future<void> delete(String accountId) =>
      _storage.delete(key: storageKey(accountId), access: _access);
}
