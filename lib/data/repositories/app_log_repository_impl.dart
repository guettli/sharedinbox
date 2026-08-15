import 'package:drift/drift.dart';

import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/data/db/database.dart';

class AppLogRepositoryImpl implements AppLogRepository {
  AppLogRepositoryImpl(this._db);

  final AppDatabase _db;

  @override
  Future<int?> insert({
    required AppLogLevel level,
    required String event,
    required String message,
    String? dataJson,
    String? screen,
    String? accountId,
    String? mailboxPath,
    String? emailId,
    int? syncLogId,
    DateTime? createdAt,
  }) async {
    try {
      return await _db.into(_db.appLogs).insert(
            AppLogsCompanion.insert(
              createdAt: createdAt ?? DateTime.now(),
              level: level.wireName,
              event: event,
              message: message,
              dataJson: Value(dataJson),
              screen: Value(screen),
              accountId: Value(accountId),
              mailboxPath: Value(mailboxPath),
              emailId: Value(emailId),
              syncLogId: Value(syncLogId),
            ),
          );
    } catch (_) {
      // Logging is best-effort — never bubble up.
      return null;
    }
  }

  @override
  Stream<List<AppLogEntry>> watchEntries(AppLogFilter filter) {
    final levels = filter.levels.map((l) => l.wireName).toList();
    final query = _db.select(_db.appLogs);

    if (levels.isEmpty) {
      // Caller explicitly hid every level — emit nothing rather than every row.
      return Stream.value(const []);
    }

    query.where((t) => t.level.isIn(levels));

    final accountId = filter.accountId;
    if (accountId != null) {
      query.where((t) => t.accountId.equals(accountId));
    }
    final syncLogId = filter.syncLogId;
    if (syncLogId != null) {
      query.where((t) => t.syncLogId.equals(syncLogId));
    }
    final emailId = filter.emailId;
    if (emailId != null) {
      query.where((t) => t.emailId.equals(emailId));
    }
    final search = filter.search?.trim();
    if (search != null && search.isNotEmpty) {
      final pattern = '%${search.replaceAll('%', r'\%')}%';
      query.where(
        (t) => t.event.like(pattern) | t.message.like(pattern),
      );
    }

    query
      ..orderBy([
        (t) => OrderingTerm.desc(t.createdAt),
        (t) => OrderingTerm.desc(t.id),
      ])
      ..limit(filter.limit);

    return query.watch().map(
          (rows) => rows
              .map(
                (r) => AppLogEntry(
                  id: r.id,
                  createdAt: r.createdAt,
                  level: AppLogLevel.tryParse(r.level) ?? AppLogLevel.info,
                  event: r.event,
                  message: r.message,
                  dataJson: r.dataJson,
                  screen: r.screen,
                  accountId: r.accountId,
                  mailboxPath: r.mailboxPath,
                  emailId: r.emailId,
                  syncLogId: r.syncLogId,
                ),
              )
              .toList(),
        );
  }

  @override
  Stream<AppLogEntry?> watchLatestForAccount({
    required String accountId,
    required String event,
  }) {
    final query = _db.select(_db.appLogs)
      ..where((t) => t.accountId.equals(accountId) & t.event.equals(event))
      ..orderBy([
        (t) => OrderingTerm.desc(t.createdAt),
        (t) => OrderingTerm.desc(t.id),
      ])
      ..limit(1);
    return query.watch().map(
      (rows) {
        if (rows.isEmpty) return null;
        final r = rows.first;
        return AppLogEntry(
          id: r.id,
          createdAt: r.createdAt,
          level: AppLogLevel.tryParse(r.level) ?? AppLogLevel.info,
          event: r.event,
          message: r.message,
          dataJson: r.dataJson,
          screen: r.screen,
          accountId: r.accountId,
          mailboxPath: r.mailboxPath,
          emailId: r.emailId,
          syncLogId: r.syncLogId,
        );
      },
    );
  }

  @override
  Future<void> trim({
    int maxRows = 10000,
    Duration maxAge = const Duration(days: 14),
  }) async {
    try {
      final cutoff = DateTime.now().subtract(maxAge);
      // Drop anything older than the time cap.
      await (_db.delete(_db.appLogs)
            ..where((t) => t.createdAt.isSmallerThanValue(cutoff)))
          .go();

      // Then enforce the row cap by keeping the newest maxRows ids.
      final keep = await (_db.select(_db.appLogs)
            ..orderBy([
              (t) => OrderingTerm.desc(t.createdAt),
              (t) => OrderingTerm.desc(t.id),
            ])
            ..limit(maxRows))
          .map((r) => r.id)
          .get();
      if (keep.isEmpty) return;
      await (_db.delete(_db.appLogs)..where((t) => t.id.isNotIn(keep))).go();
    } catch (_) {
      // Best-effort, like insert().
    }
  }

  @override
  Future<void> clearAll() async {
    await _db.delete(_db.appLogs).go();
  }
}
