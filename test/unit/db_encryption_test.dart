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
}
