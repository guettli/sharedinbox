import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart' show OrderingTerm, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/core/repositories/notification_rule_repository.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'db_test_helper.dart';

/// Reads all column names for [tableName] from [db].
Future<List<String>> _tableColumns(AppDatabase db, String tableName) async {
  final rows = await db.customSelect('PRAGMA table_info($tableName)').get();
  return rows.map((r) => r.read<String>('name')).toList();
}

void main() {
  group('Migration', () {
    test('schemaVersion matches expected value', () async {
      final db = AppDatabase(NativeDatabase.memory());
      expect(db.schemaVersion, 75);
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
      // Two pre-existing rows for the v55 preview repair (#680): one poisoned
      // with the partial-fetch offset token, one with a real preview. The
      // first also has an attachment, for the v60 thread backfill.
      rawDb.execute('''
        INSERT INTO emails (id, account_id, mailbox_path, uid, received_at,
                            preview, has_attachment)
        VALUES ('acc-1:INBOX:1', 'acc-1', 'INBOX', 1, 0, '0>', 1),
               ('acc-1:INBOX:2', 'acc-1', 'INBOX', 2, 0, 'A real preview.', 0);
      ''');
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

      // v54: per-account signature.
      expect(accountColumns, contains('signature'));

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

      // v53: move-stable server id (RFC 8474 EMAILID / Gmail X-GM-MSGID).
      expect(emailColumns, contains('server_email_id'));

      // v59: Reply-To addresses (#919).
      expect(emailColumns, contains('reply_to_json'));

      // v61: Bcc addresses (#1097).
      expect(emailColumns, contains('bcc_json'));

      // v64: message size for the Advanced Search size condition.
      expect(emailColumns, contains('size_bytes'));

      // v55: previews poisoned by the mis-parsed partial body fetch (#680) are
      // cleared so getEmailBody's backfill can replace them; real previews are
      // left alone.
      final previews = {
        for (final row in await db
            .customSelect('SELECT id, preview FROM emails ORDER BY id')
            .get())
          row.read<String>('id'): row.read<String?>('preview'),
      };
      expect(previews['acc-1:INBOX:1'], isNull);
      expect(previews['acc-1:INBOX:2'], 'A real preview.');

      // v60: threads built by the v17 step get has_attachment backfilled.
      final threadAttachments = [
        for (final row in await db
            .customSelect(
              'SELECT has_attachment FROM threads ORDER BY has_attachment',
            )
            .get())
          row.read<bool>('has_attachment'),
      ];
      expect(threadAttachments, [false, true]);

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
      expect(draftColumns, contains('bcc_text')); // v65
      expect(draftColumns, contains('attachments_json')); // v66
      expect(
        await _tableColumns(db, 'pending_changes'),
        containsAll(['state', 'lease_until', 'claim_token']), // v68, v69
      );
      expect(
        await _tableColumns(db, 'emails'),
        containsAll([
          'srv_mailbox_path',
          'srv_uid',
          'srv_uid_validity',
          'srv_jmap_id',
        ]), // v70
      );
      expect(
        await _tableColumns(db, 'emails'),
        contains('is_virtual_sent_copy'), // v71
      );
      expect(
        await _tableColumns(db, 'emails'),
        containsAll([
          'srv_is_seen',
          'srv_is_flagged',
          'srv_snoozed_until',
          'local_is_seen',
          'local_is_flagged',
          'local_snoozed_until',
          'srv_keywords_seq',
        ]), // v72
      );
      expect(
        await _tableColumns(db, 'pending_changes'),
        containsAll(['ack_seq', 'contradicted_seq']), // v72
      );
      expect(
        await _tableColumns(db, 'emails'),
        containsAll([
          'local_mailbox_path',
          'local_hidden',
          'srv_gone',
          'srv_location_seq',
        ]), // v73
      );
      expect(
        await _tableColumns(db, 'pending_changes'),
        contains('origin'), // v74
      );
      expect(
        await _tableColumns(db, 'mailboxes'),
        contains('unread_seq'), // v74
      );
      expect(
        await _tableColumns(db, 'mailboxes'),
        containsAll(['srv_name', 'local_name', 'is_local', 'srv_seq']), // v75
      );

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
          'bug_reports', // v58
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
          'emails_list_order', // v63, replaces v18's emails_received_at
          'emails_thread_id', // v18
          'pending_changes_account_id', // v18
          'emails_snoozed_until', // v22
          'mailboxes_account_id', // v25
          'threads_list_order', // v63, replaces v25's threads_latest_date
          'emails_server_email_id', // v53
          'emails_account_thread', // v57
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

    test('v59→v60 tolerates threads.has_attachment already present', () async {
      // An upgrade killed mid-way, or a background isolate migrating at the
      // same time, leaves the column behind while user_version stays 59.
      final dbFile = File('test_migration_v59_rerun.db');
      if (dbFile.existsSync()) dbFile.deleteSync();
      addTearDown(() {
        if (dbFile.existsSync()) dbFile.deleteSync();
      });

      final fresh = AppDatabase(NativeDatabase(dbFile));
      // Owner of the rows below: the v62 step drops rows without one.
      await seedAccountRow(fresh, 'acc-x');
      await fresh.close();

      final rawDb = sqlite.sqlite3.open(dbFile.path);
      rawDb.execute('''
        INSERT INTO emails (id, account_id, mailbox_path, uid, received_at,
                            has_attachment)
        VALUES ('e-att', 'acc-x', 'INBOX', 1, 0, 1),
               ('e-plain', 'acc-x', 'INBOX', 2, 0, 0);
      ''');
      rawDb.execute('''
        INSERT INTO threads (account_id, mailbox_path, id, latest_date,
                             latest_email_id)
        VALUES ('acc-x', 'INBOX', 'e-att', 0, 'e-att'),
               ('acc-x', 'INBOX', 'e-plain', 0, 'e-plain');
      ''');
      rawDb.execute('PRAGMA user_version = 59;');
      rawDb.close();

      final db = AppDatabase(NativeDatabase(dbFile));
      final attachmentByThread = {
        for (final row in await db
            .customSelect('SELECT id, has_attachment FROM threads')
            .get())
          row.read<String>('id'): row.read<bool>('has_attachment'),
      };
      expect(attachmentByThread, {'e-att': true, 'e-plain': false});
      await db.close();
    });

    test('a failing upgrade rolls back and can be retried', () async {
      final dbFile = File('test_migration_rollback.db');
      if (dbFile.existsSync()) dbFile.deleteSync();
      addTearDown(() {
        if (dbFile.existsSync()) dbFile.deleteSync();
      });

      final fresh = AppDatabase(NativeDatabase(dbFile));
      // Owner of the rows below: the v62 step drops rows without one.
      await seedAccountRow(fresh, 'acc-x');
      await fresh.close();

      // A v58 database (no reply_to_json) whose v60 backfill fails after the
      // v59 step has added the column.
      final rawDb = sqlite.sqlite3.open(dbFile.path);
      rawDb.execute('ALTER TABLE emails DROP COLUMN reply_to_json;');
      rawDb.execute('''
        INSERT INTO threads (account_id, mailbox_path, id, latest_date,
                             latest_email_id)
        VALUES ('acc-x', 'INBOX', 't1', 0, 'e1');
      ''');
      rawDb.execute('''
        CREATE TRIGGER fail_backfill BEFORE UPDATE ON threads
        BEGIN SELECT RAISE(ABORT, 'backfill failed'); END;
      ''');
      rawDb.execute('PRAGMA user_version = 58;');
      rawDb.close();

      final failing = AppDatabase(NativeDatabase(dbFile));
      await expectLater(
        failing.select(failing.accounts).get(),
        throwsA(anything),
      );
      await failing.close();

      final check = sqlite.sqlite3.open(dbFile.path);
      expect(check.select('PRAGMA user_version').single.values.single, 58);
      expect(
        check
            .select('PRAGMA table_info(emails)')
            .map((r) => r['name'])
            .contains('reply_to_json'),
        isFalse,
        reason: 'the v59 step must be rolled back with the failed v60 step',
      );
      check.execute('DROP TRIGGER fail_backfill;');
      check.close();

      // The next start replays v59 without "duplicate column name".
      final db = AppDatabase(NativeDatabase(dbFile));
      expect(await _tableColumns(db, 'emails'), contains('reply_to_json'));
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), 75);
      await db.close();
    });

    test('v60→v61 adds emails.bcc_json, tolerating it already present',
        () async {
      final dbFile = File('test_migration_v60_bcc.db');
      if (dbFile.existsSync()) dbFile.deleteSync();
      addTearDown(() {
        if (dbFile.existsSync()) dbFile.deleteSync();
      });

      final fresh = AppDatabase(NativeDatabase(dbFile));
      // Owner of the rows below: the v62 step drops rows without one.
      await seedAccountRow(fresh, 'acc-x');
      await fresh.close();

      // A v60 database: no bcc_json yet, one cached mail.
      var rawDb = sqlite.sqlite3.open(dbFile.path);
      rawDb.execute('ALTER TABLE emails DROP COLUMN bcc_json;');
      rawDb.execute('''
        INSERT INTO emails (id, account_id, mailbox_path, uid, received_at)
        VALUES ('e1', 'acc-x', 'Sent', 1, 0);
      ''');
      rawDb.execute('PRAGMA user_version = 60;');
      rawDb.close();

      var db = AppDatabase(NativeDatabase(dbFile));
      final row = await db
          .customSelect("SELECT bcc_json FROM emails WHERE id = 'e1'")
          .getSingle();
      expect(row.read<String>('bcc_json'), '[]');
      await db.close();

      // An interrupted earlier upgrade can leave the column at v60 already.
      rawDb = sqlite.sqlite3.open(dbFile.path);
      rawDb.execute('PRAGMA user_version = 60;');
      rawDb.close();
      db = AppDatabase(NativeDatabase(dbFile));
      expect(await _tableColumns(db, 'emails'), contains('bcc_json'));
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), 75);
      await db.close();
    });

    test('v63→v64 adds a NULL emails.size_bytes to cached mail', () async {
      final dbFile = File('test_migration_v63_size.db');
      if (dbFile.existsSync()) dbFile.deleteSync();
      addTearDown(() {
        if (dbFile.existsSync()) dbFile.deleteSync();
      });

      final fresh = AppDatabase(NativeDatabase(dbFile));
      await seedAccountRow(fresh, 'acc-x');
      await fresh.close();

      final rawDb = sqlite.sqlite3.open(dbFile.path)
        ..execute('ALTER TABLE emails DROP COLUMN size_bytes;')
        ..execute(
          'INSERT INTO emails (id, account_id, mailbox_path, uid, received_at)'
          " VALUES ('e1', 'acc-x', 'INBOX', 1, 0);",
        )
        ..execute('PRAGMA user_version = 63;');
      rawDb.close();

      final db = AppDatabase(NativeDatabase(dbFile));
      // Unknown until a sync or reconcile fills it in.
      final row = await db
          .customSelect("SELECT size_bytes FROM emails WHERE id = 'e1'")
          .getSingle();
      expect(row.read<int?>('size_bytes'), isNull);
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), 75);
      await db.close();
    });

    test('v64→v65 adds an empty drafts.bcc_text to saved drafts', () async {
      final dbFile = File('test_migration_v64_bcc_text.db');
      if (dbFile.existsSync()) dbFile.deleteSync();
      addTearDown(() {
        if (dbFile.existsSync()) dbFile.deleteSync();
      });

      final fresh = AppDatabase(NativeDatabase(dbFile));
      await seedAccountRow(fresh, 'acc-x'); // creates the schema
      await fresh.close();

      var rawDb = sqlite.sqlite3.open(dbFile.path)
        ..execute('ALTER TABLE drafts DROP COLUMN bcc_text;')
        ..execute(
          "INSERT INTO drafts (id, to_text, updated_at) VALUES (1, 'a@b', 0);",
        )
        ..execute('PRAGMA user_version = 64;');
      rawDb.close();

      var db = AppDatabase(NativeDatabase(dbFile));
      final row = await db
          .customSelect('SELECT to_text, bcc_text FROM drafts WHERE id = 1')
          .getSingle();
      expect(row.read<String>('to_text'), 'a@b');
      expect(row.read<String>('bcc_text'), '');
      await db.close();

      // An interrupted earlier upgrade can leave the column at v64 already.
      rawDb = sqlite.sqlite3.open(dbFile.path)
        ..execute('PRAGMA user_version = 64;');
      rawDb.close();
      db = AppDatabase(NativeDatabase(dbFile));
      expect(await _tableColumns(db, 'drafts'), contains('bcc_text'));
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), 75);
      await db.close();
    });

    test('v65→v66 adds an empty drafts.attachments_json to saved drafts',
        () async {
      final dbFile = File('test_migration_v65_attachments.db');
      if (dbFile.existsSync()) dbFile.deleteSync();
      addTearDown(() {
        if (dbFile.existsSync()) dbFile.deleteSync();
      });

      final fresh = AppDatabase(NativeDatabase(dbFile));
      await seedAccountRow(fresh, 'acc-x'); // creates the schema
      await fresh.close();

      var rawDb = sqlite.sqlite3.open(dbFile.path)
        ..execute('ALTER TABLE drafts DROP COLUMN attachments_json;')
        ..execute(
          "INSERT INTO drafts (id, to_text, updated_at) VALUES (1, 'a@b', 0);",
        )
        ..execute('PRAGMA user_version = 65;');
      rawDb.close();

      var db = AppDatabase(NativeDatabase(dbFile));
      final row = await db
          .customSelect(
            'SELECT to_text, attachments_json FROM drafts WHERE id = 1',
          )
          .getSingle();
      expect(row.read<String>('to_text'), 'a@b');
      expect(row.read<String>('attachments_json'), '[]');
      await db.close();

      // An interrupted earlier upgrade can leave the column at v65 already.
      rawDb = sqlite.sqlite3.open(dbFile.path)
        ..execute('PRAGMA user_version = 65;');
      rawDb.close();
      db = AppDatabase(NativeDatabase(dbFile));
      expect(await _tableColumns(db, 'drafts'), contains('attachments_json'));
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), 75);
      await db.close();
    });

    test('v66→v67 adds the pending flags to email_notes, both false', () async {
      final dbFile = File('test_migration_v66_notes.db');
      if (dbFile.existsSync()) dbFile.deleteSync();
      addTearDown(() {
        if (dbFile.existsSync()) dbFile.deleteSync();
      });

      final fresh = AppDatabase(NativeDatabase(dbFile));
      await seedAccountRow(fresh, 'acc-x'); // creates the schema
      await fresh.close();

      var rawDb = sqlite.sqlite3.open(dbFile.path)
        ..execute('ALTER TABLE email_notes DROP COLUMN pending_upload;')
        ..execute('ALTER TABLE email_notes DROP COLUMN pending_delete;')
        ..execute(
          'INSERT INTO email_notes (id, account_id, message_id, note_text, '
          "server_id, created_at) VALUES ('n1', 'acc-x', '<m@x>', 'hi', "
          "'7', 0);",
        )
        ..execute('PRAGMA user_version = 66;');
      rawDb.close();

      var db = AppDatabase(NativeDatabase(dbFile));
      final row = await db
          .customSelect(
            'SELECT note_text, pending_upload, pending_delete '
            "FROM email_notes WHERE id = 'n1'",
          )
          .getSingle();
      expect(row.read<String>('note_text'), 'hi');
      expect(row.read<bool>('pending_upload'), isFalse);
      expect(row.read<bool>('pending_delete'), isFalse);
      await db.close();

      // An interrupted earlier upgrade can leave the columns at v66 already.
      rawDb = sqlite.sqlite3.open(dbFile.path)
        ..execute('PRAGMA user_version = 66;');
      rawDb.close();
      db = AppDatabase(NativeDatabase(dbFile));
      expect(
        await _tableColumns(db, 'email_notes'),
        containsAll(['pending_upload', 'pending_delete']),
      );
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), 75);
      await db.close();
    });

    test('v67→v68 adds pending_changes.state, pending for queued rows',
        () async {
      final dbFile = File('test_migration_v67_change_state.db');
      if (dbFile.existsSync()) dbFile.deleteSync();
      addTearDown(() {
        if (dbFile.existsSync()) dbFile.deleteSync();
      });

      final fresh = AppDatabase(NativeDatabase(dbFile));
      await seedAccountRow(fresh, 'acc-x'); // creates the schema
      await fresh.close();

      var rawDb = sqlite.sqlite3.open(dbFile.path)
        ..execute('DROP INDEX pending_changes_resource_state;') // v72
        ..execute('ALTER TABLE pending_changes DROP COLUMN state;')
        ..execute(
          'INSERT INTO pending_changes (id, account_id, resource_type, '
          'resource_id, change_type, payload, created_at, attempts, '
          "last_error) VALUES (1, 'acc-x', 'email', 'acc-x:INBOX:1', "
          "'move', '{}', 0, 2, 'NO');",
        )
        ..execute('PRAGMA user_version = 67;');
      rawDb.close();

      var db = AppDatabase(NativeDatabase(dbFile));
      final row = await db
          .customSelect(
            'SELECT change_type, attempts, last_error, state '
            'FROM pending_changes WHERE id = 1',
          )
          .getSingle();
      expect(row.read<String>('change_type'), 'move');
      expect(row.read<int>('attempts'), 2);
      expect(row.read<String>('last_error'), 'NO');
      expect(row.read<String>('state'), 'pending');
      await db.close();

      // An interrupted earlier upgrade can leave the column at v67 already.
      rawDb = sqlite.sqlite3.open(dbFile.path)
        ..execute('PRAGMA user_version = 67;');
      rawDb.close();
      db = AppDatabase(NativeDatabase(dbFile));
      expect(await _tableColumns(db, 'pending_changes'), contains('state'));
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), 75);
      await db.close();
    });

    test('v68→v69 adds the claim columns, empty for queued rows', () async {
      final dbFile = File('test_migration_v68_change_lease.db');
      if (dbFile.existsSync()) dbFile.deleteSync();
      addTearDown(() {
        if (dbFile.existsSync()) dbFile.deleteSync();
      });

      final fresh = AppDatabase(NativeDatabase(dbFile));
      await seedAccountRow(fresh, 'acc-x'); // creates the schema
      await fresh.close();

      var rawDb = sqlite.sqlite3.open(dbFile.path)
        ..execute('ALTER TABLE pending_changes DROP COLUMN lease_until;')
        ..execute('ALTER TABLE pending_changes DROP COLUMN claim_token;')
        ..execute(
          'INSERT INTO pending_changes (id, account_id, resource_type, '
          'resource_id, change_type, payload, created_at, attempts, '
          "last_error, state) VALUES (1, 'acc-x', 'email', 'acc-x:INBOX:1', "
          "'move', '{}', 0, 2, 'NO', 'failed');",
        )
        ..execute('PRAGMA user_version = 68;');
      rawDb.close();

      var db = AppDatabase(NativeDatabase(dbFile));
      final row = await db
          .customSelect(
            'SELECT attempts, state, lease_until, claim_token '
            'FROM pending_changes WHERE id = 1',
          )
          .getSingle();
      expect(row.read<int>('attempts'), 2);
      expect(row.read<String>('state'), 'failed');
      expect(row.read<int?>('lease_until'), isNull);
      expect(row.read<String?>('claim_token'), isNull);
      await db.close();

      // An interrupted earlier upgrade can leave the column at v68 already.
      rawDb = sqlite.sqlite3.open(dbFile.path)
        ..execute('PRAGMA user_version = 68;');
      rawDb.close();
      db = AppDatabase(NativeDatabase(dbFile));
      expect(
        await _tableColumns(db, 'pending_changes'),
        containsAll(['lease_until', 'claim_token']),
      );
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), 75);
      await db.close();
    });

    test('v69→v70 fills the server location of every row', () async {
      final dbFile = File('test_migration_v69_srv_location.db');
      if (dbFile.existsSync()) dbFile.deleteSync();
      addTearDown(() {
        if (dbFile.existsSync()) dbFile.deleteSync();
      });

      final fresh = AppDatabase(NativeDatabase(dbFile));
      await seedAccountRow(fresh, 'acc-i'); // creates the schema
      await seedAccountRow(fresh, 'acc-j', accountType: 'jmap');
      await fresh.close();

      final rawDb = sqlite.sqlite3.open(dbFile.path)
        ..execute('DROP INDEX emails_srv_imap_location;')
        ..execute('DROP INDEX emails_srv_mailbox;')
        ..execute('DROP TRIGGER emails_srv_mailbox_path_default;')
        ..execute('DROP INDEX emails_srv_jmap_id;')
        ..execute('ALTER TABLE emails DROP COLUMN srv_mailbox_path;')
        ..execute('ALTER TABLE emails DROP COLUMN srv_uid;')
        ..execute('ALTER TABLE emails DROP COLUMN srv_uid_validity;')
        ..execute('ALTER TABLE emails DROP COLUMN srv_jmap_id;');
      void email(
        String id,
        String account,
        String mailbox,
        int uid, {
        bool local = false,
      }) =>
          rawDb.execute(
            'INSERT INTO emails (id, account_id, mailbox_path, uid, '
            'received_at, is_local) VALUES (?, ?, ?, ?, 0, ?)',
            [id, account, mailbox, uid, local ? 1 : 0],
          );
      var changeId = 0;
      void change(String resourceId, String type, String state) =>
          rawDb.execute(
            'INSERT INTO pending_changes (id, account_id, resource_type, '
            'resource_id, change_type, payload, created_at, attempts, state) '
            "VALUES (?, 'acc-i', 'Email', ?, ?, '{}', 0, 0, ?)",
            [++changeId, resourceId, type, state],
          );
      void checkpoint(String path, String state) => rawDb.execute(
            'INSERT INTO sync_states (account_id, resource_type, state, '
            "synced_at) VALUES ('acc-i', ?, ?, 0)",
            ['IMAP:$path', state],
          );
      checkpoint('INBOX', '{"uidValidity":777,"lastUid":9}');
      checkpoint('New', '{"uidValidity":888,"lastUid":9}');
      checkpoint('Archive', '{"uidValidity":0,"lastUid":9}');
      checkpoint('FlagReconcile:INBOX', '2026-01-01T00:00:00.000');
      // Plain row.
      email('acc-i:INBOX:5', 'acc-i', 'INBOX', 5);
      // A queued move already shows it in Archive; the server still has it
      // where the id says.
      email('acc-i:INBOX:6', 'acc-i', 'Archive', 6);
      change('acc-i:INBOX:6', 'move', 'pending');
      // Same for a stuck snooze.
      email('acc-i:INBOX:11', 'acc-i', 'Snoozed', 11);
      change('acc-i:INBOX:11', 'snooze', 'stuck');
      // A failed move protects nothing: the shown folder is used.
      email('acc-i:INBOX:12', 'acc-i', 'Archive', 12);
      change('acc-i:INBOX:12', 'move', 'failed');
      // A queued flag change is no location change.
      email('acc-i:Old:13', 'acc-i', 'New', 13);
      change('acc-i:Old:13', 'flag_seen', 'pending');
      // Folder renamed Old → New: the id still names the old path.
      email('acc-i:Old:7', 'acc-i', 'New', 7);
      // A queued move, but the id is not `account:path:uid`.
      email('acc-i:odd', 'acc-i', 'Archive', 8);
      change('acc-i:odd', 'move', 'pending');
      // Two rows for one location: the one whose id names it keeps it.
      email('acc-i:Old:9', 'acc-i', 'New', 9);
      email('acc-i:New:9', 'acc-i', 'New', 9);
      // Two rows for one location without a UIDVALIDITY: both keep it.
      email('acc-i:Archive:10', 'acc-i', 'Archive', 10);
      email('acc-i:Old2:10', 'acc-i', 'Archive', 10);
      // JMAP and local rows.
      email('acc-j:Mabc', 'acc-j', 'mb-inbox', 0);
      email('acc-i:__local__:<m@x>', 'acc-i', 'INBOX', 0, local: true);
      rawDb
        ..execute('PRAGMA user_version = 69;')
        ..close();

      final db = AppDatabase(NativeDatabase(dbFile));
      final rows = {
        for (final r in await db
            .customSelect(
              'SELECT id, srv_mailbox_path, srv_uid, srv_uid_validity, '
              'srv_jmap_id FROM emails',
            )
            .get())
          r.read<String>('id'): (
            r.read<String?>('srv_mailbox_path'),
            r.read<int?>('srv_uid'),
            r.read<int?>('srv_uid_validity'),
            r.read<String?>('srv_jmap_id'),
          ),
      };
      expect(rows['acc-i:INBOX:5'], ('INBOX', 5, 777, null));
      expect(rows['acc-i:INBOX:6'], ('INBOX', 6, 777, null));
      expect(rows['acc-i:INBOX:11'], ('INBOX', 11, 777, null));
      expect(rows['acc-i:INBOX:12'], ('Archive', 12, null, null));
      expect(rows['acc-i:Old:13'], ('New', 13, 888, null));
      expect(rows['acc-i:Old:7'], ('New', 7, 888, null));
      expect(rows['acc-i:odd'], ('Archive', 8, null, null));
      expect(rows['acc-i:New:9'], ('New', 9, 888, null));
      // v73 records the shown folder as the server's where none was known.
      expect(rows['acc-i:Old:9'], ('New', null, null, null));
      expect(rows['acc-i:Archive:10'], ('Archive', 10, null, null));
      expect(rows['acc-i:Old2:10'], ('Archive', 10, null, null));
      expect(rows['acc-j:Mabc'], ('mb-inbox', null, null, 'Mabc'));
      expect(rows['acc-i:__local__:<m@x>'], ('INBOX', null, null, null));

      final indexes = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'index' "
            "AND tbl_name = 'emails'",
          )
          .get();
      expect(
        indexes.map((r) => r.read<String>('name')),
        containsAll(['emails_srv_imap_location', 'emails_srv_jmap_id']),
      );
      // The index holds: a second row for a location cannot be written.
      await expectLater(
        db.customStatement(
          "UPDATE emails SET srv_mailbox_path = 'INBOX', srv_uid = 5, "
          "srv_uid_validity = 777 WHERE id = 'acc-i:INBOX:6'",
        ),
        throwsA(anything),
      );
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), 75);
      await db.close();
    });

    test(
        'v70→v71 stores what the ids said: Sent copies, JMAP ids, '
        'old Undo snapshots', () async {
      final dbFile = File('test_migration_v70_opaque_ids.db');
      if (dbFile.existsSync()) dbFile.deleteSync();
      addTearDown(() {
        if (dbFile.existsSync()) dbFile.deleteSync();
      });

      final fresh = AppDatabase(NativeDatabase(dbFile));
      await seedAccountRow(fresh, 'acc-i'); // creates the schema
      await seedAccountRow(fresh, 'acc-j', accountType: 'jmap');
      await fresh.close();

      final rawDb = sqlite.sqlite3.open(dbFile.path)
        ..execute('ALTER TABLE emails DROP COLUMN is_virtual_sent_copy;');
      void email(String id, String account, {bool local = false}) =>
          rawDb.execute(
            'INSERT INTO emails (id, account_id, mailbox_path, uid, '
            'received_at, is_local, srv_jmap_id) VALUES (?, ?, ?, 0, 0, ?, ?)',
            [
              id,
              account,
              'INBOX',
              local ? 1 : 0,
              account == 'acc-j' && !local ? 'Mrow' : null,
            ],
          );
      email('acc-i:__local_sent__:<m@x>', 'acc-i', local: true);
      email('acc-i:__local__:<m@x>', 'acc-i', local: true);
      email('acc-j:Mrow', 'acc-j');
      var changeId = 0;
      void change(
        String account,
        String resourceId,
        String payload, {
        String type = 'flag_seen',
      }) =>
          rawDb.execute(
            'INSERT INTO pending_changes (id, account_id, resource_type, '
            'resource_id, change_type, payload, created_at, attempts, state) '
            "VALUES (?, ?, 'Email', ?, ?, ?, 0, 0, 'pending')",
            [++changeId, account, resourceId, type, payload],
          );
      // The row records the server id; a gone row's id names it.
      change('acc-j', 'acc-j:Mrow', '{"seen":true}');
      change('acc-j', 'acc-j:Mgone', '{"seen":true}');
      change('acc-j', 'acc-j:Mrow', '{"seen":true,"jmapId":"Mkept"}');
      change('acc-i', 'acc-i:INBOX:5', '{"uid":5,"mailboxPath":"INBOX"}');
      // A queued move: the id, not the shown folder, names the server's.
      change(
        'acc-i',
        'acc-i:My:Folder:6',
        '{"uid":6,"mailboxPath":"My:Folder","dest":"Archive"}',
        type: 'move',
      );
      for (final (path, validity) in [('Archive', 55), ('My:Folder', 66)]) {
        rawDb.execute(
          'INSERT INTO sync_states (account_id, resource_type, state, '
          "synced_at) VALUES ('acc-i', ?, ?, 0)",
          ['IMAP:$path', '{"uidValidity":$validity,"lastUid":9}'],
        );
      }
      // The background check recorded these by an id built from INBOX/9.
      for (final (account, id) in [
        ('acc-i', 'acc-i:INBOX:9'),
        ('acc-i', 'acc-i:~z'),
        ('acc-j', 'acc-j:Mx'),
      ]) {
        rawDb.execute(
          'INSERT INTO notified_emails (account_id, email_id, notified_at) '
          'VALUES (?, ?, 0)',
          [account, id],
        );
      }
      Map<String, Object?> snapshot(
        String id,
        String account,
        int uid, {
        bool local = false,
        String? srvJmapId,
      }) =>
          {
            'id': id,
            'accountId': account,
            'mailboxPath': 'Archive',
            'uid': uid,
            'isLocal': local,
            if (srvJmapId != null) 'srvJmapId': srvJmapId,
          };
      rawDb.execute(
        'INSERT INTO undo_actions (id, account_id, data_json, created_at) '
        "VALUES ('u1', 'acc-i', ?, 0)",
        [
          jsonEncode({
            'originalEmails': [
              snapshot('acc-i:INBOX:5', 'acc-i', 5),
              snapshot('acc-i:My:Folder:6', 'acc-i', 6),
              snapshot('acc-i:odd', 'acc-i', 7),
              snapshot('acc-j:Msnap', 'acc-j', 0),
              snapshot('acc-j:Mold', 'acc-j', 0, srvJmapId: 'Mnew'),
              snapshot('acc-i:__local_sent__:<m@x>', 'acc-i', 0, local: true),
              snapshot('acc-i:__local__:<m@x>', 'acc-i', 0, local: true),
            ],
          }),
        ],
      );
      rawDb
        ..execute('PRAGMA user_version = 70;')
        ..close();

      final db = AppDatabase(NativeDatabase(dbFile));
      final sentCopy = {
        for (final r in await db
            .customSelect('SELECT id, is_virtual_sent_copy FROM emails')
            .get())
          r.read<String>('id'): r.read<bool>('is_virtual_sent_copy'),
      };
      expect(sentCopy, {
        'acc-i:__local_sent__:<m@x>': true,
        'acc-i:__local__:<m@x>': false,
        'acc-j:Mrow': false,
      });

      final payloads = [
        for (final r in await (db.select(db.pendingChanges)
              ..orderBy([(t) => OrderingTerm.asc(t.id)]))
            .get())
          jsonDecode(r.payload),
      ];
      expect(payloads, [
        {'seen': true, 'jmapId': 'Mrow'},
        {'seen': true, 'jmapId': 'Mgone'},
        {'seen': true, 'jmapId': 'Mkept'},
        {'uid': 5, 'mailboxPath': 'INBOX'},
        {'uid': 6, 'mailboxPath': 'My:Folder', 'dest': 'Archive'},
      ]);

      final notified = await (db.select(db.notifiedEmails)
            ..orderBy([(t) => OrderingTerm.asc(t.emailId)]))
          .get();
      expect(
        [for (final n in notified) (n.accountId, n.emailId)],
        [
          ('acc-i', 'acc-i:INBOX:9'),
          ('acc-i', 'acc-i:~z'),
          ('acc-i', notifiedImapLocationKey('INBOX', 9)),
          ('acc-j', 'acc-j:Mx'),
        ]..sort((a, b) => a.$2.compareTo(b.$2)),
      );

      final undo = await db.select(db.undoActions).getSingle();
      final emails = (jsonDecode(undo.dataJson)
          as Map<String, dynamic>)['originalEmails'] as List<dynamic>;
      Object? field(int i, String key) =>
          (emails[i] as Map<String, dynamic>)[key];
      Object? location(int i) => [
            field(i, 'srvMailboxPath'),
            field(i, 'srvUid'),
            field(i, 'srvUidValidity'),
          ];
      // No move queued: the shown folder (the id may name a renamed one).
      expect(location(0), ['Archive', 5, 55]);
      expect(location(1), ['My:Folder', 6, 66]);
      expect(location(2), ['Archive', 7, 55]);
      expect(field(3, 'srvJmapId'), 'Msnap');
      expect(field(4, 'srvJmapId'), 'Mnew');
      expect(field(5, 'isVirtualSentCopy'), isTrue);
      expect(field(6, 'isVirtualSentCopy'), isNull);
      // Undo still reads the completed snapshots.
      final action = UndoAction.fromJson({
        'id': 'u1',
        'accountId': 'acc-i',
        'type': 'delete',
        'emailIds': const <String>[],
        'sourceMailboxPath': 'INBOX',
        'timestamp': DateTime(2026).toIso8601String(),
        'originalEmails': [
          for (final e in emails)
            {
              ...(e as Map<String, dynamic>),
              'receivedAt': DateTime(2026).toIso8601String(),
              'from': const <Object>[],
              'to': const <Object>[],
              'cc': const <Object>[],
              'isSeen': false,
              'isFlagged': false,
              'hasAttachment': false,
            },
        ],
      });
      expect(action.originalEmails[5].isVirtualSentCopy, isTrue);
      expect(action.originalEmails[0].srvUid, 5);
      expect(action.originalEmails[0].srvUidValidity, 55);

      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), 75);
      await db.close();
    });

    test(
        'v71→v72 copies the read/star/snooze state into srv_ and folds the '
        'queued changes', () async {
      final dbFile = File('test_migration_v71_keywords.db');
      if (dbFile.existsSync()) dbFile.deleteSync();
      addTearDown(() {
        if (dbFile.existsSync()) dbFile.deleteSync();
      });

      final fresh = AppDatabase(NativeDatabase(dbFile));
      await seedAccountRow(fresh, 'acc-i'); // creates the schema
      await seedAccountRow(fresh, 'acc-j', accountType: 'jmap');
      await fresh.close();

      final rawDb = sqlite.sqlite3.open(dbFile.path);
      for (final column in [
        'srv_is_seen',
        'srv_is_flagged',
        'srv_snoozed_until',
        'local_is_seen',
        'local_is_flagged',
        'local_snoozed_until',
        'srv_keywords_seq',
      ]) {
        rawDb.execute('ALTER TABLE emails DROP COLUMN $column;');
      }
      rawDb
        ..execute('DROP INDEX pending_changes_resource_state;')
        ..execute('ALTER TABLE pending_changes DROP COLUMN ack_seq;')
        ..execute('ALTER TABLE pending_changes DROP COLUMN contradicted_seq;')
        ..execute('DROP TABLE sync_read_seq;');
      void email(
        String id,
        String account, {
        required bool seen,
        bool flagged = false,
        int? snoozedUntil,
        String path = 'INBOX',
      }) =>
          rawDb.execute(
            'INSERT INTO emails (id, account_id, mailbox_path, uid, '
            'received_at, is_seen, is_flagged, snoozed_until, '
            'srv_mailbox_path, srv_uid) '
            'VALUES (?, ?, ?, 1, 0, ?, ?, ?, ?, ?)',
            [
              id,
              account,
              path,
              if (seen) 1 else 0,
              if (flagged) 1 else 0,
              snoozedUntil,
              if (account == 'acc-i') path else null,
              if (account == 'acc-i') int.parse(id.split('-').last) else null,
            ],
          );
      void change(
        int id,
        String email,
        String type,
        String payload, {
        String state = 'pending',
        String account = 'acc-i',
      }) =>
          rawDb.execute(
            'INSERT INTO pending_changes (id, account_id, resource_type, '
            'resource_id, change_type, payload, created_at, attempts, state) '
            "VALUES (?, ?, 'Email', ?, ?, ?, 0, 0, ?)",
            [id, account, email, type, payload, state],
          );
      // Untouched: srv_ is today's value.
      email('e-1', 'acc-i', seen: true, flagged: true);
      // Read locally, the change still queued: the shown value stays.
      email('e-2', 'acc-i', seen: true);
      change(1, 'e-2', 'flag_seen', '{"seen":true,"mailboxPath":"INBOX"}');
      // Two changes of the star, the later one wins; a failed one does not
      // fold.
      email('e-3', 'acc-i', seen: false, path: 'Archive');
      change(2, 'e-3', 'flag_flagged', '{"flagged":true}');
      change(3, 'e-3', 'flag_flagged', '{"flagged":false}', state: 'stuck');
      change(4, 'e-3', 'flag_seen', '{"seen":true}', state: 'failed');
      // Snoozed (JMAP), the snooze still queued.
      email('e-4', 'acc-j', seen: false, snoozedUntil: 1800000000);
      change(
        5,
        'e-4',
        'snooze',
        '{"until":"2027-01-15T08:00:00.000Z","src":"inbox-id"}',
        account: 'acc-j',
      );
      // A move without a snooze change is no keyword change.
      email('e-5', 'acc-i', seen: false, path: 'Trash');
      change(6, 'e-5', 'move', '{"mailboxPath":"INBOX","dest":"Trash"}');
      rawDb
        ..execute('PRAGMA user_version = 71;')
        ..close();

      final db = AppDatabase(NativeDatabase(dbFile));
      Future<Map<String, Object?>> row(String id) async =>
          (await db.customSelect(
            'SELECT is_seen, is_flagged, snoozed_until, srv_is_seen, '
            'srv_is_flagged, srv_snoozed_until, local_is_seen, '
            'local_is_flagged, local_snoozed_until, srv_keywords_seq '
            'FROM emails WHERE id = ?',
            variables: [Variable.withString(id)],
          ).getSingle())
              .data;

      expect(await row('e-1'), {
        'is_seen': 1,
        'is_flagged': 1,
        'snoozed_until': null,
        'srv_is_seen': 1,
        'srv_is_flagged': 1,
        'srv_snoozed_until': null,
        'local_is_seen': null,
        'local_is_flagged': null,
        'local_snoozed_until': null,
        'srv_keywords_seq': 0,
      });
      final e2 = await row('e-2');
      expect(e2['is_seen'], 1);
      expect(e2['local_is_seen'], 1);
      final e3 = await row('e-3');
      expect(e3['is_flagged'], 0, reason: 'the stuck change is the later');
      expect(e3['local_is_flagged'], 0);
      expect(e3['local_is_seen'], isNull, reason: 'a failed change');
      expect(e3['is_seen'], 0);
      final e4 = await row('e-4');
      final until = DateTime.utc(2027, 1, 15, 8).millisecondsSinceEpoch ~/ 1000;
      expect(e4['local_snoozed_until'], until);
      expect(e4['snoozed_until'], until);
      expect(e4['srv_snoozed_until'], 1800000000);
      final e5 = await row('e-5');
      expect(e5['local_is_seen'], isNull);
      expect(e5['local_snoozed_until'], isNull);

      // The rows with a queued keyword change get their server value read
      // again.
      final due = await db
          .customSelect(
            'SELECT account_id, resource_type FROM sync_states '
            "WHERE resource_type LIKE '%Due:%' ORDER BY resource_type",
          )
          .get();
      expect(
        [
          for (final r in due)
            '${r.read<String>('account_id')} '
                '${r.read<String>('resource_type')}',
        ],
        [
          'acc-i IMAP:FlagReconcileDue:Archive',
          'acc-i IMAP:FlagReconcileDue:INBOX',
          'acc-j JMAP:ReconcileDue:INBOX',
        ],
      );
      expect(
        await _tableColumns(db, 'pending_changes'),
        containsAll(['ack_seq', 'contradicted_seq']),
      );
      expect(await _tableColumns(db, 'sync_read_seq'), contains('seq'));
      final index = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'index' "
            "AND name = 'pending_changes_resource_state'",
          )
          .get();
      expect(index, hasLength(1));
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), 75);
      await db.close();
    });

    test(
        'v72→v73 overlays the location: srv_mailbox_path everywhere, the '
        'queued moves folded', () async {
      final dbFile = File('test_migration_v72_location.db');
      if (dbFile.existsSync()) dbFile.deleteSync();
      addTearDown(() {
        if (dbFile.existsSync()) dbFile.deleteSync();
      });

      final fresh = AppDatabase(NativeDatabase(dbFile));
      await seedAccountRow(fresh, 'acc-i'); // creates the schema
      await seedAccountRow(fresh, 'acc-j', accountType: 'jmap');
      await fresh.close();

      final rawDb = sqlite.sqlite3.open(dbFile.path);
      rawDb
        ..execute('DROP TRIGGER emails_srv_mailbox_path_default;')
        ..execute('DROP INDEX emails_srv_mailbox;')
        ..execute('DROP INDEX emails_srv_gone;');
      for (final column in [
        'local_mailbox_path',
        'local_hidden',
        'srv_gone',
        'srv_location_seq',
      ]) {
        rawDb.execute('ALTER TABLE emails DROP COLUMN $column;');
      }
      void email(
        String id,
        String account,
        String path, {
        String? srvPath,
      }) =>
          rawDb.execute(
            'INSERT INTO emails (id, account_id, mailbox_path, uid, '
            'received_at, srv_mailbox_path, srv_uid) '
            'VALUES (?, ?, ?, 1, 0, ?, ?)',
            [
              id,
              account,
              path,
              srvPath,
              if (account == 'acc-i' && srvPath != null)
                int.parse(id.split('-').last)
              else
                null,
            ],
          );
      void change(
        int id,
        String email,
        String type,
        String payload, {
        String state = 'pending',
        String account = 'acc-i',
      }) =>
          rawDb.execute(
            'INSERT INTO pending_changes (id, account_id, resource_type, '
            'resource_id, change_type, payload, created_at, attempts, state) '
            "VALUES (?, ?, 'Email', ?, ?, ?, 0, 0, ?)",
            [id, account, email, type, payload, state],
          );
      // IMAP, untouched.
      email('e-1', 'acc-i', 'INBOX', srvPath: 'INBOX');
      // IMAP, moved to Archive, the move still queued.
      email('e-2', 'acc-i', 'Archive', srvPath: 'INBOX');
      change(1, 'e-2', 'move', '{"mailboxPath":"INBOX","dest":"Archive"}');
      // JMAP (no server folder recorded), moved, the move still queued.
      email('e-3', 'acc-j', 'trash-id');
      change(
        2,
        'e-3',
        'move',
        '{"src":"inbox-id","dest":"trash-id"}',
        account: 'acc-j',
      );
      // JMAP, untouched.
      email('e-4', 'acc-j', 'inbox-id');
      // A failed move does not fold: the mail shows the server's folder.
      email('e-5', 'acc-i', 'Archive', srvPath: 'INBOX');
      change(
        3,
        'e-5',
        'move',
        '{"mailboxPath":"INBOX","dest":"Archive"}',
        state: 'failed',
      );
      // An acked snooze whose destination is not where the server has it
      // keeps folding, as at runtime, until a read settles it; its old
      // (keyword) contradiction is forgotten.
      email('e-6', 'acc-j', 'inbox-id');
      change(
        4,
        'e-6',
        'snooze',
        '{"src":"inbox-id","dest":"snoozed-id",'
            '"until":"2027-01-15T08:00:00.000Z"}',
        state: 'acked',
        account: 'acc-j',
      );
      rawDb
        ..execute(
          'UPDATE pending_changes SET contradicted_seq = 5 WHERE id = 4',
        )
        ..execute('PRAGMA user_version = 72;')
        ..close();

      final db = AppDatabase(NativeDatabase(dbFile));
      Future<Map<String, Object?>> row(String id) async =>
          (await db.customSelect(
            'SELECT mailbox_path, srv_mailbox_path, local_mailbox_path, '
            'local_hidden, srv_gone, srv_location_seq '
            'FROM emails WHERE id = ?',
            variables: [Variable.withString(id)],
          ).getSingle())
              .data;

      expect(await row('e-1'), {
        'mailbox_path': 'INBOX',
        'srv_mailbox_path': 'INBOX',
        'local_mailbox_path': null,
        'local_hidden': 0,
        'srv_gone': 0,
        'srv_location_seq': 0,
      });
      expect(await row('e-2'), containsPair('local_mailbox_path', 'Archive'));
      expect(await row('e-2'), containsPair('mailbox_path', 'Archive'));
      expect(await row('e-2'), containsPair('srv_mailbox_path', 'INBOX'));
      expect(await row('e-3'), containsPair('srv_mailbox_path', 'inbox-id'));
      expect(await row('e-3'), containsPair('local_mailbox_path', 'trash-id'));
      expect(await row('e-3'), containsPair('mailbox_path', 'trash-id'));
      expect(await row('e-4'), containsPair('srv_mailbox_path', 'inbox-id'));
      expect(await row('e-5'), containsPair('mailbox_path', 'INBOX'));
      expect(await row('e-5'), containsPair('local_mailbox_path', null));
      expect(await row('e-6'), containsPair('mailbox_path', 'snoozed-id'));
      final ops = await db.select(db.pendingChanges).get();
      expect(ops.map((o) => o.id), [1, 2, 3, 4]);
      expect(ops.last.contradictedSeq, isNull);
      // e-3 (JMAP, its server folder newly recorded) shows where its move
      // puts it, as before; e-5's failed move no longer shows; e-6 shows
      // its acked snooze: noted in the App Log.
      final logs = await db
          .customSelect(
            'SELECT account_id, data_json FROM app_logs '
            "WHERE event = 'migration.location_overlay' ORDER BY account_id",
          )
          .get();
      expect(logs.map((l) => l.read<String>('account_id')), ['acc-i', 'acc-j']);
      expect(logs.first.read<String>('data_json'), contains('"emailId":"e-5"'));

      // A row inserted without a server folder gets the one it shows.
      await db.customStatement(
        'INSERT INTO emails (id, account_id, mailbox_path, uid, received_at) '
        "VALUES ('e-7', 'acc-j', 'inbox-id', 0, 0)",
      );
      expect(await row('e-7'), containsPair('srv_mailbox_path', 'inbox-id'));
      final index = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'index' "
            "AND name IN ('emails_srv_mailbox', 'emails_srv_gone')",
          )
          .get();
      expect(index, hasLength(2));
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), 75);
      await db.close();
    });

    test(
        'v74→v75 overlays the mailbox names and queues the Snoozed folder a '
        'JMAP snooze waits for', () async {
      final dbFile = File('test_migration_v74_mailboxes.db');
      if (dbFile.existsSync()) dbFile.deleteSync();
      addTearDown(() {
        if (dbFile.existsSync()) dbFile.deleteSync();
      });

      final fresh = AppDatabase(NativeDatabase(dbFile));
      await seedAccountRow(fresh, 'acc-i'); // creates the schema
      await seedAccountRow(fresh, 'acc-j', accountType: 'jmap');
      await seedAccountRow(fresh, 'acc-k', accountType: 'jmap');
      await fresh.close();

      final rawDb = sqlite.sqlite3.open(dbFile.path);
      for (final column in ['srv_name', 'local_name', 'is_local', 'srv_seq']) {
        rawDb.execute('ALTER TABLE mailboxes DROP COLUMN $column;');
      }
      void mailbox(String account, String path, String name) => rawDb.execute(
            'INSERT INTO mailboxes (id, account_id, path, name) '
            'VALUES (?, ?, ?, ?)',
            ['$account:$path', account, path, name],
          );
      void snooze(String account, String dest) => rawDb.execute(
            'INSERT INTO pending_changes (account_id, resource_type, '
            'resource_id, change_type, payload, created_at, state) '
            "VALUES (?, 'Email', ?, 'snooze', ?, 0, 'pending')",
            [
              account,
              '$account:~e1',
              '{"uid":0,"src":"inbox","dest":"$dest",'
                  '"until":"2030-01-01T00:00:00.000"}',
            ],
          );
      mailbox('acc-i', 'INBOX', 'INBOX');
      mailbox('acc-j', 'inbox', 'Inbox');
      mailbox('acc-k', 'inbox', 'Inbox');
      // Queued before the Snoozed folder was known: the stand-in.
      snooze('acc-j', 'Snoozed');
      // IMAP: `Snoozed` is the folder's path, created by the snooze's flush.
      snooze('acc-i', 'Snoozed');
      // The folder known: nothing to convert.
      snooze('acc-k', 'mbx-snoozed');
      rawDb.execute('PRAGMA user_version = 74;');
      rawDb.close();

      final db = AppDatabase(NativeDatabase(dbFile));
      final mailboxes = await db.select(db.mailboxes).get();
      for (final m in mailboxes.where((m) => !m.isLocal)) {
        expect(m.srvName, m.name);
      }
      final snoozed = mailboxes.singleWhere((m) => m.isLocal);
      expect(
        (snoozed.accountId, snoozed.path, snoozed.name, snoozed.role),
        ('acc-j', 'Snoozed', 'Snoozed', 'snoozed'),
      );
      final creates = await (db.select(db.pendingChanges)
            ..where((t) => t.resourceType.equals('Mailbox')))
          .get();
      expect(
        creates.map((c) => (c.accountId, c.resourceId, c.changeType, c.state)),
        [('acc-j', snoozed.id, 'create_mailbox', 'pending')],
      );
      expect(jsonDecode(creates.single.payload), {
        'name': 'Snoozed',
        'role': 'snoozed',
      });
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), 75);
      await db.close();
    });

    test('a fresh database has the server-location indexes', () async {
      final db = AppDatabase(NativeDatabase.memory());
      final indexes = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'index' "
            "AND tbl_name = 'emails'",
          )
          .get();
      expect(
        indexes.map((r) => r.read<String>('name')),
        containsAll(['emails_srv_imap_location', 'emails_srv_jmap_id']),
      );
      await db.close();
    });

    test(
        'v62→v63 adds threads.latest_uid from the latest email and the list '
        'order indexes', () async {
      final dbFile = File('test_migration_v62_list_order.db');
      if (dbFile.existsSync()) dbFile.deleteSync();
      addTearDown(() {
        if (dbFile.existsSync()) dbFile.deleteSync();
      });

      final fresh = AppDatabase(NativeDatabase(dbFile));
      await seedAccountRow(fresh, 'acc-x');
      await fresh.close();

      // A v62 database: threads without latest_uid, the old list indexes.
      final rawDb = sqlite.sqlite3.open(dbFile.path);
      rawDb.execute('DROP INDEX emails_list_order;');
      rawDb.execute('DROP INDEX threads_list_order;');
      rawDb.execute('ALTER TABLE threads DROP COLUMN latest_uid;');
      rawDb.execute(
        'CREATE INDEX emails_received_at ON emails '
        '(account_id, mailbox_path, received_at DESC);',
      );
      rawDb.execute(
        'CREATE INDEX threads_latest_date ON threads '
        '(account_id, mailbox_path, latest_date DESC);',
      );
      rawDb.execute('''
        INSERT INTO emails (id, account_id, mailbox_path, uid, received_at)
        VALUES ('acc-x:INBOX:7', 'acc-x', 'INBOX', 7, 0);
      ''');
      rawDb.execute('''
        INSERT INTO threads (id, account_id, mailbox_path, latest_date,
                             latest_email_id)
        VALUES ('t1', 'acc-x', 'INBOX', 0, 'acc-x:INBOX:7'),
               ('t2', 'acc-x', 'INBOX', 0, 'gone');
      ''');
      rawDb.execute('PRAGMA user_version = 62;');
      rawDb.close();

      final db = AppDatabase(NativeDatabase(dbFile));
      addTearDown(db.close);
      final rows = await db
          .customSelect('SELECT id, latest_uid FROM threads ORDER BY id')
          .get();
      expect(
        {for (final r in rows) r.read<String>('id'): r.read<int>('latest_uid')},
        {'t1': 7, 't2': 0},
      );
      final indexes = {
        for (final r in await db
            .customSelect("SELECT name FROM sqlite_master WHERE type = 'index'")
            .get())
          r.read<String>('name'),
      };
      expect(indexes, containsAll(['emails_list_order', 'threads_list_order']));
      expect(indexes, isNot(contains('emails_received_at')));
      expect(indexes, isNot(contains('threads_latest_date')));
    });

    test('v62→v63 tolerates latest_uid and the list indexes already present',
        () async {
      // An interrupted earlier upgrade can leave the v63 schema at v62.
      final dbFile = File('test_migration_v62_list_order_rerun.db');
      if (dbFile.existsSync()) dbFile.deleteSync();
      addTearDown(() {
        if (dbFile.existsSync()) dbFile.deleteSync();
      });

      final fresh = AppDatabase(NativeDatabase(dbFile));
      await seedAccountRow(fresh, 'acc-x');
      await fresh.close();

      final rawDb = sqlite.sqlite3.open(dbFile.path);
      rawDb.execute('''
        INSERT INTO emails (id, account_id, mailbox_path, uid, received_at)
        VALUES ('acc-x:INBOX:9', 'acc-x', 'INBOX', 9, 0);
      ''');
      rawDb.execute('''
        INSERT INTO threads (id, account_id, mailbox_path, latest_date,
                             latest_email_id, latest_uid)
        VALUES ('t1', 'acc-x', 'INBOX', 0, 'acc-x:INBOX:9', 0);
      ''');
      rawDb.execute('PRAGMA user_version = 62;');
      rawDb.close();

      final db = AppDatabase(NativeDatabase(dbFile));
      addTearDown(db.close);
      final row = await db
          .customSelect("SELECT latest_uid FROM threads WHERE id = 't1'")
          .getSingle();
      expect(row.read<int>('latest_uid'), 9);
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), 75);
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
        // v60 backfill input: thread t-att has a message with an attachment,
        // t-plain has none.
        rawDb.execute('''
        INSERT INTO emails (id, account_id, mailbox_path, uid, received_at,
                            has_attachment, thread_id)
        VALUES ('e-att', 'acc-x', 'INBOX', 1, 0, 1, 't-att'),
               ('e-plain', 'acc-x', 'INBOX', 2, 0, 0, 't-plain');
      ''');
        rawDb.execute('''
        INSERT INTO threads (account_id, mailbox_path, id, latest_date,
                             latest_email_id)
        VALUES ('acc-x', 'INBOX', 't-att', 0, 'e-att'),
               ('acc-x', 'INBOX', 't-plain', 0, 'e-plain');
      ''');
        rawDb.execute('PRAGMA user_version = 22;');
        rawDb.close();

        final db = AppDatabase(NativeDatabase(dbFile));
        // Trigger migration.
        await db.select(db.accounts).get();

        final emailColumns = await _tableColumns(db, 'emails');
        expect(emailColumns, contains('list_unsubscribe_header'));

        // v60: threads.has_attachment added to the existing table and
        // backfilled from its emails.
        final attachmentByThread = {
          for (final row in await db
              .customSelect('SELECT id, has_attachment FROM threads')
              .get())
            row.read<String>('id'): row.read<bool>('has_attachment'),
        };
        expect(attachmentByThread, {'t-att': true, 't-plain': false});

        final draftColumns = await _tableColumns(db, 'drafts');
        expect(draftColumns, contains('imap_server_id'));

        // v25: new indexes on mailboxes and threads (v63 replaces the
        // threads one with threads_list_order).
        final allIndexes = await db
            .customSelect("SELECT name FROM sqlite_master WHERE type='index'")
            .get();
        final indexNames =
            allIndexes.map((r) => r.read<String>('name')).toSet();
        expect(indexNames, contains('mailboxes_account_id'));
        expect(indexNames, contains('threads_list_order'));

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
        expect(indexNames, contains('app_logs_email_id'));
        // v62: foreign-key child index for bulk sync-log deletes.
        expect(indexNames, contains('sync_log_mailboxes_sync_log_id'));

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
          'bug_reports', // v58
        ]),
      );

      final emailColumns = await _tableColumns(db, 'emails');
      expect(emailColumns, contains('list_unsubscribe_header'));
      expect(emailColumns, contains('size_bytes')); // v64
      expect(await _tableColumns(db, 'threads'), contains('latest_uid'));
      final indexes = (await db
              .customSelect(
                "SELECT name FROM sqlite_master WHERE type = 'index'",
              )
              .get())
          .map((r) => r.read<String>('name'));
      expect(
        indexes,
        containsAll(['emails_list_order', 'threads_list_order']), // v63
      );

      final draftColumns = await _tableColumns(db, 'drafts');
      expect(draftColumns, contains('imap_server_id'));
      expect(draftColumns, contains('jmap_server_id')); // v43
      expect(draftColumns, contains('dirty')); // v43
      expect(draftColumns, contains('bcc_text')); // v65
      expect(draftColumns, contains('attachments_json')); // v66
      expect(
        await _tableColumns(db, 'pending_changes'),
        containsAll(['state', 'lease_until', 'claim_token']), // v68, v69
      );
      expect(
        await _tableColumns(db, 'emails'),
        containsAll([
          'srv_mailbox_path',
          'srv_uid',
          'srv_uid_validity',
          'srv_jmap_id',
        ]), // v70
      );
      expect(
        await _tableColumns(db, 'emails'),
        contains('is_virtual_sent_copy'), // v71
      );

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
