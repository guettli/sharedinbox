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

/// File-name suffix that records the message of a failed encryption migration
/// so the Preferences screen can tell the user their data is still unencrypted
/// (the migration runs in [initDatabasePath], where there is no UI to show it).
const String encryptionErrorSuffix = '.encryption_error';

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
String _encryptionErrorPath(String dbPath) => '$dbPath$encryptionErrorSuffix';

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

/// Records that the last encryption migration for [dbPath] failed, with a
/// human-readable [message]. Read by the Preferences screen and cleared on the
/// next successful migration.
void writeEncryptionError(String dbPath, String message) {
  File(_encryptionErrorPath(dbPath)).writeAsStringSync(message);
}

/// The message of the last failed encryption migration, or null if the last
/// migration succeeded (or none has run).
String? readEncryptionError(String dbPath) {
  final f = File(_encryptionErrorPath(dbPath));
  return f.existsSync() ? f.readAsStringSync() : null;
}

void clearEncryptionError(String dbPath) {
  final f = File(_encryptionErrorPath(dbPath));
  if (f.existsSync()) f.deleteSync();
}

/// Deletes the local mail-cache database at [dbPath] and every sidecar file
/// (WAL/SHM, the encrypted/pending/error markers) plus the SQLCipher key, so
/// the next app start rebuilds a fresh empty DB.
///
/// Account credentials live under different secure-storage keys and are left
/// untouched, so the user does not have to re-enter passwords.
Future<void> deleteLocalDatabaseCache(
  String dbPath,
  SecureStorage storage,
) async {
  for (final path in [
    dbPath,
    '$dbPath-wal',
    '$dbPath-shm',
    _encryptedMarkerPath(dbPath),
    _pendingMarkerPath(dbPath),
    _encryptionErrorPath(dbPath),
  ]) {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  }
  await deleteDbCipherKey(storage);
}
