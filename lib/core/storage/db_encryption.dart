import 'dart:io';
import 'dart:math';

import 'package:sharedinbox/core/storage/secure_storage.dart';

/// Secure-storage key under which the SQLCipher hex key is persisted.
const String dbCipherKeyStorageKey = 'sharedinbox_db_cipher_key';

/// File-name suffix used to mark that the DB at `<dbPath>` is encrypted.
/// The marker file's presence is the source of truth at boot time: the OS
/// keystore call can be slow on cold start, so we use a cheap `stat()` to
/// decide whether to apply `PRAGMA key` before opening Drift.
const String encryptedMarkerSuffix = '.encrypted';

/// File-name suffix for a pending encryption state change, processed at the
/// next app start (before any Drift connection is opened). Its contents are
/// either `enable` or `disable`.
const String pendingMarkerSuffix = '.encryption_pending';

/// 256 bits — the SQLCipher v4 default key size when supplied as a raw key.
const int _keyByteLength = 32;

/// Generates a fresh 256-bit SQLCipher key, hex-encoded.
///
/// Hex encoding lets us pass the key to SQLCipher as `PRAGMA key = "x'…'"`,
/// which skips PBKDF2 derivation — appropriate because the key is already
/// 256 bits of cryptographic entropy and lives in the OS keystore.
String generateDbCipherKeyHex() {
  final rng = Random.secure();
  final buf = StringBuffer();
  for (var i = 0; i < _keyByteLength; i++) {
    final b = rng.nextInt(256);
    if (b < 16) buf.write('0');
    buf.write(b.toRadixString(16));
  }
  return buf.toString();
}

/// Reads the SQLCipher key from secure storage. Returns null when no key
/// has been stored yet (i.e. the user has never enabled encryption).
Future<String?> readDbCipherKey(SecureStorage storage) =>
    storage.read(key: dbCipherKeyStorageKey);

/// Persists [hexKey] to secure storage. Overwrites any existing value.
Future<void> writeDbCipherKey(SecureStorage storage, String hexKey) =>
    storage.write(key: dbCipherKeyStorageKey, value: hexKey);

/// Removes the SQLCipher key from secure storage.
Future<void> deleteDbCipherKey(SecureStorage storage) =>
    storage.delete(key: dbCipherKeyStorageKey);

String _encryptedMarkerPath(String dbPath) => '$dbPath$encryptedMarkerSuffix';
String _pendingMarkerPath(String dbPath) => '$dbPath$pendingMarkerSuffix';

/// Whether the DB at [dbPath] is currently encrypted. Cheap synchronous
/// `stat()` call so the boot path stays fast.
bool isDbEncrypted(String dbPath) =>
    File(_encryptedMarkerPath(dbPath)).existsSync();

void markDbEncrypted(String dbPath) {
  File(_encryptedMarkerPath(dbPath)).writeAsStringSync('');
}

void markDbPlaintext(String dbPath) {
  final f = File(_encryptedMarkerPath(dbPath));
  if (f.existsSync()) f.deleteSync();
}

/// The kind of pending encryption migration to run at next startup.
enum PendingEncryptionChange { enable, disable }

PendingEncryptionChange? readPendingEncryptionChange(String dbPath) {
  final f = File(_pendingMarkerPath(dbPath));
  if (!f.existsSync()) return null;
  switch (f.readAsStringSync().trim()) {
    case 'enable':
      return PendingEncryptionChange.enable;
    case 'disable':
      return PendingEncryptionChange.disable;
  }
  return null;
}

void writePendingEncryptionChange(
  String dbPath,
  PendingEncryptionChange change,
) {
  final name = switch (change) {
    PendingEncryptionChange.enable => 'enable',
    PendingEncryptionChange.disable => 'disable',
  };
  File(_pendingMarkerPath(dbPath)).writeAsStringSync(name);
}

void clearPendingEncryptionChange(String dbPath) {
  final f = File(_pendingMarkerPath(dbPath));
  if (f.existsSync()) f.deleteSync();
}
