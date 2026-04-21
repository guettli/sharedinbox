import 'package:drift/drift.dart';

import '../../core/repositories/sync_log_repository.dart';
import '../db/database.dart';

class SyncLogRepositoryImpl implements SyncLogRepository {
  SyncLogRepositoryImpl(this._db);

  final AppDatabase _db;

  @override
  Future<void> log({
    required String accountId,
    required bool success,
    String? errorMessage,
    required String protocol,
    required int emailsFetched,
    required int emailsSkipped,
    required int mailboxesSynced,
    required int pendingFlushed,
    required int bytesTransferred,
    required DateTime startedAt,
    required DateTime finishedAt,
  }) async {
    await _db.into(_db.syncLogs).insert(
          SyncLogsCompanion.insert(
            accountId: accountId,
            result: success ? 'ok' : 'error',
            errorMessage: Value(errorMessage),
            protocol: Value(protocol),
            itemsSynced: Value(emailsFetched),
            emailsSkipped: Value(emailsSkipped),
            mailboxesSynced: Value(mailboxesSynced),
            pendingFlushed: Value(pendingFlushed),
            bytesTransferred: Value(bytesTransferred),
            startedAt: startedAt,
            finishedAt: finishedAt,
          ),
        );
  }

  @override
  Stream<List<SyncLogEntry>> observeSyncLogs(String accountId) {
    return (_db.select(_db.syncLogs)
          ..where((t) => t.accountId.equals(accountId))
          ..orderBy([(t) => OrderingTerm.desc(t.startedAt)])
          ..limit(100))
        .watch()
        .map(
          (rows) => rows
              .map(
                (r) => SyncLogEntry(
                  id: r.id,
                  result: r.result,
                  errorMessage: r.errorMessage,
                  protocol: r.protocol,
                  emailsFetched: r.itemsSynced,
                  emailsSkipped: r.emailsSkipped,
                  mailboxesSynced: r.mailboxesSynced,
                  pendingFlushed: r.pendingFlushed,
                  bytesTransferred: r.bytesTransferred,
                  startedAt: r.startedAt,
                  finishedAt: r.finishedAt,
                ),
              )
              .toList(),
        );
  }
}
