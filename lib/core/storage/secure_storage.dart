/// Minimal interface over platform secure credential storage.
abstract class SecureStorage {
  Future<void> write({required String key, required String? value});
  Future<String?> read({required String key});
  Future<void> delete({required String key});
}
