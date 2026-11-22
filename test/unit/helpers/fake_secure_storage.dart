import 'package:sharedinbox/core/storage/secure_storage.dart';

/// In-memory [SecureStorage] stand-in — shared across db_encryption_test.dart
/// and db_encryption_migration_test.dart so both suites use the same fake
/// without tripping the jscpd duplication gate.
class FakeSecureStorage implements SecureStorage {
  final Map<String, String> _data = {};

  /// The [SecureStorageAccess] of every call, per key, in call order.
  final Map<String, List<SecureStorageAccess>> accessLog = {};

  void _log(String key, SecureStorageAccess access) =>
      accessLog.putIfAbsent(key, () => []).add(access);

  @override
  Future<String?> read({
    required String key,
    SecureStorageAccess access = SecureStorageAccess.defaultAccess,
  }) async {
    _log(key, access);
    return _data[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    SecureStorageAccess access = SecureStorageAccess.defaultAccess,
  }) async {
    _log(key, access);
    if (value == null) {
      _data.remove(key);
      return;
    }
    _data[key] = value;
  }

  @override
  Future<void> delete({
    required String key,
    SecureStorageAccess access = SecureStorageAccess.defaultAccess,
  }) async {
    _log(key, access);
    _data.remove(key);
  }
}
