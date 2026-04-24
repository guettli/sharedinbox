import 'package:sharedinbox/core/models/account.dart';

abstract class AccountRepository {
  Stream<List<Account>> observeAccounts();
  Future<Account?> getAccount(String id);
  Future<void> addAccount(Account account, String password);

  /// Updates account fields. Pass [password] to also update the stored password.
  Future<void> updateAccount(Account account, {String? password});
  Future<void> removeAccount(String id);
  Future<String> getPassword(String accountId);
}
