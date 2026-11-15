import 'package:drift/drift.dart' show Variable;
import 'package:sharedinbox/core/repositories/unsynced_work_repository.dart';
import 'package:sharedinbox/data/db/database.dart';

class UnsyncedWorkRepositoryImpl implements UnsyncedWorkRepository {
  UnsyncedWorkRepositoryImpl(this._db);

  final AppDatabase _db;

  @override
  Future<UnsyncedWork> countForAccount(String accountId) async {
    final row = await _db.customSelect(
      'SELECT '
      '(SELECT COUNT(*) FROM pending_changes WHERE account_id = ?1) AS changes, '
      '(SELECT COUNT(*) FROM outbox WHERE account_id = ?1) AS outbox, '
      // A note deleted locally but not yet on the server (pending_delete)
      // loses nothing: the server keeps the note.
      '(SELECT COUNT(*) FROM email_notes WHERE account_id = ?1 '
      'AND pending_upload = 1 AND pending_delete = 0) AS notes, '
      '(SELECT COUNT(*) FROM local_sieve_scripts WHERE account_id = ?1) '
      'AS filters, '
      '(SELECT COUNT(*) FROM notification_rules WHERE account_id = ?1) '
      'AS rules',
      variables: [Variable.withString(accountId)],
      readsFrom: {
        _db.pendingChanges,
        _db.outbox,
        _db.emailNotes,
        _db.localSieveScripts,
        _db.notificationRules,
      },
    ).getSingle();
    return UnsyncedWork(
      queuedChanges: row.read<int>('changes'),
      unsentEmails: row.read<int>('outbox'),
      unsyncedNotes: row.read<int>('notes'),
      localFilters: row.read<int>('filters'),
      notificationRules: row.read<int>('rules'),
    );
  }
}
