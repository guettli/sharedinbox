import 'package:drift/drift.dart' show Value;

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
    return _db.select(_db.accounts).watch().map(
          (rows) => rows.map(_toModel).toList(),
        );
  }

  @override
  Future<model.Account?> getAccount(String id) async {
    final row = await (_db.select(_db.accounts)..where((t) => t.id.equals(id)))
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
          ),
        );
    await _storage.write(key: _passwordKey(account.id), value: password);
  }

  @override
  Future<void> updateAccount(model.Account account, {String? password}) async {
    await (_db.update(_db.accounts)..where((t) => t.id.equals(account.id)))
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
      ),
    );
    if (password != null) {
      await _storage.write(key: _passwordKey(account.id), value: password);
    }
  }

  @override
  Future<void> removeAccount(String id) async {
    await (_db.delete(_db.accounts)..where((t) => t.id.equals(id))).go();
    await _storage.delete(key: _passwordKey(id));
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
      );
}
