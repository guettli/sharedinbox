import 'package:sharedinbox/core/storage/db_encryption.dart';

/// Snapshot of the local-storage encryption state.
class DbEncryptionStatus {
  const DbEncryptionStatus({
    required this.isEncrypted,
    required this.pendingChange,
    this.lastError,
  });

  /// True when the live DB file is currently encrypted with SQLCipher.
  final bool isEncrypted;

  /// Non-null when the user has queued a toggle that will apply on next
  /// app start. Used by the UI to render a "Restart to apply" hint.
  final PendingEncryptionChange? pendingChange;

  /// Non-null when the last encryption migration failed (e.g. the SQLCipher
  /// key would not persist). The DB is unchanged; the UI surfaces this so the
  /// user knows their data is still unencrypted.
  final String? lastError;

  bool get hasPendingChange => pendingChange != null;
}

/// User-facing controller for local-storage encryption.
///
/// Toggling is asynchronous from the app's perspective: the migration runs at
/// the next `initDatabasePath()` because converting the SQLite file between
/// plaintext and SQLCipher requires exclusive access. Until the user restarts
/// the app, the live DB keeps its current encryption state.
class DbEncryptionService {
  const DbEncryptionService(this._dbPath);

  final String _dbPath;

  DbEncryptionStatus status() => DbEncryptionStatus(
        isEncrypted: isDbEncrypted(_dbPath),
        pendingChange: readPendingEncryptionChange(_dbPath),
        lastError: readEncryptionError(_dbPath),
      );

  /// Clears a surfaced migration error once the user has acknowledged it.
  void dismissError() => clearEncryptionError(_dbPath);

  /// Requests that encryption be enabled on next app start. Idempotent — a
  /// second call while already pending does nothing.
  void scheduleEnable() {
    if (isDbEncrypted(_dbPath)) {
      // Already on; clear any stale "disable" pending so the toggle reflects
      // the current state.
      if (readPendingEncryptionChange(_dbPath) ==
          PendingEncryptionChange.disable) {
        clearPendingEncryptionChange(_dbPath);
      }
      return;
    }
    writePendingEncryptionChange(_dbPath, PendingEncryptionChange.enable);
  }

  /// Requests that encryption be disabled on next app start.
  void scheduleDisable() {
    if (!isDbEncrypted(_dbPath)) {
      if (readPendingEncryptionChange(_dbPath) ==
          PendingEncryptionChange.enable) {
        clearPendingEncryptionChange(_dbPath);
      }
      return;
    }
    writePendingEncryptionChange(_dbPath, PendingEncryptionChange.disable);
  }

  /// Cancels a queued enable/disable before the user restarts the app.
  void cancelPendingChange() => clearPendingEncryptionChange(_dbPath);
}
