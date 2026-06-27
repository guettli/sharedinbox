import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/app_log_repository_impl.dart';

import 'db_test_helper.dart';

void main() {
  configureSqliteForTests();

  late AppDatabase db;
  late AppLogRepositoryImpl repo;

  setUp(() async {
    db = openTestDatabase();
    repo = AppLogRepositoryImpl(db);
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

  tearDown(() => db.close());

  test('insert stores level, event, message, context and dataJson', () async {
    final id = await repo.insert(
      level: AppLogLevel.warn,
      event: 'sync.retry',
      message: 'Retrying after 5s',
      dataJson: '{"attempt":2}',
      accountId: 'acc1',
      mailboxPath: 'INBOX',
      syncLogId: 42,
    );
    expect(id, isNotNull);

    final rows = await db.select(db.appLogs).get();
    expect(rows, hasLength(1));
    final row = rows.first;
    expect(row.level, 'warn');
    expect(row.event, 'sync.retry');
    expect(row.message, 'Retrying after 5s');
    expect(row.dataJson, '{"attempt":2}');
    expect(row.accountId, 'acc1');
    expect(row.mailboxPath, 'INBOX');
    expect(row.syncLogId, 42);
  });

  test('watchEntries hides debug by default and orders newest first', () async {
    await repo.insert(
      level: AppLogLevel.debug,
      event: 'ui.screen.enter',
      message: '/inbox',
      createdAt: DateTime(2024, 1, 1, 10),
    );
    await repo.insert(
      level: AppLogLevel.info,
      event: 'sync.cycle.complete',
      message: 'ok',
      createdAt: DateTime(2024, 1, 1, 11),
    );
    await repo.insert(
      level: AppLogLevel.error,
      event: 'sync.cycle.failed',
      message: 'boom',
      createdAt: DateTime(2024, 1, 1, 12),
    );

    final entries = await repo.watchEntries(const AppLogFilter()).first;
    expect(entries.map((e) => e.event).toList(), [
      'sync.cycle.failed',
      'sync.cycle.complete',
    ]);
  });

  test('watchEntries respects custom level filter (debug included)', () async {
    await repo.insert(level: AppLogLevel.debug, event: 'x', message: 'm');
    await repo.insert(level: AppLogLevel.info, event: 'y', message: 'm');

    final entries = await repo
        .watchEntries(const AppLogFilter(levels: {AppLogLevel.debug}))
        .first;
    expect(entries, hasLength(1));
    expect(entries.first.event, 'x');
  });

  test('watchEntries filters by account', () async {
    await db.into(db.accounts).insert(
          AccountsCompanion.insert(
            id: 'acc2',
            displayName: 'Other',
            email: 'other@example.com',
            imapHost: 'imap.example.com',
            imapPort: 993,
            imapSsl: true,
            smtpHost: 'smtp.example.com',
            smtpPort: 587,
            smtpSsl: true,
          ),
        );
    await repo.insert(
      level: AppLogLevel.info,
      event: 'a',
      message: '',
      accountId: 'acc1',
    );
    await repo.insert(
      level: AppLogLevel.info,
      event: 'b',
      message: '',
      accountId: 'acc2',
    );

    final entries =
        await repo.watchEntries(const AppLogFilter(accountId: 'acc2')).first;
    expect(entries.map((e) => e.event).toList(), ['b']);
  });

  test('watchEntries filters by syncLogId', () async {
    await repo.insert(
      level: AppLogLevel.info,
      event: 'a',
      message: '',
      syncLogId: 1,
    );
    await repo.insert(
      level: AppLogLevel.info,
      event: 'b',
      message: '',
      syncLogId: 2,
    );

    final entries =
        await repo.watchEntries(const AppLogFilter(syncLogId: 1)).first;
    expect(entries.map((e) => e.event).toList(), ['a']);
  });

  test('watchEntries free-text search matches event and message', () async {
    await repo.insert(
      level: AppLogLevel.info,
      event: 'sync.start',
      message: 'x',
    );
    await repo.insert(
      level: AppLogLevel.info,
      event: 'ui.compose.send',
      message: 'sent ok',
    );

    final byEvent =
        await repo.watchEntries(const AppLogFilter(search: 'compose')).first;
    expect(byEvent.map((e) => e.event).toList(), ['ui.compose.send']);

    final byMessage =
        await repo.watchEntries(const AppLogFilter(search: 'sent')).first;
    expect(byMessage.map((e) => e.event).toList(), ['ui.compose.send']);
  });

  test('watchEntries returns empty when no levels are selected', () async {
    await repo.insert(level: AppLogLevel.info, event: 'a', message: '');
    final entries =
        await repo.watchEntries(const AppLogFilter(levels: {})).first;
    expect(entries, isEmpty);
  });

  test('trim deletes entries beyond maxRows', () async {
    final now = DateTime.now();
    for (var i = 0; i < 5; i++) {
      await repo.insert(
        level: AppLogLevel.info,
        event: 'e$i',
        message: '',
        createdAt: now.add(Duration(seconds: i)),
      );
    }
    // Disable the age cap so only the row cap is exercised.
    await repo.trim(maxRows: 2, maxAge: const Duration(days: 365 * 100));
    final rows = await db.select(db.appLogs).get();
    expect(rows.map((r) => r.event).toList()..sort(), ['e3', 'e4']);
  });

  test('trim deletes entries older than maxAge', () async {
    await repo.insert(
      level: AppLogLevel.info,
      event: 'old',
      message: '',
      createdAt: DateTime.now().subtract(const Duration(days: 60)),
    );
    await repo.insert(
      level: AppLogLevel.info,
      event: 'new',
      message: '',
    );
    await repo.trim();
    final rows = await db.select(db.appLogs).get();
    expect(rows.map((r) => r.event).toList(), ['new']);
  });

  test('clearAll wipes the table', () async {
    await repo.insert(level: AppLogLevel.info, event: 'x', message: '');
    await repo.insert(level: AppLogLevel.info, event: 'y', message: '');
    await repo.clearAll();
    expect(await db.select(db.appLogs).get(), isEmpty);
  });
}
