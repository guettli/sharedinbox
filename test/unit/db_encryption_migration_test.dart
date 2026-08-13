import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/storage/db_encryption.dart';
import 'package:sharedinbox/core/storage/secure_storage.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/db/db_encryption_migration.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'helpers/fake_secure_storage.dart';

/// SecureStorage that throws on write. Used to exercise the failure branch
/// of [processPendingDbEncryptionChange] without touching sqlite.
class _ThrowingSecureStorage implements SecureStorage {
  @override
  Future<String?> read({required String key}) async => null;

  @override
  Future<void> write({required String key, required String? value}) async {
    throw const FileSystemException('storage write refused');
  }

  @override
  Future<void> delete({required String key}) async {}
}

/// SecureStorage whose write silently no-ops and whose read always returns
/// null — mimicking libsecret with no running keyring daemon. Used to prove
/// the key round-trip check aborts before the DB is rewritten, so we never end
/// up with an encrypted file whose key nobody has.
class _NoOpWriteSecureStorage implements SecureStorage {
  @override
  Future<String?> read({required String key}) async => null;

  @override
  Future<void> write({required String key, required String? value}) async {}

  @override
  Future<void> delete({required String key}) async {}
}

/// The 16-byte plaintext SQLite header — the ASCII string "SQLite format 3"
/// followed by a single NUL byte (see https://sqlite.org/fileformat.html).
/// SQLCipher stores a random 16-byte salt at the same offset, so a header
/// equality check reliably distinguishes the two encodings on disk.
final Uint8List _plaintextMagic = Uint8List.fromList(
  <int>[...'SQLite format 3'.codeUnits, 0],
);

/// The SQLCipher version string reported by the linked sqlite3. Plain sqlite3
/// silently ignores `PRAGMA cipher_version` and returns an empty ResultSet, so
/// an empty value means the `source: sqlcipher` build hook is not in effect —
/// which, since the migration to package:sqlite3's bundled SQLCipher (#436),
/// is a build regression that must fail CI, not a reason to skip.
String _cipherVersion() {
  final db = sqlite.sqlite3.openInMemory();
  try {
    final rows = db.select('PRAGMA cipher_version;');
    if (rows.isEmpty) return '';
    return rows.first.values.first?.toString() ?? '';
  } finally {
    db.close();
  }
}

