import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sharedinbox/data/db/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'db_test_helper.dart';

Future<int> _foreignKeysPragma(AppDatabase db) async =>
    (await db.customSelect('PRAGMA foreign_keys').getSingle())
        .read<int>('foreign_keys');

Future<List<QueryRow>> _violations(AppDatabase db) =>
    db.customSelect('PRAGMA foreign_key_check').get();

Future<List<String>> _ids(AppDatabase db, String sql) async => [
      for (final r in await db.customSelect(sql).get())
        r.data.values.first.toString(),
    ];

Future<void> _insertEmail(AppDatabase db, String id, String accountId) =>
    db.into(db.emails).insert(
          EmailsCompanion.insert(
            id: id,
            accountId: accountId,
            mailboxPath: 'INBOX',
            uid: 1,
            receivedAt: DateTime(2026),
          ),
        );

void main() {
  setUpAll(configureSqliteForTests);

  test('every open switches foreign keys on (#1119)', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    expect(await _foreignKeysPragma(db), 1);
    expect(await _violations(db), isEmpty);
    // Deleting an email nulls its log references: indexed, not a scan.
    expect(
      await _ids(
        db,
        "SELECT name FROM sqlite_master WHERE name = 'app_logs_email_id'",
      ),
      ['app_logs_email_id'],
    );
  });

  test('deleting an email cascades to its body and detaches its logs',
      () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await seedAccountRow(db, 'acc');
    await _insertEmail(db, 'acc:INBOX:1', 'acc');
    await db.into(db.emailBodies).insert(
          EmailBodiesCompanion.insert(emailId: 'acc:INBOX:1'),
        );
    await db.into(db.appLogs).insert(
          AppLogsCompanion.insert(
            createdAt: DateTime(2026),
            level: 'info',
            event: 'e',
            message: 'm',
            accountId: const Value('acc'),
            emailId: const Value('acc:INBOX:1'),
          ),
        );

    await db.customStatement("DELETE FROM emails WHERE id = 'acc:INBOX:1'");

    expect(await _ids(db, 'SELECT email_id FROM email_bodies'), isEmpty);
    expect(
      await _ids(db, 'SELECT email_id IS NULL FROM app_logs'),
      ['1'],
    );
    expect(
      () => db.into(db.emailBodies).insert(
            EmailBodiesCompanion.insert(emailId: 'acc:INBOX:gone'),
          ),
      throwsA(predicate(isForeignKeyViolation)),
    );
  });

  test('the v61→v62 upgrade removes rows that break a foreign key', () async {
    final dir = Directory.systemTemp.createTempSync('fk_cleanup');
    addTearDown(() => dir.deleteSync(recursive: true));
    final dbFile = File(p.join(dir.path, 'v61.db'));

    final fresh = AppDatabase(NativeDatabase(dbFile));
    await seedAccountRow(fresh, 'acc');
    await fresh.close();

    // What older builds could leave behind with foreign keys off: rows of a
    // removed account, bodies of deleted emails, logs naming deleted rows.
    final raw = sqlite.sqlite3.open(dbFile.path);
    raw.execute('''
      INSERT INTO emails (id, account_id, mailbox_path, uid, received_at)
      VALUES ('acc:INBOX:1', 'acc', 'INBOX', 1, 0),
             ('gone:INBOX:1', 'gone', 'INBOX', 1, 0);
      INSERT INTO email_bodies (email_id)
      VALUES ('acc:INBOX:1'), ('acc:INBOX:deleted'), ('gone:INBOX:1');
      INSERT INTO mailboxes (id, account_id, path, name)
      VALUES ('acc:INBOX', 'acc', 'INBOX', 'INBOX'),
             ('gone:INBOX', 'gone', 'INBOX', 'INBOX');
      INSERT INTO sync_logs (id, account_id, result, started_at, finished_at)
      VALUES (1, 'acc', 'ok', 0, 0), (2, 'gone', 'ok', 0, 0);
      INSERT INTO sync_log_mailboxes (sync_log_id, mailbox_path)
      VALUES (1, 'INBOX'), (2, 'INBOX'), (3, 'INBOX');
      INSERT INTO app_logs
        (created_at, level, event, message, account_id, email_id, sync_log_id)
      VALUES (0, 'info', 'kept', 'm', 'acc', 'acc:INBOX:1', 1),
             (0, 'info', 'detached', 'm', 'gone', 'gone:INBOX:1', 2);
      PRAGMA user_version = 61;
    ''');
    raw.close();

    final db = AppDatabase(NativeDatabase(dbFile));
    addTearDown(db.close);

    expect(await _violations(db), isEmpty);
    expect(await _foreignKeysPragma(db), 1);
    expect(await _ids(db, 'SELECT id FROM emails'), ['acc:INBOX:1']);
    expect(
      await _ids(db, 'SELECT email_id FROM email_bodies'),
      ['acc:INBOX:1'],
    );
    expect(await _ids(db, 'SELECT id FROM mailboxes'), ['acc:INBOX']);
    expect(await _ids(db, 'SELECT id FROM sync_logs'), ['1']);
    expect(
      await _ids(db, 'SELECT sync_log_id FROM sync_log_mailboxes'),
      ['1'],
    );
    expect(
      await _ids(
        db,
        "SELECT event || ':' || IFNULL(account_id, '-') || ':' || "
        "IFNULL(email_id, '-') || ':' || IFNULL(sync_log_id, '-') "
        'FROM app_logs ORDER BY id',
      ),
      ['kept:acc:acc:INBOX:1:1', 'detached:-:-:-'],
    );
  });
}
