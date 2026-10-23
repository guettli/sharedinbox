import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/repositories/sync_log_repository.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/sync_log_repository_impl.dart';

import 'db_test_helper.dart';

void main() {
  configureSqliteForTests();

  late AppDatabase db;
  late SyncLogRepositoryImpl repo;

  setUp(() async {
    db = await openTestDatabaseWithAccounts(['acc1', 'acc2']);
    repo = SyncLogRepositoryImpl(db);
  });

  tearDown(() => db.close());

  Future<int> logAt(String accountId, DateTime startedAt) => repo.log(
        accountId: accountId,
        success: true,
        protocol: 'imap',
        emailsFetched: 0,
        emailsSkipped: 0,
        mailboxesSynced: 1,
        pendingFlushed: 0,
        bytesTransferred: 0,
        startedAt: startedAt,
        finishedAt: startedAt,
        mailboxStats: const [
          MailboxSyncStats(
            mailboxPath: 'INBOX',
            fetched: 0,
            skipped: 0,
            bytesTransferred: 0,
          ),
        ],
      );

  Future<Set<int>> syncLogIds() async =>
      (await db.select(db.syncLogs).get()).map((r) => r.id).toSet();

  test('drops logs older than maxAge but keeps the newest per account',
      () async {
    final now = DateTime.now();
    final old1 = await logAt('acc1', now.subtract(const Duration(days: 30)));
    final recent1 = await logAt('acc1', now.subtract(const Duration(days: 1)));
    await logAt('acc2', now.subtract(const Duration(days: 40)));
    final old2b = await logAt('acc2', now.subtract(const Duration(days: 20)));
    final logRow = await db.into(db.appLogs).insert(
          AppLogsCompanion.insert(
            level: 'info',
            event: 'sync.cycle',
            message: 'm',
            createdAt: now,
            syncLogId: Value(old1),
          ),
        );

    await repo.trim();

    // acc2 has only old logs: its newest one survives.
    expect(await syncLogIds(), {recent1, old2b});
    final mailboxRows = await db.select(db.syncLogMailboxes).get();
    expect(mailboxRows.map((r) => r.syncLogId).toSet(), {recent1, old2b});
    final appLog = await (db.select(db.appLogs)
          ..where((t) => t.id.equals(logRow)))
        .getSingle();
    expect(appLog.syncLogId, isNull);
  });

  test('keeps only the newest maxPerAccount logs of each account', () async {
    final now = DateTime.now();
    final acc1 = [
      for (var i = 5; i > 0; i--)
        await logAt('acc1', now.subtract(Duration(minutes: i))),
    ];
    final acc2 = await logAt('acc2', now.subtract(const Duration(hours: 1)));

    await repo.trim(maxPerAccount: 2);

    expect(await syncLogIds(), {...acc1.skip(3), acc2});
  });

  test('is a no-op on a closed database', () async {
    await db.close();
    await repo.trim();
    db = openTestDatabase();
  });
}
