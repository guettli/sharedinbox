import 'package:sharedinbox/core/repositories/app_log_repository.dart';

/// An in-memory [AppLogRepository] for tests: every insert becomes an
/// [AppLogEntry] in [rows] (ids 1, 2, …). The one place tests spell out the
/// `insert` signature; subclasses add whatever else a test needs.
class RecordingAppLogRepository extends NoOpAppLogRepository {
  RecordingAppLogRepository({
    List<AppLogEntry>? rows,
    this.defaultCreatedAt,
    this.onInsert,
  }) : rows = rows ?? [];

  final List<AppLogEntry> rows;

  /// `createdAt` of a row inserted without one; null means "now".
  final DateTime? defaultCreatedAt;

  /// Runs before a row is stored, e.g. to make inserts throw.
  final void Function(AppLogEntry entry)? onInsert;

  /// [rows] as one map per insert, keyed by the insert's parameter names.
  List<Map<String, Object?>> get inserts => [
        for (final r in rows)
          {
            'level': r.level,
            'event': r.event,
            'message': r.message,
            'dataJson': r.dataJson,
            'screen': r.screen,
            'accountId': r.accountId,
            'mailboxPath': r.mailboxPath,
            'emailId': r.emailId,
            'syncLogId': r.syncLogId,
          },
      ];

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
    final entry = AppLogEntry(
      id: rows.length + 1,
      createdAt: createdAt ?? defaultCreatedAt ?? DateTime.now(),
      level: level,
      event: event,
      message: message,
      dataJson: dataJson,
      screen: screen,
      accountId: accountId,
      mailboxPath: mailboxPath,
      emailId: emailId,
      syncLogId: syncLogId,
    );
    onInsert?.call(entry);
    rows.add(entry);
    return entry.id;
  }
}
