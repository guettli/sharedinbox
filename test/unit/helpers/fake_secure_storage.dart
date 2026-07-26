import 'package:sharedinbox/core/storage/secure_storage.dart';

/// In-memory [SecureStorage] stand-in — shared across db_encryption_test.dart
/// and db_encryption_migration_test.dart so both suites use the same fake
/// without tripping the jscpd duplication gate.
class FakeSecureStorage implements SecureStorage {
  final Map<String, String> _data = {};

  @override
  Future<String?> read({required String key}) async => _data[key];

  @override
  Future<void> write({required String key, required String? value}) async {
    if (value == null) {
      _data.remove(key);
      return;
    }
    _data[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    _data.remove(key);
  }
}
