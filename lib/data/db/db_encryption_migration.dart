import 'dart:io';

import 'package:sharedinbox/core/storage/db_encryption.dart';
import 'package:sharedinbox/core/storage/secure_storage.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// Runs any pending encryption state change for the DB at [dbPath].
///
/// Called by [initDatabasePath] before any Drift connection is opened. Idle
/// when no `<dbPath>.encryption_pending` marker exists, which is the common
/// case.
///
/// On success the marker is cleared and the encrypted marker /
/// secure-storage key are updated to match the new state. On failure the
/// original DB file is left untouched and the marker is cleared so the app
/// does not retry on every launch — the user can re-toggle from Preferences.
Future<void> processPendingDbEncryptionChange({
  required String dbPath,
  required SecureStorage storage,
}) async {
  final change = readPendingEncryptionChange(dbPath);
  if (change == null) return;
  try {
    switch (change) {
      case PendingEncryptionChange.enable:
        await _encryptInPlace(dbPath: dbPath, storage: storage);
      case PendingEncryptionChange.disable:
        await _decryptInPlace(dbPath: dbPath, storage: storage);
    }
  } finally {
    clearPendingEncryptionChange(dbPath);
  }
}

/// Encrypts a plaintext DB by cloning every page into a new SQLCipher file
/// via `sqlcipher_export`, then atomically swapping the new file into place.
Future<void> _encryptInPlace({
  required String dbPath,
  required SecureStorage storage,
}) async {
  if (isDbEncrypted(dbPath)) return; // already done
  if (!File(dbPath).existsSync()) {
    // No data yet — just mint a key and write the marker so the next open
    // creates the DB encrypted from scratch.
    final key = generateDbCipherKeyHex();
    await _writeKeyVerified(storage, key);
    markDbEncrypted(dbPath);
    return;
  }

  final keyHex = await readDbCipherKey(storage) ?? generateDbCipherKeyHex();
  await _writeKeyVerified(storage, keyHex);

  final tmpPath = '$dbPath.enc.tmp';
  _deleteIfExists(tmpPath);

  final db = sqlite.sqlite3.open(dbPath);
  try {
    db.execute("ATTACH DATABASE '$tmpPath' AS encrypted KEY \"x'$keyHex'\";");
    db.execute('PRAGMA encrypted.cipher_compatibility = 4;');
    db.execute("SELECT sqlcipher_export('encrypted');");
    db.execute('DETACH DATABASE encrypted;');
  } finally {
    db.close();
  }

  await _atomicReplace(tmpPath, dbPath);
  markDbEncrypted(dbPath);
}

/// Decrypts an encrypted DB into a fresh plaintext file, then atomically
/// swaps the new file into place and deletes the cipher key.
Future<void> _decryptInPlace({
  required String dbPath,
  required SecureStorage storage,
}) async {
  if (!isDbEncrypted(dbPath)) return; // already plaintext
  final keyHex = await readDbCipherKey(storage);
  if (keyHex == null) {
    // No key stored but marker present — can't decrypt. Drop the marker so
    // the next open does not try to apply a non-existent key.
    markDbPlaintext(dbPath);
    return;
  }

  final tmpPath = '$dbPath.plain.tmp';
  _deleteIfExists(tmpPath);

  final db = sqlite.sqlite3.open(dbPath);
  try {
    db.execute("PRAGMA key = \"x'$keyHex'\";");
    db.execute('PRAGMA cipher_compatibility = 4;');
    db.execute("ATTACH DATABASE '$tmpPath' AS plaintext KEY '';");
    db.execute("SELECT sqlcipher_export('plaintext');");
    db.execute('DETACH DATABASE plaintext;');
  } finally {
    db.close();
  }

  await _atomicReplace(tmpPath, dbPath);
  markDbPlaintext(dbPath);
  await deleteDbCipherKey(storage);
}

/// Writes [keyHex] to secure storage and reads it back to confirm the write
/// actually persisted. On some platforms (e.g. libsecret with no running
/// keyring daemon) a write can silently no-op; encrypting the DB with a key
/// that nobody can read back is permanent data loss, so abort loudly instead.
Future<void> _writeKeyVerified(SecureStorage storage, String keyHex) async {
  await writeDbCipherKey(storage, keyHex);
  final readBack = await readDbCipherKey(storage);
  if (readBack != keyHex) {
    throw StateError(
      'SQLCipher key did not persist to secure storage; aborting encryption '
      'to avoid an unrecoverable database.',
    );
  }
}

void _deleteIfExists(String path) {
  final f = File(path);
  if (f.existsSync()) f.deleteSync();
  final walFiles = ['$path-wal', '$path-shm'];
  for (final w in walFiles) {
    final wf = File(w);
    if (wf.existsSync()) wf.deleteSync();
  }
}

/// Replaces [target] with [source]. WAL/SHM sidecar files for the old DB are
/// discarded because they no longer belong to the new file's journal mode.
Future<void> _atomicReplace(String source, String target) async {
  final backup = '$target.bak';
  _deleteIfExists(backup);
  final tFile = File(target);
  if (tFile.existsSync()) await tFile.rename(backup);
  await File(source).rename(target);
  // Tidy up any orphaned WAL/SHM from the previous file.
  for (final w in ['$target-wal', '$target-shm']) {
    final wf = File(w);
    if (wf.existsSync()) wf.deleteSync();
  }
  final bFile = File(backup);
  if (bFile.existsSync()) bFile.deleteSync();
}
