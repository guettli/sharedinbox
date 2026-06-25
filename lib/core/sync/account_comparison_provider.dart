import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/sync/account_comparison.dart';
import 'package:sharedinbox/di.dart';

/// One-shot comparison between two accounts' local DB rows.
final accountComparisonProvider = FutureProvider.autoDispose
    .family<AccountComparisonResult, (String, String)>((ref, key) async {
  final (idA, idB) = key;
  final service = AccountComparison(ref.watch(dbProvider));
  return service.compare(idA, idB);
});

/// Streams the accounts that form a comparable IMAP/JMAP pair with [accountId]
/// (same host + same effective username, opposite protocol).
final comparableCounterpartsProvider =
    StreamProvider.autoDispose.family<List<Account>, String>((ref, accountId) {
  return ref.watch(accountRepositoryProvider).observeAccounts().map((accounts) {
    final self = accounts.cast<Account?>().firstWhere(
          (a) => a?.id == accountId,
          orElse: () => null,
        );
    if (self == null) return const <Account>[];
    return AccountComparison.counterpartsOf(self, accounts);
  });
});
