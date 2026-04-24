import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:sharedinbox/core/storage/secure_storage.dart';

class FlutterSecureStorageImpl implements SecureStorage {
  const FlutterSecureStorageImpl();

  static const _impl = FlutterSecureStorage();

  @override
  Future<void> write({required String key, required String? value}) =>
      _impl.write(key: key, value: value);

  @override
  Future<String?> read({required String key}) => _impl.read(key: key);

  @override
  Future<void> delete({required String key}) => _impl.delete(key: key);
}
