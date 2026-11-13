import 'package:sharedinbox/core/repositories/sync_log_repository.dart';

/// [SyncLogRepository] stand-in that records which account each logged sync
/// was for, whether it succeeded and what error text it stored, shared by the sync-manager and
/// reliability-runner suites instead of each restating the interface (jscpd
/// duplication gate).
class FakeSyncLogRepository extends NoOpSyncLogRepository {
  /// Every [log] call, in order.
  final records = <({
    String accountId,
    bool success,
    String? errorMessage,
    String? stackTrace,
  })>[];

  /// `success` of every [log] call, in order.
  List<bool> get logs => [for (final r in records) r.success];

  int _nextId = 1;

  @override
  Future<int> log({
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
  }) async {
    records.add(
      (
        accountId: accountId,
        success: success,
        errorMessage: errorMessage,
        stackTrace: stackTrace,
      ),
    );
    return _nextId++;
  }
}
