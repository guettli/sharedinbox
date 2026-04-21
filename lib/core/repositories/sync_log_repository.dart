class SyncLogEntry {
  const SyncLogEntry({
    required this.id,
    required this.result,
    this.errorMessage,
    required this.startedAt,
    required this.finishedAt,
  });

  final int id;
  final String result; // 'ok' or 'error'
  final String? errorMessage;
  final DateTime startedAt;
  final DateTime finishedAt;

  Duration get duration => finishedAt.difference(startedAt);
  bool get isOk => result == 'ok';
}

abstract class SyncLogRepository {
  Future<void> log({
    required String accountId,
    required bool success,
    String? errorMessage,
    required DateTime startedAt,
    required DateTime finishedAt,
  });

  Stream<List<SyncLogEntry>> observeSyncLogs(String accountId);
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

  @override
  Stream<List<SyncLogEntry>> observeSyncLogs(String accountId) =>
      Stream.value([]);
}
