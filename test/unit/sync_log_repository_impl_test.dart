import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/sync_log_repository_impl.dart';

import 'db_test_helper.dart';

void main() {
  configureSqliteForTests();

  late final db = openTestDatabase();

  setUpAll(() async {
    await db.into(db.accounts).insert(
          AccountsCompanion.insert(
            id: 'acc1',
            displayName: 'Test',
            email: 'test@example.com',
            imapHost: 'imap.example.com',
            imapPort: 993,
            imapSsl: true,
            smtpHost: 'smtp.example.com',
            smtpPort: 587,
            smtpSsl: true,
          ),
        );
  });

  tearDownAll(() => db.close());

  test('logs success entry', () async {
    final repo = SyncLogRepositoryImpl(db);
    final start = DateTime(2024, 1, 1, 10);
    final end = DateTime(2024, 1, 1, 10, 0, 5);

    await repo.log(
      accountId: 'acc1',
      success: true,
      protocol: 'imap',
      emailsFetched: 5,
      emailsSkipped: 0,
      mailboxesSynced: 3,
      pendingFlushed: 0,
      bytesTransferred: 0,
      startedAt: start,
      finishedAt: end,
    );

    final rows = await db.select(db.syncLogs).get();
    expect(rows, hasLength(1));
    expect(rows.first.result, 'ok');
    expect(rows.first.errorMessage, null);
    expect(rows.first.accountId, 'acc1');
    expect(rows.first.protocol, 'imap');
    expect(rows.first.itemsSynced, 5);
    expect(rows.first.mailboxesSynced, 3);
    expect(rows.first.pendingFlushed, 0);
  });

  test('logs error entry with message', () async {
    final repo = SyncLogRepositoryImpl(db);
    final start = DateTime(2024, 1, 1, 11);
    final end = DateTime(2024, 1, 1, 11, 0, 2);

    await repo.log(
      accountId: 'acc1',
      success: false,
      errorMessage: 'Connection refused',
      protocol: 'imap',
      emailsFetched: 0,
      emailsSkipped: 0,
      mailboxesSynced: 0,
      pendingFlushed: 0,
      bytesTransferred: 0,
      startedAt: start,
      finishedAt: end,
    );

    final rows = await (db.select(db.syncLogs)
          ..where((r) => r.result.equals('error')))
        .get();
    expect(rows, hasLength(1));
    expect(rows.first.result, 'error');
    expect(rows.first.errorMessage, 'Connection refused');
  });
}
