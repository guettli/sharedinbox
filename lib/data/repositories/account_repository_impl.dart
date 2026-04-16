import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/models/account.dart';
import '../../core/repositories/account_repository.dart';
import '../db/database.dart';
import '../db/database.dart' as db show Account;

class AccountRepositoryImpl implements AccountRepository {
  AccountRepositoryImpl(this._db);

  final AppDatabase _db;
  final _storage = const FlutterSecureStorage();

  @override
  Stream<List<Account>> observeAccounts() {
    return _db.select(_db.accounts).watch().map(
          (rows) => rows.map(_toModel).toList(),
        );
  }

  @override
  Future<Account?> getAccount(String id) async {
    final row = await (_db.select(_db.accounts)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : _toModel(row);
  }

  @override
  Future<void> addAccount(Account account, String password) async {
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
          ),
        );
    await _storage.write(key: _passwordKey(account.id), value: password);
  }

  @override
  Future<void> removeAccount(String id) async {
    await (_db.delete(_db.accounts)..where((t) => t.id.equals(id))).go();
    await _storage.delete(key: _passwordKey(id));
  }

  @override
  Future<String> getPassword(String accountId) async {
    final pw = await _storage.read(key: _passwordKey(accountId));
    if (pw == null) throw StateError('No password stored for account $accountId');
    return pw;
  }

  String _passwordKey(String accountId) => 'account_password_$accountId';

  Account _toModel(db.Account row) => Account(
        id: row.id,
        displayName: row.displayName,
        email: row.email,
        imapHost: row.imapHost,
        imapPort: row.imapPort,
        imapSsl: row.imapSsl,
        smtpHost: row.smtpHost,
        smtpPort: row.smtpPort,
        smtpSsl: row.smtpSsl,
      );
}
