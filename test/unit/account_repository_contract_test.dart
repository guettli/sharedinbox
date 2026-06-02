import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';

import 'account_repository_impl_test.dart' show MapSecureStorage;
import 'db_test_helper.dart';

// ── Contract ──────────────────────────────────────────────────────────────────

/// Verifies the [AccountRepository] interface contract.
///
/// Subclass this and override [makeRepo] to run the same suite against any
/// concrete implementation.
abstract class AccountRepositoryContract {
  AccountRepository makeRepo();

  static const _a = Account(
    id: 'c-1',
    displayName: 'Contract',
    email: 'c@example.com',
    imapHost: 'imap.example.com',
    smtpHost: 'smtp.example.com',
  );

  void run() {
    test('observeAccounts starts empty', () async {
      final repo = makeRepo();
      expect(await repo.observeAccounts().first, isEmpty);
    });

    test('addAccount makes account visible via observeAccounts', () async {
      final repo = makeRepo();
      await repo.addAccount(_a, 'pw');
      final list = await repo.observeAccounts().first;
      expect(list, hasLength(1));
      expect(list.first.id, _a.id);
    });

    test('getAccount returns null for unknown id', () async {
      final repo = makeRepo();
      expect(await repo.getAccount('no-such'), isNull);
    });

    test('getAccount returns added account', () async {
      final repo = makeRepo();
      await repo.addAccount(_a, 'pw');
      final a = await repo.getAccount(_a.id);
      expect(a, isNotNull);
      expect(a!.email, _a.email);
    });

    test('getPassword returns stored password', () async {
      final repo = makeRepo();
      await repo.addAccount(_a, 'secret123');
      expect(await repo.getPassword(_a.id), 'secret123');
    });

    test('updateAccount reflects changes in observeAccounts', () async {
      final repo = makeRepo();
      await repo.addAccount(_a, 'pw');
      final updated = _a.copyWith(displayName: 'Updated');
      await repo.updateAccount(updated);
      final list = await repo.observeAccounts().first;
      expect(list.first.displayName, 'Updated');
    });

    test('updateAccount with password updates stored password', () async {
      final repo = makeRepo();
      await repo.addAccount(_a, 'old');
      await repo.updateAccount(_a, password: 'new');
      expect(await repo.getPassword(_a.id), 'new');
    });

    test(
      'removeAccount makes account disappear from observeAccounts',
      () async {
        final repo = makeRepo();
        await repo.addAccount(_a, 'pw');
        await repo.removeAccount(_a.id);
        expect(await repo.observeAccounts().first, isEmpty);
      },
    );

    test('getAccount returns null after removeAccount', () async {
      final repo = makeRepo();
      await repo.addAccount(_a, 'pw');
      await repo.removeAccount(_a.id);
      expect(await repo.getAccount(_a.id), isNull);
    });
  }
}

// ── Impl under test ───────────────────────────────────────────────────────────

class _AccountRepositoryImplContract extends AccountRepositoryContract {
  @override
  AccountRepository makeRepo() =>
      AccountRepositoryImpl(openTestDatabase(), MapSecureStorage());
}

void main() {
  setUpAll(configureSqliteForTests);

  group('AccountRepositoryImpl satisfies AccountRepository contract', () {
    _AccountRepositoryImplContract().run();
  });
}
