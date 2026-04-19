abstract class SyncLogRepository {
  Future<void> log({
    required String accountId,
    required bool success,
    String? errorMessage,
    required DateTime startedAt,
    required DateTime finishedAt,
  });
}

class NoOpSyncLogRepository implements SyncLogRepository {
  const NoOpSyncLogRepository();

  @override
  Future<void> log({
    required String accountId,
    required bool success,
    String? errorMessage,
    required DateTime startedAt,
    required DateTime finishedAt,
  }) async {}
}
