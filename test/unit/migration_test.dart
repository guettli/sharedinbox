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
      expect(db.schemaVersion, 52);
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

      // v52: local self-sent "virtual" message marker.
      expect(emailColumns, contains('is_local'));

      // v8: mailboxes role column.
      final mailboxColumns = await _tableColumns(db, 'mailboxes');
      expect(mailboxColumns, contains('role'));

      // v9: email_bodies cached_at column.
      final bodyColumns = await _tableColumns(db, 'email_bodies');
      expect(bodyColumns, contains('cached_at'));
      expect(bodyColumns, contains('headers_json'));

      // v4: drafts table with v24 imap_server_id column, v43 sync columns.
      final draftColumns = await _tableColumns(db, 'drafts');
      expect(draftColumns, contains('imap_server_id'));
      expect(draftColumns, contains('jmap_server_id')); // v43
      expect(draftColumns, contains('dirty')); // v43

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
          'draft_tombstones', // v43
          'outbox', // v46
        ]),
      );

      // v51: last_error column on sync_health.
      final syncHealthColumns = await _tableColumns(db, 'sync_health');
      expect(syncHealthColumns, contains('last_error'));

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
      // v44: mailbox_name column on sync_log_mailboxes.
      expect(syncLogMailboxColumns, contains('mailbox_name'));

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
        // v44: mailbox_name column on sync_log_mailboxes.
        expect(syncLogMailboxColumns, contains('mailbox_name'));

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

        // v38: prefetch_mode and body_cache_limit_mb columns on user_preferences.
        expect(userPrefsColumns, contains('prefetch_mode'));
        expect(userPrefsColumns, contains('body_cache_limit_mb'));

        // v39: email_notes table.
        await db.customSelect('SELECT count(*) FROM email_notes').get();

        // v40: installed_versions table.
        await db.customSelect('SELECT count(*) FROM installed_versions').get();

        // v45: app_logs table and its supporting indexes.
        await db.customSelect('SELECT count(*) FROM app_logs').get();
        expect(indexNames, contains('app_logs_created_at'));
        expect(indexNames, contains('app_logs_account_created_at'));
        expect(indexNames, contains('app_logs_level'));
        expect(indexNames, contains('app_logs_sync_log_id'));

        await db.close();
        if (dbFile.existsSync()) dbFile.deleteSync();
      },
    );

    test('v40→v41: IMAP email IDs gain mailboxPath segment', () async {
      final dbFile = File('test_migration_v40.db');
      if (dbFile.existsSync()) dbFile.deleteSync();

      final rawDb = sqlite.sqlite3.open(dbFile.path);
      rawDb.execute('''
        CREATE TABLE accounts (
          id TEXT NOT NULL PRIMARY KEY,
          display_name TEXT NOT NULL,
          email TEXT NOT NULL,
          imap_host TEXT NOT NULL DEFAULT '',
          imap_port INTEGER NOT NULL DEFAULT 993,
          imap_ssl INTEGER NOT NULL DEFAULT 1,
          smtp_host TEXT NOT NULL DEFAULT '',
          smtp_port INTEGER NOT NULL DEFAULT 465,
          smtp_ssl INTEGER NOT NULL DEFAULT 1,
          account_type TEXT NOT NULL DEFAULT 'imap',
          jmap_url TEXT NULL,
          username TEXT NOT NULL DEFAULT '',
          verbose INTEGER NOT NULL DEFAULT 0,
          manage_sieve_host TEXT NOT NULL DEFAULT '',
          manage_sieve_port INTEGER NOT NULL DEFAULT 4190,
          manage_sieve_ssl INTEGER NOT NULL DEFAULT 1,
          manage_sieve_available INTEGER NULL
        )
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
          is_seen INTEGER NOT NULL DEFAULT 0,
          is_flagged INTEGER NOT NULL DEFAULT 0,
          has_attachment INTEGER NOT NULL DEFAULT 0,
          thread_id TEXT NULL,
          message_id TEXT NULL,
          in_reply_to TEXT NULL,
          "references" TEXT NULL,
          snoozed_until INTEGER NULL,
          snoozed_from_mailbox_path TEXT NULL,
          list_unsubscribe_header TEXT NULL
        )
      ''');
      rawDb.execute('''
        CREATE TABLE email_bodies (
          email_id TEXT NOT NULL PRIMARY KEY REFERENCES emails (id) ON DELETE CASCADE,
          text_body TEXT NULL,
          html_body TEXT NULL,
          attachments_json TEXT NOT NULL DEFAULT '[]',
          cached_at INTEGER NULL,
          headers_json TEXT NULL,
          mime_tree_json TEXT NULL
        )
      ''');
      rawDb.execute('''
        CREATE TABLE threads (
          account_id TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
          mailbox_path TEXT NOT NULL,
          id TEXT NOT NULL,
          subject TEXT NULL,
          latest_date INTEGER NOT NULL,
          message_count INTEGER NOT NULL DEFAULT 1,
          has_unread INTEGER NOT NULL DEFAULT 0,
          is_flagged INTEGER NOT NULL DEFAULT 0,
          participants_json TEXT NOT NULL DEFAULT '[]',
          preview TEXT NULL,
          latest_email_id TEXT NOT NULL,
          email_ids_json TEXT NOT NULL DEFAULT '[]',
          PRIMARY KEY (account_id, mailbox_path, id)
        )
      ''');
      rawDb.execute('''
        CREATE TABLE pending_changes (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          account_id TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
          resource_type TEXT NOT NULL,
          resource_id TEXT NOT NULL,
          change_type TEXT NOT NULL,
          payload TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          attempts INTEGER NOT NULL DEFAULT 0,
          last_error TEXT NULL
        )
      ''');
      // email_notes already exists in any real v40 database (added in v39);
      // the v42 migration backfills email_notes_fts from it, so the test
      // setup must include the table for the migration chain to succeed.
      rawDb.execute('''
        CREATE TABLE email_notes (
          id TEXT NOT NULL PRIMARY KEY,
          account_id TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
          message_id TEXT NOT NULL,
          note_text TEXT NOT NULL,
          server_id TEXT NOT NULL,
          created_at INTEGER NOT NULL
        )
      ''');
      // drafts exists at v40 (was created at v4, gained imap_server_id at v24).
      // Required so the v43 addColumn for jmap_server_id/dirty has a table.
      rawDb.execute('''
        CREATE TABLE drafts (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          account_id TEXT NULL,
          reply_to_email_id TEXT NULL,
          to_text TEXT NOT NULL DEFAULT '',
          cc_text TEXT NOT NULL DEFAULT '',
          subject_text TEXT NOT NULL DEFAULT '',
          body_text TEXT NOT NULL DEFAULT '',
          updated_at INTEGER NOT NULL,
          imap_server_id TEXT NULL
        )
      ''');
      // sync_log_mailboxes was created at v12; v44 addColumn for mailbox_name
      // needs this table to exist on the upgrade path.
      rawDb.execute('''
        CREATE TABLE sync_log_mailboxes (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          sync_log_id INTEGER NOT NULL,
          mailbox_path TEXT NOT NULL,
          fetched INTEGER NOT NULL DEFAULT 0,
          skipped INTEGER NOT NULL DEFAULT 0,
          bytes_transferred INTEGER NOT NULL DEFAULT 0,
          duration_ms INTEGER NULL
        )
      ''');

      // Insert an IMAP account.
      rawDb.execute(
        "INSERT INTO accounts (id, display_name, email) VALUES ('acc-1', 'Alice', 'alice@example.com')",
      );

      // Two emails with the same UID but in different mailboxes — old format.
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      rawDb.execute(
        'INSERT INTO emails (id, account_id, mailbox_path, uid, received_at, thread_id) '
        "VALUES ('acc-1:50', 'acc-1', 'INBOX', 50, $now, 'acc-1:50')",
      );
      rawDb.execute(
        'INSERT INTO emails (id, account_id, mailbox_path, uid, received_at) '
        "VALUES ('acc-1:50-arch', 'acc-1', 'Archive', 50, $now)",
      );
      // A third email with a Message-ID-based thread_id (should not be changed).
      rawDb.execute(
        'INSERT INTO emails (id, account_id, mailbox_path, uid, received_at, thread_id) '
        "VALUES ('acc-1:99', 'acc-1', 'INBOX', 99, $now, '<original@example.com>')",
      );

      // Email body for the first email.
      rawDb.execute(
        "INSERT INTO email_bodies (email_id, text_body) VALUES ('acc-1:50', 'body text')",
      );

      // Thread for the first email (old-format IDs).
      rawDb.execute(
        'INSERT INTO threads (account_id, mailbox_path, id, latest_date, latest_email_id, email_ids_json) '
        "VALUES ('acc-1', 'INBOX', 'acc-1:50', $now, 'acc-1:50', '[\"acc-1:50\"]')",
      );

      // A pending change referencing the first email's old ID.
      rawDb.execute(
        'INSERT INTO pending_changes (account_id, resource_type, resource_id, change_type, payload, created_at) '
        "VALUES ('acc-1', 'Email', 'acc-1:50', 'flag_seen', '{\"seen\":true}', $now)",
      );

      rawDb.execute('PRAGMA user_version = 40');
      rawDb.close();

      // Open with Drift to trigger the migration.
      final db = AppDatabase(NativeDatabase(dbFile));
      await db.select(db.accounts).get();

      // emails.id should now use the accountId:mailboxPath:uid format.
      final emailRows = await db.select(db.emails).get();
      final emailIds = emailRows.map((r) => r.id).toSet();
      expect(emailIds, contains('acc-1:INBOX:50'));
      expect(emailIds, contains('acc-1:Archive:50'));
      expect(emailIds, contains('acc-1:INBOX:99'));
      // Old-format IDs must be gone.
      expect(emailIds, isNot(contains('acc-1:50')));
      expect(emailIds, isNot(contains('acc-1:99')));

      // email_bodies.email_id must be updated.
      final bodyRows = await db.select(db.emailBodies).get();
      expect(bodyRows, hasLength(1));
      expect(bodyRows.first.emailId, 'acc-1:INBOX:50');

      // thread_id where it was the email's own ID should be updated.
      final inboxEmail = emailRows.firstWhere((r) => r.id == 'acc-1:INBOX:50');
      expect(inboxEmail.threadId, 'acc-1:INBOX:50');

      // thread_id based on a real Message-ID must be left unchanged.
      final inboxEmail99 =
          emailRows.firstWhere((r) => r.id == 'acc-1:INBOX:99');
      expect(inboxEmail99.threadId, '<original@example.com>');

      // threads must be rebuilt with new-format IDs.
      final threadRows = await db.select(db.threads).get();
      final thread = threadRows.firstWhere((t) => t.mailboxPath == 'INBOX');
      expect(thread.latestEmailId, 'acc-1:INBOX:50');
      expect(thread.emailIdsJson, contains('acc-1:INBOX:50'));

      // pending_changes.resource_id is not updated by the migration
      // (IMAP operations use payload uid/mailboxPath, so this is safe).
      final changeRows = await db.select(db.pendingChanges).get();
      expect(changeRows, hasLength(1));

      await db.close();
      if (dbFile.existsSync()) dbFile.deleteSync();
    });

    test('fresh install creates all tables at schemaVersion 44', () async {
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
          'email_notes', // v39
          'installed_versions', // v40
          'draft_tombstones', // v43
          'outbox', // v46
        ]),
      );

      final emailColumns = await _tableColumns(db, 'emails');
      expect(emailColumns, contains('list_unsubscribe_header'));

      final draftColumns = await _tableColumns(db, 'drafts');
      expect(draftColumns, contains('imap_server_id'));
      expect(draftColumns, contains('jmap_server_id')); // v43
      expect(draftColumns, contains('dirty')); // v43

      // v30: duration_ms column on sync_log_mailboxes.
      final syncLogMailboxColumns = await _tableColumns(
        db,
        'sync_log_mailboxes',
      );
      expect(syncLogMailboxColumns, contains('duration_ms'));
      // v44: mailbox_name column on sync_log_mailboxes.
      expect(syncLogMailboxColumns, contains('mailbox_name'));

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

      // v38: prefetch_mode and body_cache_limit_mb columns on user_preferences.
      expect(userPrefsColumns, contains('prefetch_mode'));
      expect(userPrefsColumns, contains('body_cache_limit_mb'));

      // v39: email_notes table.
      await db.customSelect('SELECT count(*) FROM email_notes').get();

      // v40: installed_versions table.
      await db.customSelect('SELECT count(*) FROM installed_versions').get();

      // v42: email_notes FTS5 virtual table and triggers.
      final triggerNames = (await db
              .customSelect(
                "SELECT name FROM sqlite_master WHERE type='trigger'",
              )
              .get())
          .map((r) => r.read<String>('name'))
          .toSet();
      expect(
        triggerNames,
        containsAll([
          'email_notes_fts_ai',
          'email_notes_fts_au',
          'email_notes_fts_ad',
        ]),
      );
      await db.customSelect('SELECT count(*) FROM email_notes_fts').get();

      await db.close();
    });

    test('v41→v42: email_notes FTS table is created and backfilled', () async {
      final dbFile = File('test_migration_v41_to_v42.db');
      if (dbFile.existsSync()) dbFile.deleteSync();

      final rawDb = sqlite.sqlite3.open(dbFile.path);
      // Minimal v41 schema needed to upgrade: accounts, emails, email_notes
      // (plus the tables the v41 migration block touches: email_bodies,
      // threads, pending_changes).
      rawDb.execute('''
        CREATE TABLE accounts (
          id TEXT NOT NULL PRIMARY KEY,
          display_name TEXT NOT NULL,
          email TEXT NOT NULL,
          imap_host TEXT NOT NULL DEFAULT '',
          imap_port INTEGER NOT NULL DEFAULT 993,
          imap_ssl INTEGER NOT NULL DEFAULT 1,
          smtp_host TEXT NOT NULL DEFAULT '',
          smtp_port INTEGER NOT NULL DEFAULT 465,
          smtp_ssl INTEGER NOT NULL DEFAULT 1,
          account_type TEXT NOT NULL DEFAULT 'jmap',
          jmap_url TEXT NULL,
          username TEXT NOT NULL DEFAULT '',
          verbose INTEGER NOT NULL DEFAULT 0,
          manage_sieve_host TEXT NOT NULL DEFAULT '',
          manage_sieve_port INTEGER NOT NULL DEFAULT 4190,
          manage_sieve_ssl INTEGER NOT NULL DEFAULT 1,
          manage_sieve_available INTEGER NULL
        )
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
          is_seen INTEGER NOT NULL DEFAULT 0,
          is_flagged INTEGER NOT NULL DEFAULT 0,
          has_attachment INTEGER NOT NULL DEFAULT 0,
          thread_id TEXT NULL,
          message_id TEXT NULL,
          in_reply_to TEXT NULL,
          "references" TEXT NULL,
          snoozed_until INTEGER NULL,
          snoozed_from_mailbox_path TEXT NULL,
          list_unsubscribe_header TEXT NULL
        )
      ''');
      rawDb.execute('''
        CREATE TABLE email_notes (
          id TEXT NOT NULL PRIMARY KEY,
          account_id TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
          message_id TEXT NOT NULL,
          note_text TEXT NOT NULL,
          server_id TEXT NOT NULL,
          created_at INTEGER NOT NULL
        )
      ''');
      // drafts exists at v41 (created at v4); the migration continues past v42
      // to v43, whose addColumn for jmap_server_id/dirty needs this table.
      rawDb.execute('''
        CREATE TABLE drafts (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          account_id TEXT NULL,
          reply_to_email_id TEXT NULL,
          to_text TEXT NOT NULL DEFAULT '',
          cc_text TEXT NOT NULL DEFAULT '',
          subject_text TEXT NOT NULL DEFAULT '',
          body_text TEXT NOT NULL DEFAULT '',
          updated_at INTEGER NOT NULL,
          imap_server_id TEXT NULL
        )
      ''');
      // sync_log_mailboxes was created at v12; v44 addColumn for mailbox_name
      // needs this table to exist on the upgrade path.
      rawDb.execute('''
        CREATE TABLE sync_log_mailboxes (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          sync_log_id INTEGER NOT NULL,
          mailbox_path TEXT NOT NULL,
          fetched INTEGER NOT NULL DEFAULT 0,
          skipped INTEGER NOT NULL DEFAULT 0,
          bytes_transferred INTEGER NOT NULL DEFAULT 0,
          duration_ms INTEGER NULL
        )
      ''');

      // Pre-existing note row that the v42 backfill must index.
      rawDb.execute(
        'INSERT INTO accounts (id, display_name, email) '
        "VALUES ('acc-1', 'Alice', 'alice@example.com')",
      );
      rawDb.execute(
        'INSERT INTO email_notes (id, account_id, message_id, note_text, server_id, created_at) '
        "VALUES ('note-1', 'acc-1', '<msg1@example.com>', 'urgent follow-up needed', '42', 0)",
      );

      rawDb.execute('PRAGMA user_version = 41');
      rawDb.close();

      final db = AppDatabase(NativeDatabase(dbFile));
      // Trigger migration.
      await db.select(db.accounts).get();

      // The FTS table and its sync triggers must exist.
      final triggerNames = (await db
              .customSelect(
                "SELECT name FROM sqlite_master WHERE type='trigger'",
              )
              .get())
          .map((r) => r.read<String>('name'))
          .toSet();
      expect(
        triggerNames,
        containsAll([
          'email_notes_fts_ai',
          'email_notes_fts_au',
          'email_notes_fts_ad',
        ]),
      );

      // Backfill: the pre-existing note must be searchable via MATCH.
      final matches = await db
          .customSelect(
            "SELECT rowid FROM email_notes_fts WHERE email_notes_fts MATCH 'urgent'",
          )
          .get();
      expect(matches, hasLength(1));

      await db.close();
      if (dbFile.existsSync()) dbFile.deleteSync();
    });

    test('v43→v44: sync_log_mailboxes gains mailbox_name column', () async {
      final dbFile = File('test_migration_v43_to_v44.db');
      if (dbFile.existsSync()) dbFile.deleteSync();

      // Build a minimal v43 schema with sync_logs + sync_log_mailboxes and a
      // pre-existing row so the migration must add the column without losing
      // data. Tables that other migrations touch (drafts, email_notes, …) are
      // not relevant past v43, so we keep this slim.
      final rawDb = sqlite.sqlite3.open(dbFile.path);
      rawDb.execute('''
        CREATE TABLE accounts (
          id TEXT NOT NULL PRIMARY KEY,
          display_name TEXT NOT NULL,
          email TEXT NOT NULL,
          imap_host TEXT NOT NULL DEFAULT '',
          imap_port INTEGER NOT NULL DEFAULT 993,
          imap_ssl INTEGER NOT NULL DEFAULT 1,
          smtp_host TEXT NOT NULL DEFAULT '',
          smtp_port INTEGER NOT NULL DEFAULT 465,
          smtp_ssl INTEGER NOT NULL DEFAULT 1,
          account_type TEXT NOT NULL DEFAULT 'jmap',
          jmap_url TEXT NULL,
          username TEXT NOT NULL DEFAULT '',
          verbose INTEGER NOT NULL DEFAULT 0,
          manage_sieve_host TEXT NOT NULL DEFAULT '',
          manage_sieve_port INTEGER NOT NULL DEFAULT 4190,
          manage_sieve_ssl INTEGER NOT NULL DEFAULT 1,
          manage_sieve_available INTEGER NULL
        )
      ''');
      rawDb.execute('''
        CREATE TABLE sync_logs (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          account_id TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
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
          protocol_log TEXT NULL,
          error_stack_trace TEXT NULL,
          is_permanent INTEGER NOT NULL DEFAULT 0
        )
      ''');
      rawDb.execute('''
        CREATE TABLE sync_log_mailboxes (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          sync_log_id INTEGER NOT NULL REFERENCES sync_logs (id) ON DELETE CASCADE,
          mailbox_path TEXT NOT NULL,
          fetched INTEGER NOT NULL DEFAULT 0,
          skipped INTEGER NOT NULL DEFAULT 0,
          bytes_transferred INTEGER NOT NULL DEFAULT 0,
          duration_ms INTEGER NULL
        )
      ''');

      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      rawDb.execute(
        'INSERT INTO accounts (id, display_name, email) '
        "VALUES ('acc-1', 'Alice', 'alice@example.com')",
      );
      rawDb.execute(
        'INSERT INTO sync_logs (id, account_id, result, protocol, '
        'started_at, finished_at) '
        "VALUES (1, 'acc-1', 'ok', 'jmap', $now, $now)",
      );
      // A JMAP row mimicking the bug: opaque id as path, no display name.
      rawDb.execute(
        'INSERT INTO sync_log_mailboxes '
        '(sync_log_id, mailbox_path, fetched, skipped, bytes_transferred, duration_ms) '
        "VALUES (1, 'a', 0, 0, 0, 510)",
      );

      rawDb.execute('PRAGMA user_version = 43');
      rawDb.close();

      final db = AppDatabase(NativeDatabase(dbFile));
      // Trigger migration.
      await db.select(db.accounts).get();

      // The new column must exist.
      final cols = await _tableColumns(db, 'sync_log_mailboxes');
      expect(cols, contains('mailbox_name'));

      // The pre-existing row must survive the migration and have a null name.
      final rows = await db.select(db.syncLogMailboxes).get();
      expect(rows, hasLength(1));
      expect(rows.first.mailboxPath, 'a');
      expect(rows.first.mailboxName, isNull);

      await db.close();
      if (dbFile.existsSync()) dbFile.deleteSync();
    });

    // #406: legacy IMAP rows written before commit 6db1f31 still store
    // Message-ID / In-Reply-To / References with the RFC 5322 `<...>`
    // brackets. The v49 migration strips them so they compare cleanly against
    // JMAP rows, which have always been bracket-less (RFC 8621 §4.1.2.3).
    test('v48→v49: strips angle brackets from legacy message-id columns',
        () async {
      final dbFile = File('test_migration_v48_to_v49.db');
      if (dbFile.existsSync()) dbFile.deleteSync();

      final rawDb = sqlite.sqlite3.open(dbFile.path);
      rawDb.execute('''
        CREATE TABLE accounts (
          id TEXT NOT NULL PRIMARY KEY,
          display_name TEXT NOT NULL,
          email TEXT NOT NULL,
          imap_host TEXT NOT NULL DEFAULT '',
          imap_port INTEGER NOT NULL DEFAULT 993,
          imap_ssl INTEGER NOT NULL DEFAULT 1,
          smtp_host TEXT NOT NULL DEFAULT '',
          smtp_port INTEGER NOT NULL DEFAULT 465,
          smtp_ssl INTEGER NOT NULL DEFAULT 1,
          account_type TEXT NOT NULL DEFAULT 'imap',
          jmap_url TEXT NULL,
          username TEXT NOT NULL DEFAULT '',
          verbose INTEGER NOT NULL DEFAULT 0,
          manage_sieve_host TEXT NOT NULL DEFAULT '',
          manage_sieve_port INTEGER NOT NULL DEFAULT 4190,
          manage_sieve_ssl INTEGER NOT NULL DEFAULT 1,
          manage_sieve_available INTEGER NULL
        )
      ''');
      // Emails schema mirrors the v48 shape (post-v41 wide format).
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
          is_seen INTEGER NOT NULL DEFAULT 0,
          is_flagged INTEGER NOT NULL DEFAULT 0,
          has_attachment INTEGER NOT NULL DEFAULT 0,
          thread_id TEXT NULL,
          message_id TEXT NULL,
          in_reply_to TEXT NULL,
          "references" TEXT NULL,
          snoozed_until INTEGER NULL,
          snoozed_from_mailbox_path TEXT NULL,
          list_unsubscribe_header TEXT NULL
        )
      ''');
      // email_bodies (created at v9) is referenced by the v48 migration when
      // it lands on this schema, but it doesn't need any rows for our test.
      rawDb.execute('''
        CREATE TABLE email_bodies (
          email_id TEXT NOT NULL PRIMARY KEY REFERENCES emails (id) ON DELETE CASCADE,
          text_body TEXT NULL,
          html_body TEXT NULL,
          attachments_json TEXT NOT NULL DEFAULT '[]',
          cached_at INTEGER NULL,
          headers_json TEXT NULL,
          mime_tree_json TEXT NULL
        )
      ''');

      rawDb.execute(
        "INSERT INTO accounts (id, display_name, email) VALUES ('acc-1', 'Alice', 'alice@example.com')",
      );
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      // 1. Row with bracketed ids in all three columns — must be stripped.
      rawDb.execute(
        'INSERT INTO emails '
        '(id, account_id, mailbox_path, uid, received_at, message_id, in_reply_to, "references") '
        "VALUES ('acc-1:INBOX:1', 'acc-1', 'INBOX', 1, $now, '<a1@example.com>', '<parent@example.com>', '<r1@example.com> <r2@example.com>')",
      );
      // 2. Row with already-clean ids — must be left untouched.
      rawDb.execute(
        'INSERT INTO emails '
        '(id, account_id, mailbox_path, uid, received_at, message_id, in_reply_to, "references") '
        "VALUES ('acc-1:INBOX:2', 'acc-1', 'INBOX', 2, $now, 'clean@example.com', NULL, NULL)",
      );
      // 3. Row with mixed bracketed / bracket-less references tokens.
      rawDb.execute(
        'INSERT INTO emails '
        '(id, account_id, mailbox_path, uid, received_at, message_id, "references") '
        "VALUES ('acc-1:INBOX:3', 'acc-1', 'INBOX', 3, $now, 'clean@example.com', '<a@x> b@y <c@z>')",
      );

      rawDb.execute('PRAGMA user_version = 48');
      rawDb.close();

      final db = AppDatabase(NativeDatabase(dbFile));
      await db.select(db.accounts).get();

      final rows = await db.select(db.emails).get();
      final byId = {for (final r in rows) r.id: r};

      expect(byId['acc-1:INBOX:1']?.messageId, 'a1@example.com');
      expect(byId['acc-1:INBOX:1']?.inReplyTo, 'parent@example.com');
      expect(
        byId['acc-1:INBOX:1']?.references,
        'r1@example.com r2@example.com',
      );

      expect(byId['acc-1:INBOX:2']?.messageId, 'clean@example.com');
      expect(byId['acc-1:INBOX:2']?.inReplyTo, isNull);
      expect(byId['acc-1:INBOX:2']?.references, isNull);

      expect(byId['acc-1:INBOX:3']?.references, 'a@x b@y c@z');

      await db.close();
      if (dbFile.existsSync()) dbFile.deleteSync();
    });

    // #328: full-body search. The v50 migration adds the email_body_fts FTS5
    // shadow table + sync triggers and backfills it from existing bodies.
    test('v49→v50: creates email_body_fts and backfills existing bodies',
        () async {
      final dbFile = File('test_migration_v49_to_v50.db');
      if (dbFile.existsSync()) dbFile.deleteSync();

      final rawDb = sqlite.sqlite3.open(dbFile.path);
      rawDb.execute('''
        CREATE TABLE accounts (
          id TEXT NOT NULL PRIMARY KEY,
          display_name TEXT NOT NULL,
          email TEXT NOT NULL,
          imap_host TEXT NOT NULL DEFAULT '',
          imap_port INTEGER NOT NULL DEFAULT 993,
          imap_ssl INTEGER NOT NULL DEFAULT 1,
          smtp_host TEXT NOT NULL DEFAULT '',
          smtp_port INTEGER NOT NULL DEFAULT 465,
          smtp_ssl INTEGER NOT NULL DEFAULT 1,
          account_type TEXT NOT NULL DEFAULT 'imap',
          jmap_url TEXT NULL,
          username TEXT NOT NULL DEFAULT '',
          verbose INTEGER NOT NULL DEFAULT 0,
          manage_sieve_host TEXT NOT NULL DEFAULT '',
          manage_sieve_port INTEGER NOT NULL DEFAULT 4190,
          manage_sieve_ssl INTEGER NOT NULL DEFAULT 1,
          manage_sieve_available INTEGER NULL
        )
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
          is_seen INTEGER NOT NULL DEFAULT 0,
          is_flagged INTEGER NOT NULL DEFAULT 0,
          has_attachment INTEGER NOT NULL DEFAULT 0,
          thread_id TEXT NULL,
          message_id TEXT NULL,
          in_reply_to TEXT NULL,
          "references" TEXT NULL,
          snoozed_until INTEGER NULL,
          snoozed_from_mailbox_path TEXT NULL,
          list_unsubscribe_header TEXT NULL
        )
      ''');
      // email_bodies at v49 shape (post-v48: gained body_size at v48).
      rawDb.execute('''
        CREATE TABLE email_bodies (
          email_id TEXT NOT NULL PRIMARY KEY REFERENCES emails (id) ON DELETE CASCADE,
          text_body TEXT NULL,
          html_body TEXT NULL,
          attachments_json TEXT NOT NULL DEFAULT '[]',
          cached_at INTEGER NULL,
          headers_json TEXT NULL,
          mime_tree_json TEXT NULL,
          body_size INTEGER NULL
        )
      ''');

      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      rawDb.execute(
        "INSERT INTO accounts (id, display_name, email) VALUES ('acc-1', 'Alice', 'alice@example.com')",
      );
      rawDb.execute(
        'INSERT INTO emails (id, account_id, mailbox_path, uid, subject, received_at) '
        "VALUES ('acc-1:INBOX:1', 'acc-1', 'INBOX', 1, 'Trip', $now)",
      );
      // Pre-existing body whose text the v50 backfill must index.
      rawDb.execute(
        'INSERT INTO email_bodies (email_id, text_body) '
        "VALUES ('acc-1:INBOX:1', 'Please book the flamingo sanctuary tour')",
      );

      rawDb.execute('PRAGMA user_version = 49');
      rawDb.close();

      final db = AppDatabase(NativeDatabase(dbFile));
      // Trigger migration.
      await db.select(db.accounts).get();

      // The FTS table and its sync triggers must exist.
      final triggerNames = (await db
              .customSelect(
                "SELECT name FROM sqlite_master WHERE type='trigger'",
              )
              .get())
          .map((r) => r.read<String>('name'))
          .toSet();
      expect(
        triggerNames,
        containsAll([
          'email_body_fts_ai',
          'email_body_fts_au',
          'email_body_fts_ad',
        ]),
      );

      // Backfill: the pre-existing body must be searchable via MATCH, and a
      // word only present in the body (not the subject) proves full-body
      // coverage rather than a preview snippet.
      final matches = await db
          .customSelect(
            "SELECT rowid FROM email_body_fts WHERE email_body_fts MATCH 'flamingo'",
          )
          .get();
      expect(matches, hasLength(1));

      await db.close();
      if (dbFile.existsSync()) dbFile.deleteSync();
    });
  });

  // Regression test for https://codeberg.org/guettli/sharedinbox/issues/508:
  // _openConnection's setup callback must not crash when PRAGMA journal_mode =
  // WAL fails with SQLITE_BUSY_SNAPSHOT (extended code 261, primary code 5)
  // because a WorkManager background task already has the DB open in WAL mode.
  group('WAL setup (#508)', () {
    test(
      'setupPragmasForTesting does not throw when WAL is already active and '
      'another connection holds an open read transaction',
      () {
        final dbFile = File('test_wal_busy_508.db');
        if (dbFile.existsSync()) dbFile.deleteSync();
        addTearDown(() {
          if (dbFile.existsSync()) dbFile.deleteSync();
        });

        // conn1: enable WAL and keep a read transaction open — simulates a
        // WorkManager background task that opened the DB before the foreground
        // app starts.
        final conn1 = sqlite.sqlite3.open(dbFile.path);
        conn1.execute('PRAGMA journal_mode = WAL;');
        conn1.execute('BEGIN;');
        conn1.select('SELECT 1;');

        // conn2: run the exact production setup through setupPragmasForTesting.
        // This must not throw even though conn1 holds an open transaction and
        // the DB is already in WAL mode.
        final conn2 = sqlite.sqlite3.open(dbFile.path);
        expect(() => setupPragmasForTesting(conn2), returnsNormally);

        conn1.execute('ROLLBACK;');
        conn1.close();
        conn2.close();
      },
    );
  });
}
