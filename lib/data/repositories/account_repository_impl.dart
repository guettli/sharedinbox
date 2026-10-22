import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:sharedinbox/core/models/account.dart' as model;
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/storage/secure_storage.dart';
import 'package:sharedinbox/data/db/database.dart';

class AccountRepositoryImpl implements AccountRepository {
  AccountRepositoryImpl(
    this._db,
    this._storage, {
    Future<Directory> Function() getCacheDir = getTemporaryDirectory,
  }) : _getCacheDir = getCacheDir;

  final AppDatabase _db;
  final SecureStorage _storage;
  final Future<Directory> Function() _getCacheDir;

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
    final gone = await _db.transaction(() async {
      await (_db.delete(_db.accounts)..where((t) => t.id.equals(id))).go();
      return _db.deleteRowsOfMissingAccounts();
    });
    await _storage.delete(key: _passwordKey(id));
    await _deleteAttachmentFiles({...gone, id});
  }

  /// Deletes downloaded attachments of [accountIds]: they live in one
  /// folder per email, named after its id (`<accountId>:…` with ':' as '_').
  Future<void> _deleteAttachmentFiles(Set<String> accountIds) async {
    try {
      final root = Directory(
        p.join((await _getCacheDir()).path, 'sharedinbox', 'attachments'),
      );
      if (!await root.exists()) return;
      await for (final entry in root.list()) {
        final name = p.basename(entry.path);
        if (accountIds.any((id) => name.startsWith('${id}_'))) {
          await entry.delete(recursive: true);
        }
      }
    } on Object {
      // Best effort: the OS clears the cache folder eventually.
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
