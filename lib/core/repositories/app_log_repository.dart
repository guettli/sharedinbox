/// Severity of an [AppLogEntry]. Ordering mirrors common logging conventions:
/// debug < info < warn < error.
enum AppLogLevel {
  debug,
  info,
  warn,
  error;

  String get wireName => switch (this) {
        AppLogLevel.debug => 'debug',
        AppLogLevel.info => 'info',
        AppLogLevel.warn => 'warn',
        AppLogLevel.error => 'error',
      };

  static AppLogLevel? tryParse(String value) {
    switch (value) {
      case 'debug':
        return AppLogLevel.debug;
      case 'info':
        return AppLogLevel.info;
      case 'warn':
        return AppLogLevel.warn;
      case 'error':
        return AppLogLevel.error;
    }
    return null;
  }
}

class AppLogEntry {
  const AppLogEntry({
    required this.id,
    required this.createdAt,
    required this.level,
    required this.event,
    required this.message,
    this.dataJson,
    this.screen,
    this.accountId,
    this.mailboxPath,
    this.emailId,
    this.syncLogId,
  });

  final int id;
  final DateTime createdAt;
  final AppLogLevel level;
  final String event;
  final String message;
  // JSON-encoded object of extra structured fields. Null when the caller
  // attached no extra data and no error/stack trace.
  final String? dataJson;
  final String? screen;
  final String? accountId;
  final String? mailboxPath;
  final String? emailId;
  final int? syncLogId;
}

/// Filter applied when streaming entries from [AppLogRepository.watchEntries].
/// Default filter hides debug rows — the issue mandates "hide debug by default".
class AppLogFilter {
  const AppLogFilter({
    this.levels = const {
      AppLogLevel.info,
      AppLogLevel.warn,
      AppLogLevel.error,
    },
    this.accountId,
    this.syncLogId,
    this.search,
    this.limit = 500,
  });

  final Set<AppLogLevel> levels;
  final String? accountId;
  final int? syncLogId;
  final String? search;
  final int limit;

  AppLogFilter copyWith({
    Set<AppLogLevel>? levels,
    String? accountId,
    int? syncLogId,
    String? search,
    int? limit,
    bool clearAccountId = false,
    bool clearSyncLogId = false,
    bool clearSearch = false,
  }) {
    return AppLogFilter(
      levels: levels ?? this.levels,
      accountId: clearAccountId ? null : (accountId ?? this.accountId),
      syncLogId: clearSyncLogId ? null : (syncLogId ?? this.syncLogId),
      search: clearSearch ? null : (search ?? this.search),
      limit: limit ?? this.limit,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! AppLogFilter) return false;
    if (other.accountId != accountId) return false;
    if (other.syncLogId != syncLogId) return false;
    if (other.search != search) return false;
    if (other.limit != limit) return false;
    if (other.levels.length != levels.length) return false;
    for (final l in levels) {
      if (!other.levels.contains(l)) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        Object.hashAllUnordered(levels),
        accountId,
        syncLogId,
        search,
        limit,
      );
}

abstract class AppLogRepository {
  /// Inserts a row. Implementations must never throw — logging is best-effort
  /// and a failure here must not abort the caller. Returns the new row id, or
  /// `null` if the insert was suppressed (e.g. DB unavailable in tests).
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
  });

  /// Watches the most recent entries matching [filter], newest first.
  Stream<List<AppLogEntry>> watchEntries(AppLogFilter filter);

  /// Emits the newest entry (by created_at/id) for [accountId] whose
  /// [event] column equals [event], or `null` when the account has never
  /// logged that event. Emits again whenever a newer matching row appears.
  /// Used by the sync-state view to render the "Push" row.
  Stream<AppLogEntry?> watchLatestForAccount({
    required String accountId,
    required String event,
  });

  /// Removes everything older than [maxRows] / [maxAge] (whichever leaves
  /// fewer rows). Idempotent — safe to call any time.
  Future<void> trim({
    int maxRows = 10000,
    Duration maxAge = const Duration(days: 14),
  });

  /// Clears every row. Used by the "Clear log" UI action.
  Future<void> clearAll();
}

class NoOpAppLogRepository implements AppLogRepository {
  const NoOpAppLogRepository();

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
  }) async =>
      null;

  @override
  Stream<List<AppLogEntry>> watchEntries(AppLogFilter filter) =>
      Stream.value(const []);

  @override
  Stream<AppLogEntry?> watchLatestForAccount({
    required String accountId,
    required String event,
  }) =>
      Stream.value(null);

  @override
  Future<void> trim({
    int maxRows = 10000,
    Duration maxAge = const Duration(days: 14),
  }) async {}

  @override
  Future<void> clearAll() async {}
}
