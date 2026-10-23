import 'package:sharedinbox/core/repositories/sync_log_repository.dart';

/// [SyncLogRepository] stand-in that records only which account each logged
/// sync was for and whether it succeeded, shared by the sync-manager and
/// reliability-runner suites instead of each restating the interface (jscpd
/// duplication gate).
class FakeSyncLogRepository extends NoOpSyncLogRepository {
  /// Every [log] call, in order.
  final records = <({String accountId, bool success})>[];

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
    records.add((accountId: accountId, success: success));
    return _nextId++;
  }
}
