import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// Reads all column names for [tableName] from [db].
Future<List<String>> _tableColumns(AppDatabase db, String tableName) async {
  final rows = await db.customSelect('PRAGMA table_info($tableName)').get();
  return rows.map((r) => r.read<String>('name')).toList();
}

void main() {
  group('Migration', () {
    test('schemaVersion matches expected value', () async {
      final db = AppDatabase(NativeDatabase.memory());
      expect(db.schemaVersion, 37);
      await db.close();
    });

    test('upgrade from v1 to latest checks all added columns', () async {
      final dbFile = File('test_migration_v1.db');
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

      final db = AppDatabase(NativeDatabase(dbFile));

      // Trigger migration by performing a query.
      final accs = await db.select(db.accounts).get();
      expect(accs, hasLength(1));
      expect(accs.first.displayName, 'Alice');
      expect(accs.first.accountType, 'imap');

      // v2–v3: accounts columns.
      final accountColumns = await _tableColumns(db, 'accounts');
      expect(
        accountColumns,
        containsAll(['account_type', 'jmap_url', 'username']),
      );
      expect(accountColumns, contains('manage_sieve_host'));

      // v14: threading columns.
      final emailColumns = await _tableColumns(db, 'emails');
      expect(
        emailColumns,
        containsAll(['thread_id', 'message_id', 'in_reply_to', 'references']),
      );

      // v22: snooze columns.
      expect(
        emailColumns,
        containsAll(['snoozed_until', 'snoozed_from_mailbox_path']),
      );

      // v23: list-unsubscribe header column.
      expect(emailColumns, contains('list_unsubscribe_header'));

      // v8: mailboxes role column.
      final mailboxColumns = await _tableColumns(db, 'mailboxes');
      expect(mailboxColumns, contains('role'));

      // v9: email_bodies cached_at column.
      final bodyColumns = await _tableColumns(db, 'email_bodies');
      expect(bodyColumns, contains('cached_at'));
      expect(bodyColumns, contains('headers_json'));

      // v4: drafts table with v24 imap_server_id column.
      final draftColumns = await _tableColumns(db, 'drafts');
      expect(draftColumns, contains('imap_server_id'));

      // v5, v6, v7, v12, v17, v19, v21: new tables.
      final allTables = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
          .get();
      final tableNames = allTables.map((r) => r.read<String>('name')).toList();
      expect(
        tableNames,
        containsAll([
          'sync_states', // v5
          'pending_changes', // v6
          'sync_logs', // v7
          'sync_log_mailboxes', // v12
          'threads', // v17
          'sync_health', // v19
          'undo_actions', // v21
        ]),
      );

      // v18, v22, v25: indexes.
      final allIndexes = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type='index'")
          .get();
      final indexNames = allIndexes.map((r) => r.read<String>('name')).toSet();
      expect(
        indexNames,
        containsAll([
          'emails_received_at', // v18
          'emails_thread_id', // v18
          'pending_changes_account_id', // v18
          'emails_snoozed_until', // v22
          'mailboxes_account_id', // v25
          'threads_latest_date', // v25
        ]),
      );

      // v26: FTS5 virtual table and triggers exist.
      final allTriggers = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type='trigger'")
          .get();
      final triggerNames =
          allTriggers.map((r) => r.read<String>('name')).toSet();
      expect(
        triggerNames,
        containsAll(['email_fts_ai', 'email_fts_au', 'email_fts_ad']),
      );
      // Verify FTS table was created and is queryable.
      await db.customSelect('SELECT count(*) FROM email_fts').get();

      // v27: search_history_entries table.
      await db
          .customSelect('SELECT count(*) FROM search_history_entries')
          .get();

      // v28: mime_tree_json column on email_bodies.
      await db
          .customSelect('SELECT mime_tree_json FROM email_bodies LIMIT 0')
          .get();

      // v29: local_sieve_scripts table.
      await db.customSelect('SELECT count(*) FROM local_sieve_scripts').get();

      // v30: duration_ms column on sync_log_mailboxes.
      final syncLogMailboxColumns = await _tableColumns(
        db,
        'sync_log_mailboxes',
      );
      expect(syncLogMailboxColumns, contains('duration_ms'));

      // v32: local_sieve_applied table.
      await db.customSelect('SELECT count(*) FROM local_sieve_applied').get();

      // v33: error_stack_trace and is_permanent columns on sync_logs.
      final syncLogColumns = await _tableColumns(db, 'sync_logs');
      expect(syncLogColumns, contains('error_stack_trace'));
      expect(syncLogColumns, contains('is_permanent'));

      // v34: user_preferences table.
      await db.customSelect('SELECT count(*) FROM user_preferences').get();

      // v35: mail_view_button_position column on user_preferences.
      final userPrefsColumns = await _tableColumns(db, 'user_preferences');
      expect(userPrefsColumns, contains('mail_view_button_position'));

      // v36: after_mail_view_action column on user_preferences.
      expect(userPrefsColumns, contains('after_mail_view_action'));

      // v37: image_trusted_senders table.
      await db.customSelect('SELECT count(*) FROM image_trusted_senders').get();

      await db.close();
      if (dbFile.existsSync()) dbFile.deleteSync();
    });

    test(
      'upgrade from v22 to latest adds list_unsubscribe_header and imap_server_id',
      () async {
        final dbFile = File('test_migration_v22.db');
        if (dbFile.existsSync()) dbFile.deleteSync();

        // Build a v22 database schema directly with raw SQL.
        final rawDb = sqlite.sqlite3.open(dbFile.path);
        rawDb.execute('''
        CREATE TABLE accounts (
          id TEXT NOT NULL PRIMARY KEY,
          display_name TEXT NOT NULL,
          email TEXT NOT NULL,
          imap_host TEXT NOT NULL,
          imap_port INTEGER NOT NULL DEFAULT 993,
          imap_ssl INTEGER NOT NULL DEFAULT 1 CHECK ("imap_ssl" IN (0, 1)),
          smtp_host TEXT NOT NULL DEFAULT '',
          smtp_port INTEGER NOT NULL DEFAULT 465,
          smtp_ssl INTEGER NOT NULL DEFAULT 1 CHECK ("smtp_ssl" IN (0, 1)),
          account_type TEXT NOT NULL DEFAULT 'imap',
          jmap_url TEXT NULL,
          username TEXT NULL,
          manage_sieve_host TEXT NULL,
          manage_sieve_port INTEGER NULL,
          manage_sieve_ssl INTEGER NULL,
          manage_sieve_available INTEGER NOT NULL DEFAULT 0 CHECK ("manage_sieve_available" IN (0, 1)),
          verbose INTEGER NOT NULL DEFAULT 0 CHECK ("verbose" IN (0, 1))
        );
      ''');
        rawDb.execute('''
        CREATE TABLE drafts (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          account_id TEXT NULL,
          reply_to_email_id TEXT NULL,
          to_text TEXT NOT NULL DEFAULT '',
          cc_text TEXT NOT NULL DEFAULT '',
          subject_text TEXT NOT NULL DEFAULT '',
          body_text TEXT NOT NULL DEFAULT '',
          updated_at INTEGER NOT NULL
        );
      ''');
        rawDb.execute('''
        CREATE TABLE mailboxes (
          id TEXT NOT NULL PRIMARY KEY,
          account_id TEXT NOT NULL,
          path TEXT NOT NULL,
          name TEXT NOT NULL,
          unread_count INTEGER NOT NULL DEFAULT 0,
          total_count INTEGER NOT NULL DEFAULT 0,
          role TEXT NULL
        );
      ''');
        rawDb.execute('''
        CREATE TABLE emails (
          id TEXT NOT NULL PRIMARY KEY,
          account_id TEXT NOT NULL,
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
          has_attachment INTEGER NOT NULL DEFAULT 0 CHECK ("has_attachment" IN (0, 1)),
          thread_id TEXT NULL,
          message_id TEXT NULL,
          in_reply_to TEXT NULL,
          "references" TEXT NULL,
          snoozed_until INTEGER NULL,
          snoozed_from_mailbox_path TEXT NULL
        );
      ''');
        rawDb.execute('''
        CREATE TABLE threads (
          account_id TEXT NOT NULL,
          mailbox_path TEXT NOT NULL,
          id TEXT NOT NULL,
          subject TEXT NULL,
          latest_date INTEGER NOT NULL,
          message_count INTEGER NOT NULL DEFAULT 1,
          has_unread INTEGER NOT NULL DEFAULT 0 CHECK ("has_unread" IN (0, 1)),
          is_flagged INTEGER NOT NULL DEFAULT 0 CHECK ("is_flagged" IN (0, 1)),
          participants_json TEXT NOT NULL DEFAULT '[]',
          preview TEXT NULL,
          latest_email_id TEXT NOT NULL,
          email_ids_json TEXT NOT NULL DEFAULT '[]',
          PRIMARY KEY (account_id, mailbox_path, id)
        );
      ''');
        rawDb.execute('''
        CREATE TABLE email_bodies (
          email_id TEXT NOT NULL PRIMARY KEY REFERENCES emails(id) ON DELETE CASCADE,
          text_body TEXT NULL,
          html_body TEXT NULL,
          attachments_json TEXT NOT NULL DEFAULT '[]',
          cached_at INTEGER NULL,
          headers_json TEXT NULL
        );
      ''');
        rawDb.execute('''
        CREATE TABLE sync_logs (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          account_id TEXT NOT NULL,
          result TEXT NOT NULL,
          error_message TEXT NULL,
          protocol TEXT NOT NULL DEFAULT '',
          items_synced INTEGER NOT NULL DEFAULT 0,
          mailboxes_synced INTEGER NOT NULL DEFAULT 0,
          pending_flushed INTEGER NOT NULL DEFAULT 0,
          emails_skipped INTEGER NOT NULL DEFAULT 0,
          bytes_transferred INTEGER NOT NULL DEFAULT 0,
          started_at INTEGER NOT NULL,
          finished_at INTEGER NOT NULL,
          protocol_log TEXT NULL
        );
      ''');
        rawDb.execute('''
        CREATE TABLE sync_log_mailboxes (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          sync_log_id INTEGER NOT NULL REFERENCES sync_logs (id) ON DELETE CASCADE,
          mailbox_path TEXT NOT NULL,
          fetched INTEGER NOT NULL DEFAULT 0,
          skipped INTEGER NOT NULL DEFAULT 0,
          bytes_transferred INTEGER NOT NULL DEFAULT 0
        );
      ''');
        rawDb.execute('PRAGMA user_version = 22;');
        rawDb.close();

        final db = AppDatabase(NativeDatabase(dbFile));
        // Trigger migration.
        await db.select(db.accounts).get();

        final emailColumns = await _tableColumns(db, 'emails');
        expect(emailColumns, contains('list_unsubscribe_header'));

        final draftColumns = await _tableColumns(db, 'drafts');
        expect(draftColumns, contains('imap_server_id'));

        // v25: new indexes on mailboxes and threads.
        final allIndexes = await db
            .customSelect("SELECT name FROM sqlite_master WHERE type='index'")
            .get();
        final indexNames =
            allIndexes.map((r) => r.read<String>('name')).toSet();
        expect(indexNames, contains('mailboxes_account_id'));
        expect(indexNames, contains('threads_latest_date'));

        // v26: FTS5 virtual table and triggers.
        final allTriggers = await db
            .customSelect("SELECT name FROM sqlite_master WHERE type='trigger'")
            .get();
        final triggerNames =
            allTriggers.map((r) => r.read<String>('name')).toSet();
        expect(
          triggerNames,
          containsAll(['email_fts_ai', 'email_fts_au', 'email_fts_ad']),
        );
        await db.customSelect('SELECT count(*) FROM email_fts').get();

        // v27: search_history_entries table.
        await db
            .customSelect('SELECT count(*) FROM search_history_entries')
            .get();

        // v28: mime_tree_json column on email_bodies.
        await db
            .customSelect('SELECT mime_tree_json FROM email_bodies LIMIT 0')
            .get();

        // v29: local_sieve_scripts table.
        await db.customSelect('SELECT count(*) FROM local_sieve_scripts').get();

        // v30: duration_ms column on sync_log_mailboxes.
        final syncLogMailboxColumns = await _tableColumns(
          db,
          'sync_log_mailboxes',
        );
        expect(syncLogMailboxColumns, contains('duration_ms'));

        // v33: error_stack_trace and is_permanent columns on sync_logs.
        final syncLogColumns = await _tableColumns(db, 'sync_logs');
        expect(syncLogColumns, contains('error_stack_trace'));
        expect(syncLogColumns, contains('is_permanent'));

        // v34: user_preferences table.
        await db.customSelect('SELECT count(*) FROM user_preferences').get();

        // v35: mail_view_button_position column on user_preferences.
        final userPrefsColumns = await _tableColumns(db, 'user_preferences');
        expect(userPrefsColumns, contains('mail_view_button_position'));

        // v36: after_mail_view_action column on user_preferences.
        expect(userPrefsColumns, contains('after_mail_view_action'));

        // v37: image_trusted_senders table.
        await db
            .customSelect('SELECT count(*) FROM image_trusted_senders')
            .get();

        await db.close();
        if (dbFile.existsSync()) dbFile.deleteSync();
      },
    );

    test('fresh install creates all tables at schemaVersion 37', () async {
      final db = AppDatabase(NativeDatabase.memory());
      await db.select(db.accounts).get();

      final allTables = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
          .get();
      final tableNames = allTables.map((r) => r.read<String>('name')).toSet();
      expect(
        tableNames,
        containsAll([
          'accounts',
          'mailboxes',
          'emails',
          'email_bodies',
          'drafts',
          'sync_states',
          'pending_changes',
          'sync_logs',
          'sync_log_mailboxes',
          'threads',
          'sync_health',
          'undo_actions',
          'search_history_entries',
          'local_sieve_scripts', // v29
          'share_keys', // v31
          'local_sieve_applied', // v32
          'user_preferences', // v34
          'image_trusted_senders', // v37
        ]),
      );

      final emailColumns = await _tableColumns(db, 'emails');
      expect(emailColumns, contains('list_unsubscribe_header'));

      final draftColumns = await _tableColumns(db, 'drafts');
      expect(draftColumns, contains('imap_server_id'));

      // v30: duration_ms column on sync_log_mailboxes.
      final syncLogMailboxColumns = await _tableColumns(
        db,
        'sync_log_mailboxes',
      );
      expect(syncLogMailboxColumns, contains('duration_ms'));

      // v33: error_stack_trace and is_permanent columns on sync_logs.
      final syncLogColumns = await _tableColumns(db, 'sync_logs');
      expect(syncLogColumns, contains('error_stack_trace'));
      expect(syncLogColumns, contains('is_permanent'));

      // v35: mail_view_button_position column on user_preferences.
      final userPrefsColumns = await _tableColumns(db, 'user_preferences');
      expect(userPrefsColumns, contains('mail_view_button_position'));

      // v36: after_mail_view_action column on user_preferences.
      expect(userPrefsColumns, contains('after_mail_view_action'));

      // v37: image_trusted_senders table.
      await db.customSelect('SELECT count(*) FROM image_trusted_senders').get();

      await db.close();
    });
  });
}
