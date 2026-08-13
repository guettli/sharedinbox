import 'dart:io';

import 'package:sharedinbox/core/storage/db_encryption.dart';
import 'package:test/test.dart';

import 'helpers/fake_secure_storage.dart';

void main() {
  group('generateDbCipherKeyHex', () {
    test('produces 64 hex characters (256 bits)', () {
      final key = generateDbCipherKeyHex();
      expect(key.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(key), isTrue);
    });

    test('returns a fresh value on every call', () {
      final a = generateDbCipherKeyHex();
      final b = generateDbCipherKeyHex();
      expect(a, isNot(b));
    });
  });

  group('cipher key storage', () {
    test('round-trip: write → read → delete', () async {
      final storage = FakeSecureStorage();
      final key = generateDbCipherKeyHex();

      expect(await readDbCipherKey(storage), isNull);
      await writeDbCipherKey(storage, key);
      expect(await readDbCipherKey(storage), key);
      await deleteDbCipherKey(storage);
      expect(await readDbCipherKey(storage), isNull);
    });
  });

  group('encrypted-state marker', () {
    late Directory tmp;
    late String dbPath;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('si_db_enc_');
      dbPath = '${tmp.path}/sharedinbox.db';
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('isDbEncrypted is false by default', () {
      expect(isDbEncrypted(dbPath), isFalse);
    });

    test('markDbEncrypted creates the marker file', () {
      markDbEncrypted(dbPath);
      expect(isDbEncrypted(dbPath), isTrue);
      expect(File('$dbPath$encryptedMarkerSuffix').existsSync(), isTrue);
    });

    test('markDbPlaintext removes the marker file', () {
      markDbEncrypted(dbPath);
      markDbPlaintext(dbPath);
      expect(isDbEncrypted(dbPath), isFalse);
    });

    test('markDbPlaintext is a no-op when marker is absent', () {
      markDbPlaintext(dbPath);
      expect(isDbEncrypted(dbPath), isFalse);
    });
  });

  group('pending-encryption marker', () {
    late Directory tmp;
    late String dbPath;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('si_db_enc_pending_');
      dbPath = '${tmp.path}/sharedinbox.db';
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('readPendingEncryptionChange returns null when no marker', () {
      expect(readPendingEncryptionChange(dbPath), isNull);
    });

    test('write+read enable round-trip', () {
      writePendingEncryptionChange(dbPath, PendingEncryptionChange.enable);
      expect(
        readPendingEncryptionChange(dbPath),
        PendingEncryptionChange.enable,
      );
    });

    test('write+read disable round-trip', () {
      writePendingEncryptionChange(dbPath, PendingEncryptionChange.disable);
      expect(
        readPendingEncryptionChange(dbPath),
        PendingEncryptionChange.disable,
      );
    });

    test('overwrite replaces the previous value', () {
      writePendingEncryptionChange(dbPath, PendingEncryptionChange.enable);
      writePendingEncryptionChange(dbPath, PendingEncryptionChange.disable);
      expect(
        readPendingEncryptionChange(dbPath),
        PendingEncryptionChange.disable,
      );
    });

    test('clearPendingEncryptionChange removes the marker', () {
      writePendingEncryptionChange(dbPath, PendingEncryptionChange.enable);
      clearPendingEncryptionChange(dbPath);
      expect(readPendingEncryptionChange(dbPath), isNull);
    });

    test('garbage marker content returns null rather than throwing', () {
      File('$dbPath$pendingMarkerSuffix').writeAsStringSync('???');
      expect(readPendingEncryptionChange(dbPath), isNull);
    });
  });

  group('encryption-error marker', () {
    late Directory tmp;
    late String dbPath;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('si_db_enc_err_');
      dbPath = '${tmp.path}/sharedinbox.db';
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('read returns null when no error was recorded', () {
      expect(readEncryptionError(dbPath), isNull);
    });

    test('write then read returns the recorded message', () {
      writeEncryptionError(dbPath, 'Encryption could not be enabled: boom');
      expect(
        readEncryptionError(dbPath),
        'Encryption could not be enabled: boom',
      );
    });

    test('clear removes the marker', () {
      writeEncryptionError(dbPath, 'boom');
      clearEncryptionError(dbPath);
      expect(readEncryptionError(dbPath), isNull);
    });
  });

  group('deleteLocalDatabaseCache', () {
    late Directory tmp;
    late String dbPath;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('si_db_del_cache_');
      dbPath = '${tmp.path}/sharedinbox.db';
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('deletes the DB, sidecars and cipher key but keeps credentials',
        () async {
      final storage = FakeSecureStorage();
      // Seed the DB, its WAL/SHM sidecars and every marker.
      File(dbPath).writeAsStringSync('db');
      File('$dbPath-wal').writeAsStringSync('wal');
      File('$dbPath-shm').writeAsStringSync('shm');
      markDbEncrypted(dbPath);
      writePendingEncryptionChange(dbPath, PendingEncryptionChange.enable);
      writeEncryptionError(dbPath, 'boom');
      await writeDbCipherKey(storage, generateDbCipherKeyHex());
      // An unrelated credential entry that must survive the wipe.
      await storage.write(key: 'account_pw_1', value: 'hunter2');

      await deleteLocalDatabaseCache(dbPath, storage);

      expect(File(dbPath).existsSync(), isFalse);
      expect(File('$dbPath-wal').existsSync(), isFalse);
      expect(File('$dbPath-shm').existsSync(), isFalse);
      expect(isDbEncrypted(dbPath), isFalse);
      expect(readPendingEncryptionChange(dbPath), isNull);
      expect(readEncryptionError(dbPath), isNull);
      expect(await readDbCipherKey(storage), isNull);
      // Credentials are untouched — the user keeps their passwords.
      expect(await storage.read(key: 'account_pw_1'), 'hunter2');
    });

    test('is a no-op when nothing exists', () async {
      final storage = FakeSecureStorage();
      await deleteLocalDatabaseCache(dbPath, storage);
      expect(File(dbPath).existsSync(), isFalse);
    });
  });
}
