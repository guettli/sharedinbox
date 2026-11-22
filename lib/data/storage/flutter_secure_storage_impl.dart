import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:sharedinbox/core/storage/secure_storage.dart';

class FlutterSecureStorageImpl implements SecureStorage {
  const FlutterSecureStorageImpl();

  static const _impl = FlutterSecureStorage();

  static const _iosFirstUnlock = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  );
  static const _macFirstUnlock = MacOsOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  );

  // null keeps the package default.
  static IOSOptions? _iOptions(SecureStorageAccess access) =>
      access == SecureStorageAccess.afterFirstUnlockThisDevice
          ? _iosFirstUnlock
          : null;

  static MacOsOptions? _mOptions(SecureStorageAccess access) =>
      access == SecureStorageAccess.afterFirstUnlockThisDevice
          ? _macFirstUnlock
          : null;

  @override
  Future<void> write({
    required String key,
    required String? value,
    SecureStorageAccess access = SecureStorageAccess.defaultAccess,
  }) =>
      _impl.write(
        key: key,
        value: value,
        iOptions: _iOptions(access),
        mOptions: _mOptions(access),
      );

  @override
  Future<String?> read({
    required String key,
    SecureStorageAccess access = SecureStorageAccess.defaultAccess,
  }) =>
      _impl.read(
        key: key,
        iOptions: _iOptions(access),
        mOptions: _mOptions(access),
      );

  @override
  Future<void> delete({
    required String key,
    SecureStorageAccess access = SecureStorageAccess.defaultAccess,
  }) =>
      _impl.delete(
        key: key,
        iOptions: _iOptions(access),
        mOptions: _mOptions(access),
      );
}
