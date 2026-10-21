import 'package:drift/drift.dart' show TableInfo, UpdateKind, Value;

import 'package:sharedinbox/core/models/account.dart' as model;
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/storage/secure_storage.dart';
import 'package:sharedinbox/data/db/database.dart';

class AccountRepositoryImpl implements AccountRepository {
  AccountRepositoryImpl(this._db, this._storage);

  final AppDatabase _db;
  final SecureStorage _storage;

  @override
  Stream<List<model.Account>> observeAccounts() {
    return _db
        .select(_db.accounts)
        .watch()
        .map((rows) => rows.map(_toModel).toList());
  }

  @override
  Future<model.Account?> getAccount(String id) async {
    final row = await (_db.select(
      _db.accounts,
    )..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : _toModel(row);
  }

  @override
  Future<void> addAccount(model.Account account, String password) async {
    await _db.into(_db.accounts).insertOnConflictUpdate(
          AccountsCompanion.insert(
            id: account.id,
            displayName: account.displayName,
            email: account.email,
            imapHost: account.imapHost,
            imapPort: account.imapPort,
            imapSsl: account.imapSsl,
            smtpHost: account.smtpHost,
            smtpPort: account.smtpPort,
            smtpSsl: account.smtpSsl,
            accountType: Value(account.type.name),
            jmapUrl: Value(account.jmapUrl),
            username: Value(account.username),
            verbose: Value(account.verbose),
            manageSieveHost: Value(account.manageSieveHost),
            manageSievePort: Value(account.manageSievePort),
            manageSieveSsl: Value(account.manageSieveSsl),
            manageSieveAvailable: Value(account.manageSieveAvailable),
            signature: Value(account.signature),
            notificationsEnabled: Value(account.notificationsEnabled),
          ),
        );
    await _storage.write(key: _passwordKey(account.id), value: password);
  }

  @override
  Future<void> updateAccount(model.Account account, {String? password}) async {
    await (_db.update(
      _db.accounts,
    )..where((t) => t.id.equals(account.id)))
        .write(
      AccountsCompanion(
        displayName: Value(account.displayName),
        email: Value(account.email),
        imapHost: Value(account.imapHost),
        imapPort: Value(account.imapPort),
        imapSsl: Value(account.imapSsl),
        smtpHost: Value(account.smtpHost),
        smtpPort: Value(account.smtpPort),
        smtpSsl: Value(account.smtpSsl),
        accountType: Value(account.type.name),
        jmapUrl: Value(account.jmapUrl),
        username: Value(account.username),
        verbose: Value(account.verbose),
        manageSieveHost: Value(account.manageSieveHost),
        manageSievePort: Value(account.manageSievePort),
        manageSieveSsl: Value(account.manageSieveSsl),
        manageSieveAvailable: Value(account.manageSieveAvailable),
        signature: Value(account.signature),
        notificationsEnabled: Value(account.notificationsEnabled),
      ),
    );
    if (password != null) {
      await _storage.write(key: _passwordKey(account.id), value: password);
    }
  }

  @override
  Future<void> removeAccount(String id) async {
    await _db.transaction(() async {
      await (_db.delete(_db.accounts)..where((t) => t.id.equals(id))).go();
      await _deleteRowsOfMissingAccounts();
    });
    await _storage.delete(key: _passwordKey(id));
  }

  /// Deletes the rows the schema's `onDelete: cascade` (and `setNull`)
  /// references would remove for accounts that no longer exist. SQLite
  /// enforces foreign keys only after `PRAGMA foreign_keys = ON`, which runs
  /// only after a resync, so deleting an account usually left all its mail,
  /// mailboxes and threads behind — still listed in the combined inbox.
  /// Matching every missing account also clears what earlier deletes left.
  /// Drafts have no such reference and are kept: they hold the user's text.
  Future<void> _deleteRowsOfMissingAccounts() async {
    const gone = 'account_id NOT IN (SELECT id FROM accounts)';
    Future<void> run(
      String sql,
      Set<TableInfo> tables, {
      UpdateKind kind = UpdateKind.delete,
    }) =>
        _db.customUpdate(
          sql,
          updates: tables,
          updateKind: kind,
        );

    // Children of the account's emails and sync logs first.
    await run(
      'DELETE FROM email_bodies WHERE email_id IN '
      '(SELECT id FROM emails WHERE $gone)',
      {_db.emailBodies},
    );
    await run(
      'DELETE FROM attachment_files WHERE email_id IN '
      '(SELECT id FROM emails WHERE $gone)',
      {_db.attachmentFiles},
    );
    await run(
      'DELETE FROM sync_log_mailboxes WHERE sync_log_id IN '
      '(SELECT id FROM sync_logs WHERE $gone)',
      {_db.syncLogMailboxes},
    );
    await run(
      'UPDATE app_logs SET email_id = NULL WHERE email_id IN '
      '(SELECT id FROM emails WHERE $gone)',
      {_db.appLogs},
      kind: UpdateKind.update,
    );
    await run(
      'UPDATE app_logs SET sync_log_id = NULL WHERE sync_log_id IN '
      '(SELECT id FROM sync_logs WHERE $gone)',
      {_db.appLogs},
      kind: UpdateKind.update,
    );
    await run(
      'UPDATE app_logs SET account_id = NULL '
      'WHERE account_id IS NOT NULL AND $gone',
      {_db.appLogs},
      kind: UpdateKind.update,
    );
    for (final table in <TableInfo>[
      _db.emails,
      _db.threads,
      _db.mailboxes,
      _db.pendingChanges,
      _db.syncStates,
      _db.syncLogs,
      _db.syncHealth,
      _db.draftTombstones,
      _db.localSieveScripts,
      _db.localSieveApplied,
      _db.undoActions,
      _db.notificationRules,
      _db.notifiedEmails,
      _db.emailNotes,
      _db.outbox,
    ]) {
      await run('DELETE FROM ${table.actualTableName} WHERE $gone', {table});
    }
  }

  @override
  Future<String> getPassword(String accountId) async {
    final pw = await _storage.read(key: _passwordKey(accountId));
    if (pw == null) {
      throw StateError('No password stored for account $accountId');
    }
    return pw;
  }

  String _passwordKey(String accountId) => 'account_password_$accountId';

  model.Account _toModel(Account row) => model.Account(
        id: row.id,
        displayName: row.displayName,
        email: row.email,
        username: row.username,
        type: model.AccountType.values.byName(row.accountType),
        imapHost: row.imapHost,
        imapPort: row.imapPort,
        imapSsl: row.imapSsl,
        smtpHost: row.smtpHost,
        smtpPort: row.smtpPort,
        smtpSsl: row.smtpSsl,
        manageSieveHost: row.manageSieveHost,
        manageSievePort: row.manageSievePort,
        manageSieveSsl: row.manageSieveSsl,
        manageSieveAvailable: row.manageSieveAvailable,
        jmapUrl: row.jmapUrl,
        verbose: row.verbose,
        signature: row.signature ?? '',
        notificationsEnabled: row.notificationsEnabled ?? false,
      );
}
