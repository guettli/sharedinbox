import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  group('Migration', () {
    test('upgrade from v1 to latest', () async {
      // 1. Create a V1 database using raw sqlite3.
      final dbFile = File('test_migration.db');
      if (dbFile.existsSync()) dbFile.deleteSync();

      final rawDb = sqlite.sqlite3.open(dbFile.path);
      rawDb.execute('''
        CREATE TABLE accounts (
          id TEXT NOT NULL PRIMARY KEY,
          display_name TEXT NOT NULL,
          email TEXT NOT NULL,
          imap_host TEXT NOT NULL,
          imap_port INTEGER NOT NULL,
          imap_ssl INTEGER NOT NULL CHECK ("imap_ssl" IN (0, 1)),
          smtp_host TEXT NOT NULL,
          smtp_port INTEGER NOT NULL,
          smtp_ssl INTEGER NOT NULL CHECK ("smtp_ssl" IN (0, 1))
        );
      ''');
      rawDb.execute('''
        CREATE TABLE mailboxes (
          id TEXT NOT NULL PRIMARY KEY,
          account_id TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
          path TEXT NOT NULL,
          name TEXT NOT NULL,
          unread_count INTEGER NOT NULL DEFAULT 0,
          total_count INTEGER NOT NULL DEFAULT 0
        );
      ''');
      rawDb.execute('''
        CREATE TABLE emails (
          id TEXT NOT NULL PRIMARY KEY,
          account_id TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
          mailbox_path TEXT NOT NULL,
          uid INTEGER NOT NULL,
          subject TEXT NULL,
          sent_at INTEGER NULL,
          received_at INTEGER NOT NULL,
          from_json TEXT NOT NULL DEFAULT '[]',
          to_addresses TEXT NOT NULL DEFAULT '[]',
          cc_json TEXT NOT NULL DEFAULT '[]',
          preview TEXT NULL,
          is_seen INTEGER NOT NULL DEFAULT 0 CHECK ("is_seen" IN (0, 1)),
          is_flagged INTEGER NOT NULL DEFAULT 0 CHECK ("is_flagged" IN (0, 1)),
          has_attachment INTEGER NOT NULL DEFAULT 0 CHECK ("has_attachment" IN (0, 1))
        );
      ''');
      rawDb.execute('''
        CREATE TABLE email_bodies (
          email_id TEXT NOT NULL PRIMARY KEY REFERENCES emails (id) ON DELETE CASCADE,
          text_body TEXT NULL,
          html_body TEXT NULL,
          attachments_json TEXT NOT NULL DEFAULT '[]'
        );
      ''');
      rawDb.execute(
        "INSERT INTO accounts (id, display_name, email, imap_host, imap_port, imap_ssl, smtp_host, smtp_port, smtp_ssl) VALUES ('acc-1', 'Alice', 'alice@example.com', 'imap.example.com', 993, 1, 'smtp.example.com', 465, 1);",
      );
      rawDb.execute('PRAGMA user_version = 1;');
      rawDb.close();

      // 2. Open it with AppDatabase (v22).
      final db = AppDatabase(NativeDatabase(dbFile));

      // Trigger migration by performing a simple query.
      final accs = await db.select(db.accounts).get();
      expect(accs, hasLength(1));
      expect(accs.first.displayName, 'Alice');
      expect(accs.first.accountType, 'imap'); // default value

      // 3. Verify that all columns exist.
      // If migration failed, it would have thrown an exception during opening or query.
      final tableInfo =
          await db.customSelect('PRAGMA table_info(emails)').get();
      final columns = tableInfo.map((r) => r.read<String>('name')).toList();

      expect(columns, contains('thread_id'));
      expect(columns, contains('snoozed_until'));
      expect(columns, contains('snoozed_from_mailbox_path'));

      final accountsInfo =
          await db.customSelect('PRAGMA table_info(accounts)').get();
      final accountColumns =
          accountsInfo.map((r) => r.read<String>('name')).toList();
      expect(accountColumns, contains('account_type'));
      expect(accountColumns, contains('username'));
      expect(accountColumns, contains('manage_sieve_host'));

      await db.close();
      if (dbFile.existsSync()) dbFile.deleteSync();
    });

    test('fresh install (v22) works', () async {
      final db = AppDatabase(NativeDatabase.memory());
      // Just ensure we can create everything and query.
      await db.select(db.accounts).get();
      await db.close();
    });
  });
}
