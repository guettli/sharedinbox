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
    required DateTime startedAt,
    required DateTime finishedAt,
  }) async {
    await _db.into(_db.syncLogs).insert(
          SyncLogsCompanion.insert(
            accountId: accountId,
            result: success ? 'ok' : 'error',
            errorMessage: Value(errorMessage),
            startedAt: startedAt,
            finishedAt: finishedAt,
          ),
        );
  }
}
