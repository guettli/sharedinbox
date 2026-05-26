class MailboxSyncStats {
  const MailboxSyncStats({
    required this.mailboxPath,
    required this.fetched,
    required this.skipped,
    required this.bytesTransferred,
    this.duration,
  });

  final String mailboxPath;
  final int fetched;
  final int skipped;
  final int bytesTransferred;
  final Duration? duration;
}

class SyncLogEntry {
  const SyncLogEntry({
    required this.id,
    required this.result,
    this.errorMessage,
    this.stackTrace,
    this.isPermanent = false,
    required this.protocol,
    required this.emailsFetched,
    required this.emailsSkipped,
    required this.mailboxesSynced,
    required this.pendingFlushed,
    required this.bytesTransferred,
    required this.startedAt,
    required this.finishedAt,
    this.mailboxStats = const [],
    this.protocolLog,
  });

  final int id;
  final String result; // 'ok' or 'error'
  final String? errorMessage;
  final String? stackTrace;
  final bool isPermanent;
  final String protocol; // 'imap' or 'jmap'
  final int emailsFetched;
  final int emailsSkipped;
  final int mailboxesSynced;
  final int pendingFlushed;
  final int bytesTransferred;
  final DateTime startedAt;
  final DateTime finishedAt;
  final List<MailboxSyncStats> mailboxStats;
  final String? protocolLog;

  Duration get duration => finishedAt.difference(startedAt);
  bool get isOk => result == 'ok';
}

abstract class SyncLogRepository {
  Future<void> log({
    required String accountId,
    required bool success,
    String? errorMessage,
    String? stackTrace,
    bool isPermanent = false,
    required String protocol,
    required int emailsFetched,
    required int emailsSkipped,
    required int mailboxesSynced,
    required int pendingFlushed,
    required int bytesTransferred,
    required DateTime startedAt,
    required DateTime finishedAt,
    List<MailboxSyncStats> mailboxStats = const [],
    String? protocolLog,
  });

  Stream<List<SyncLogEntry>> observeSyncLogs(String accountId);

  /// Emits the error message of the most recent sync attempt for [accountId],
  /// or null when the last sync succeeded (or no syncs have run yet).
  Stream<String?> observeLastError(String accountId);
}

class NoOpSyncLogRepository implements SyncLogRepository {
  const NoOpSyncLogRepository();

  @override
  Future<void> log({
    required String accountId,
    required bool success,
    String? errorMessage,
    String? stackTrace,
    bool isPermanent = false,
    required String protocol,
    required int emailsFetched,
    required int emailsSkipped,
    required int mailboxesSynced,
    required int pendingFlushed,
    required int bytesTransferred,
    required DateTime startedAt,
    required DateTime finishedAt,
    List<MailboxSyncStats> mailboxStats = const [],
    String? protocolLog,
  }) async {}

  @override
  Stream<List<SyncLogEntry>> observeSyncLogs(String accountId) =>
      Stream.value([]);

  @override
  Stream<String?> observeLastError(String accountId) => Stream.value(null);
}
