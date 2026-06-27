import 'package:drift/drift.dart';

import 'package:sharedinbox/core/repositories/sync_log_repository.dart';
import 'package:sharedinbox/data/db/database.dart';

class SyncLogRepositoryImpl implements SyncLogRepository {
  SyncLogRepositoryImpl(this._db);

  final AppDatabase _db;

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
    var logId = 0;
    await _db.transaction(() async {
      logId = await _db.into(_db.syncLogs).insert(
            SyncLogsCompanion.insert(
              accountId: accountId,
              result: success ? 'ok' : 'error',
              errorMessage: Value(errorMessage),
              errorStackTrace: Value(stackTrace),
              isPermanent: Value(isPermanent),
              protocol: Value(protocol),
              itemsSynced: Value(emailsFetched),
              emailsSkipped: Value(emailsSkipped),
              mailboxesSynced: Value(mailboxesSynced),
              pendingFlushed: Value(pendingFlushed),
              bytesTransferred: Value(bytesTransferred),
              startedAt: startedAt,
              finishedAt: finishedAt,
              protocolLog: Value(protocolLog),
            ),
          );
      for (final s in mailboxStats) {
        await _db.into(_db.syncLogMailboxes).insert(
              SyncLogMailboxesCompanion.insert(
                syncLogId: logId,
                mailboxPath: s.mailboxPath,
                fetched: Value(s.fetched),
                skipped: Value(s.skipped),
                bytesTransferred: Value(s.bytesTransferred),
                durationMs: Value(s.duration?.inMilliseconds),
                mailboxName: Value(s.mailboxName),
              ),
            );
      }
    });
    return logId;
  }

  @override
  Stream<List<SyncLogEntry>> observeSyncLogs(String accountId) {
    final logsQuery = _db.select(_db.syncLogs)
      ..where((t) => t.accountId.equals(accountId))
      ..orderBy([(t) => OrderingTerm.desc(t.startedAt)])
      ..limit(100);

    return logsQuery.watch().asyncMap((rows) async {
      final entries = <SyncLogEntry>[];
      for (final r in rows) {
        // Sort by mailbox_name when present (JMAP labels) and fall back to
        // mailbox_path so pre-v44 rows still produce a stable order.
        final mailboxRows = await (_db.select(_db.syncLogMailboxes)
              ..where((t) => t.syncLogId.equals(r.id))
              ..orderBy([
                (t) => OrderingTerm.asc(t.mailboxName),
                (t) => OrderingTerm.asc(t.mailboxPath),
              ]))
            .get();
        entries.add(
          SyncLogEntry(
            id: r.id,
            result: r.result,
            errorMessage: r.errorMessage,
            stackTrace: r.errorStackTrace,
            isPermanent: r.isPermanent,
            protocol: r.protocol,
            emailsFetched: r.itemsSynced,
            emailsSkipped: r.emailsSkipped,
            mailboxesSynced: r.mailboxesSynced,
            pendingFlushed: r.pendingFlushed,
            bytesTransferred: r.bytesTransferred,
            startedAt: r.startedAt,
            finishedAt: r.finishedAt,
            protocolLog: r.protocolLog,
            mailboxStats: mailboxRows
                .map(
                  (m) => MailboxSyncStats(
                    mailboxPath: m.mailboxPath,
                    mailboxName: m.mailboxName,
                    fetched: m.fetched,
                    skipped: m.skipped,
                    bytesTransferred: m.bytesTransferred,
                    duration: m.durationMs != null
                        ? Duration(milliseconds: m.durationMs!)
                        : null,
                  ),
                )
                .toList(),
          ),
        );
      }
      return entries;
    });
  }

  @override
  Stream<String?> observeLastError(String accountId) {
    return (_db.select(_db.syncLogs)
          ..where((t) => t.accountId.equals(accountId))
          ..orderBy([(t) => OrderingTerm.desc(t.startedAt)])
          ..limit(1))
        .watchSingleOrNull()
        .map((row) => (row?.result == 'error') ? row?.errorMessage : null);
  }
}
