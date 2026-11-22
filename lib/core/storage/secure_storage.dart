/// When a stored item may be read.
enum SecureStorageAccess {
  /// The platform default (iOS/macOS: only while the device is unlocked).
  defaultAccess,

  /// iOS/macOS: readable after the first unlock since boot, also from a
  /// background task; never migrated to another device or backup. Other
  /// platforms use their default.
  afterFirstUnlockThisDevice,
}

/// Minimal interface over platform secure credential storage.
///
/// Pass the same [SecureStorageAccess] to [read] and [delete] that was used
/// for [write]: the iOS keychain matches on it.
abstract class SecureStorage {
  Future<void> write({
    required String key,
    required String? value,
    SecureStorageAccess access = SecureStorageAccess.defaultAccess,
  });
  Future<String?> read({
    required String key,
    SecureStorageAccess access = SecureStorageAccess.defaultAccess,
  });
  Future<void> delete({
    required String key,
    SecureStorageAccess access = SecureStorageAccess.defaultAccess,
  });
}
