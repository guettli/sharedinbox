class SyncLogEntry {
  const SyncLogEntry({
    required this.id,
    required this.result,
    this.errorMessage,
    required this.protocol,
    required this.emailsFetched,
    required this.emailsSkipped,
    required this.mailboxesSynced,
    required this.pendingFlushed,
    required this.bytesTransferred,
    required this.startedAt,
    required this.finishedAt,
  });

  final int id;
  final String result; // 'ok' or 'error'
  final String? errorMessage;
  final String protocol; // 'imap' or 'jmap'
  final int emailsFetched;
  final int emailsSkipped;
  final int mailboxesSynced;
  final int pendingFlushed;
  final int bytesTransferred;
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
    required String protocol,
    required int emailsFetched,
    required int emailsSkipped,
    required int mailboxesSynced,
    required int pendingFlushed,
    required int bytesTransferred,
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
    required String protocol,
    required int emailsFetched,
    required int emailsSkipped,
    required int mailboxesSynced,
    required int pendingFlushed,
    required int bytesTransferred,
    required DateTime startedAt,
    required DateTime finishedAt,
  }) async {}

  @override
  Stream<List<SyncLogEntry>> observeSyncLogs(String accountId) =>
      Stream.value([]);
}