void main() {
  late Directory tmp;
  late String dbPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('si_db_enc_mig_');
    dbPath = '${tmp.path}/sharedinbox.db';
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  // Loud, single assertion that the bundled SQLCipher hook is actually in
  // effect. If it regresses, every test in this file fails here rather than
  // silently skipping the encryption round-trips (the pre-#436 behaviour).
  setUpAll(() {
    expect(
      _cipherVersion(),
      isNotEmpty,
      reason: 'sqlite3 is not linked against SQLCipher — check the '
          '`hooks: user_defines: sqlite3: source: sqlcipher` block in '
          'pubspec.yaml.',
    );
  });

  group('processPendingDbEncryptionChange — pure Dart branches', () {
    test('no pending change is a no-op', () async {
      final storage = FakeSecureStorage();
      await processPendingDbEncryptionChange(dbPath: dbPath, storage: storage);
      expect(isDbEncrypted(dbPath), isFalse);
      expect(await readDbCipherKey(storage), isNull);
    });

    test(
      'enable with no existing DB file mints a key + marker and skips the '
      'sqlcipher_export path',
      () async {
        final storage = FakeSecureStorage();
        writePendingEncryptionChange(dbPath, PendingEncryptionChange.enable);

        await processPendingDbEncryptionChange(
          dbPath: dbPath,
          storage: storage,
        );

        expect(isDbEncrypted(dbPath), isTrue);
        expect(readPendingEncryptionChange(dbPath), isNull);
        final key = await readDbCipherKey(storage);
        expect(key, isNotNull);
        expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(key!), isTrue);
        // No DB file was created — the next Drift open will make one.
        expect(File(dbPath).existsSync(), isFalse);
      },
    );

    test('enable is a no-op when the DB is already encrypted', () async {
      final storage = FakeSecureStorage();
      final existing = generateDbCipherKeyHex();
      await writeDbCipherKey(storage, existing);
      markDbEncrypted(dbPath);
      writePendingEncryptionChange(dbPath, PendingEncryptionChange.enable);

      await processPendingDbEncryptionChange(
        dbPath: dbPath,
        storage: storage,
      );

      expect(isDbEncrypted(dbPath), isTrue);
      expect(readPendingEncryptionChange(dbPath), isNull);
      // The pre-existing key is not rotated.
      expect(await readDbCipherKey(storage), existing);
    });

    test(
      'disable with marker present but no stored key drops the marker '
      'without touching the file',
      () async {
        final storage = FakeSecureStorage();
        // Simulate an inconsistent state: the encrypted marker file exists
        // but the secure-storage key is gone (e.g. keystore wipe).
        File(dbPath).writeAsBytesSync([1, 2, 3, 4]);
        markDbEncrypted(dbPath);
        writePendingEncryptionChange(dbPath, PendingEncryptionChange.disable);

        await processPendingDbEncryptionChange(
          dbPath: dbPath,
          storage: storage,
        );

        expect(isDbEncrypted(dbPath), isFalse);
        expect(readPendingEncryptionChange(dbPath), isNull);
        // File bytes preserved — we intentionally do not attempt a decrypt
        // when no key is available.
        expect(File(dbPath).readAsBytesSync(), [1, 2, 3, 4]);
      },
    );

    test(
      'pending marker is cleared even when the migration throws — the boot '
      'path must never spin on a poisoned marker',
      () async {
        final storage = _ThrowingSecureStorage();
        writePendingEncryptionChange(dbPath, PendingEncryptionChange.enable);

        await expectLater(
          processPendingDbEncryptionChange(dbPath: dbPath, storage: storage),
          throwsA(isA<FileSystemException>()),
        );

        expect(readPendingEncryptionChange(dbPath), isNull);
        expect(isDbEncrypted(dbPath), isFalse);
      },
    );

    test(
      'enable aborts without rewriting the DB when the key will not persist',
      () async {
        // A silently-failed key write followed by a successful encrypt is
        // permanent data loss (an encrypted file whose key nobody has), so the
        // migration must verify the key round-trips first and abort otherwise.
        final storage = _NoOpWriteSecureStorage();
        File(dbPath).writeAsBytesSync(_plaintextMagic);
        writePendingEncryptionChange(dbPath, PendingEncryptionChange.enable);

        await expectLater(
          processPendingDbEncryptionChange(dbPath: dbPath, storage: storage),
          throwsA(isA<StateError>()),
        );

        // Marker cleared, DB left plaintext and byte-for-byte untouched.
        expect(readPendingEncryptionChange(dbPath), isNull);
        expect(isDbEncrypted(dbPath), isFalse);
        expect(File(dbPath).readAsBytesSync(), _plaintextMagic);
      },
    );
  });

  group('processPendingDbEncryptionChange — SQLCipher round-trip', () {
    test('enable rewrites a plaintext DB into an encrypted one', () async {
      // Seed a plaintext DB with known content.
      final seed = sqlite.sqlite3.open(dbPath);
      seed.execute('CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT);');
      seed.execute("INSERT INTO notes (body) VALUES ('hello'), ('world');");
      seed.close();

      // Sanity: file starts with the plaintext SQLite magic.
      final before = File(dbPath).readAsBytesSync().sublist(0, 16);
      expect(before, _plaintextMagic);

      final storage = FakeSecureStorage();
      writePendingEncryptionChange(dbPath, PendingEncryptionChange.enable);
      await processPendingDbEncryptionChange(
        dbPath: dbPath,
        storage: storage,
      );

      expect(isDbEncrypted(dbPath), isTrue);
      expect(readPendingEncryptionChange(dbPath), isNull);

      // File header no longer matches the plaintext magic (SQLCipher stores
      // a random 16-byte salt at offset 0).
      final after = File(dbPath).readAsBytesSync().sublist(0, 16);
      expect(after, isNot(_plaintextMagic));

      // Opening without the key fails on the first read.
      final noKey = sqlite.sqlite3.open(dbPath);
      try {
        expect(
          () => noKey.select('SELECT body FROM notes ORDER BY id;'),
          throwsA(isA<sqlite.SqliteException>()),
        );
      } finally {
        noKey.close();
      }

      // Opening with the correct key returns the seeded rows unchanged.
      final key = (await readDbCipherKey(storage))!;
      final ok = sqlite.sqlite3.open(dbPath);
      try {
        ok.execute('PRAGMA key = "x\'$key\'";');
        ok.execute('PRAGMA cipher_compatibility = 4;');
        final rows = ok.select('SELECT body FROM notes ORDER BY id;');
        expect(rows.map((r) => r['body']).toList(), ['hello', 'world']);
      } finally {
        ok.close();
      }
    });

    test('disable rewrites an encrypted DB back to plaintext', () async {
      // Seed a plaintext DB, then enable encryption.
      final seed = sqlite.sqlite3.open(dbPath);
      seed.execute('CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT);');
      seed.execute("INSERT INTO kv VALUES ('greeting', 'hi'), ('lang', 'en');");
      seed.close();

      final storage = FakeSecureStorage();
      writePendingEncryptionChange(dbPath, PendingEncryptionChange.enable);
      await processPendingDbEncryptionChange(
        dbPath: dbPath,
        storage: storage,
      );
      expect(isDbEncrypted(dbPath), isTrue);
      expect(await readDbCipherKey(storage), isNotNull);

      // Now flip back to plaintext.
      writePendingEncryptionChange(dbPath, PendingEncryptionChange.disable);
      await processPendingDbEncryptionChange(
        dbPath: dbPath,
        storage: storage,
      );

      expect(isDbEncrypted(dbPath), isFalse);
      expect(readPendingEncryptionChange(dbPath), isNull);
      expect(await readDbCipherKey(storage), isNull);

      // Header is once again the plaintext magic.
      final header = File(dbPath).readAsBytesSync().sublist(0, 16);
      expect(header, _plaintextMagic);

      // Data survives the round-trip.
      final plain = sqlite.sqlite3.open(dbPath);
      try {
        final rows = plain.select('SELECT k, v FROM kv ORDER BY k;');
        expect(
          rows.map((r) => [r['k'], r['v']]).toList(),
          [
            ['greeting', 'hi'],
            ['lang', 'en'],
          ],
        );
      } finally {
        plain.close();
      }
    });
  });

  group('setupPragmasForTesting — cipher key path', () {
    test(
      'a correct key unlocks the DB so subsequent reads succeed',
      () async {
        // Create an encrypted DB via the production migration path so the
        // on-disk format matches what _openConnection expects at runtime.
        final storage = FakeSecureStorage();
        writePendingEncryptionChange(dbPath, PendingEncryptionChange.enable);
        await processPendingDbEncryptionChange(
          dbPath: dbPath,
          storage: storage,
        );
        final key = (await readDbCipherKey(storage))!;

        final db = sqlite.sqlite3.open(dbPath);
        try {
          setupPragmasForTesting(db, cipherKeyHex: key);
          // A round-trip read must succeed under the applied key.
          db.execute('CREATE TABLE t (x INTEGER);');
          db.execute('INSERT INTO t VALUES (42);');
          final rows = db.select('SELECT x FROM t;');
          expect(rows.single['x'], 42);
        } finally {
          db.close();
        }
      },
    );

    test('a wrong key leaves the DB unreadable', () async {
      // Encrypt with one key, then try to open with a fresh one.
      final storage = FakeSecureStorage();
      final seed = sqlite.sqlite3.open(dbPath);
      seed.execute('CREATE TABLE t (x INTEGER);');
      seed.execute('INSERT INTO t VALUES (1);');
      seed.close();
      writePendingEncryptionChange(dbPath, PendingEncryptionChange.enable);
      await processPendingDbEncryptionChange(
        dbPath: dbPath,
        storage: storage,
      );

      final wrong = generateDbCipherKeyHex();
      final db = sqlite.sqlite3.open(dbPath);
      try {
        setupPragmasForTesting(db, cipherKeyHex: wrong);
        expect(
          () => db.select('SELECT x FROM t;'),
          throwsA(isA<sqlite.SqliteException>()),
        );
      } finally {
        db.close();
      }
    });
  });
}
