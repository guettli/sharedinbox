import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';

/// In-memory [AccountRepository] over a fixed, growable [accounts] list,
/// shared by the reliability-runner suites instead of each restating the
/// interface (and tripping the jscpd duplication gate). Writes are no-ops;
/// every account's password is `secret`.
class FakeAccountRepository implements AccountRepository {
  FakeAccountRepository(this.accounts);

  final List<Account> accounts;

  @override
  Stream<List<Account>> observeAccounts() => Stream.value(accounts);
  @override
  Future<Account?> getAccount(String id) async => accounts
      .cast<Account?>()
      .firstWhere((a) => a?.id == id, orElse: () => null);
  @override
  Future<void> addAccount(Account account, String password) async {}
  @override
  Future<void> updateAccount(Account account, {String? password}) async {}
  @override
  Future<void> removeAccount(String id) async {}
  @override
  Future<String> getPassword(String id) async => 'secret';
}
