import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/storage/secure_storage.dart';
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';

import 'db_test_helper.dart';

// ── Fake ──────────────────────────────────────────────────────────────────────

class MapSecureStorage implements SecureStorage {
  final _map = <String, String>{};

  @override
  Future<void> write({required String key, required String? value}) async {
    if (value == null) {
      _map.remove(key);
    } else {
      _map[key] = value;
    }
  }

  @override
  Future<String?> read({required String key}) async => _map[key];

  @override
  Future<void> delete({required String key}) async => _map.remove(key);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

const _account = Account(
  id: 'acc-1',
  displayName: 'Alice',
  email: 'alice@example.com',
  imapHost: 'imap.example.com',
  smtpHost: 'smtp.example.com',
);

AccountRepositoryImpl _makeRepo() =>
    AccountRepositoryImpl(openTestDatabase(), MapSecureStorage());

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUpAll(configureSqliteForTests);

  group('AccountRepositoryImpl', () {
    test('observeAccounts emits empty list initially', () async {
      final repo = _makeRepo();
      final accounts = await repo.observeAccounts().first;
      expect(accounts, isEmpty);
    });

    test('addAccount then observeAccounts emits the account', () async {
      final repo = _makeRepo();
      await repo.addAccount(_account, 'secret');
      final accounts = await repo.observeAccounts().first;
      expect(accounts, hasLength(1));
      expect(accounts.first.id, 'acc-1');
      expect(accounts.first.email, 'alice@example.com');
    });

    test('getAccount returns null for unknown id', () async {
      final repo = _makeRepo();
      expect(await repo.getAccount('unknown'), isNull);
    });

    test('getAccount returns the account after addAccount', () async {
      final repo = _makeRepo();
      await repo.addAccount(_account, 'secret');
      final result = await repo.getAccount('acc-1');
      expect(result, isNotNull);
      expect(result!.displayName, 'Alice');
    });

    test('getPassword returns stored password', () async {
      final repo = _makeRepo();
      await repo.addAccount(_account, 'mypassword');
      expect(await repo.getPassword('acc-1'), 'mypassword');
    });

    test('getPassword throws StateError when no password stored', () async {
      final repo = _makeRepo();
      expect(
        () => repo.getPassword('missing'),
        throwsA(isA<StateError>()),
      );
    });

    test('removeAccount deletes account and password', () async {
      final repo = _makeRepo();
      await repo.addAccount(_account, 'secret');
      await repo.removeAccount('acc-1');

      expect(await repo.getAccount('acc-1'), isNull);
      expect(
        () => repo.getPassword('acc-1'),
        throwsA(isA<StateError>()),
      );
    });

    test('addAccount is idempotent (upsert)', () async {
      final repo = _makeRepo();
      await repo.addAccount(_account, 'v1');
      const updated = Account(
        id: 'acc-1',
        displayName: 'Alice Updated',
        email: 'alice@example.com',
        imapHost: 'imap.example.com',
        smtpHost: 'smtp.example.com',
      );
      await repo.addAccount(updated, 'v2');
      final accounts = await repo.observeAccounts().first;
      expect(accounts, hasLength(1));
      expect(accounts.first.displayName, 'Alice Updated');
      expect(await repo.getPassword('acc-1'), 'v2');
    });

    test('observeAccounts reflects removal', () async {
      final repo = _makeRepo();
      await repo.addAccount(_account, 'secret');
      await repo.removeAccount('acc-1');
      final accounts = await repo.observeAccounts().first;
      expect(accounts, isEmpty);
    });
  });
}
