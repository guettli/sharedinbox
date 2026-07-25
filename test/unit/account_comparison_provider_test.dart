import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/sync/account_comparison.dart';
import 'package:sharedinbox/core/sync/account_comparison_provider.dart';
import 'package:sharedinbox/di.dart';

import 'account_sync_manager_test.mocks.dart';
import 'db_test_helper.dart';

// Reuses the generated MockAccountRepository from
// account_sync_manager_test.mocks.dart to avoid hand-rolling — and
// duplicating — another AccountRepository fake (jscpd guard).
MockAccountRepository _accountRepoWith(List<Account> accounts) {
  final repo = MockAccountRepository();
  when(repo.observeAccounts()).thenAnswer((_) => Stream.value(accounts));
  return repo;
}

void main() {
  configureSqliteForTests();

  group('accountComparisonProvider', () {
    test('returns an AccountComparisonResult built from the shared DB',
        () async {
      final db = openTestDatabase();
      final container = ProviderContainer(
        overrides: [dbProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      addTearDown(db.close);

      // Empty DB → both accounts have zero mailboxes; result is well-formed.
      final result = await container
          .read(accountComparisonProvider(('imap', 'jmap')).future);
      expect(result, isA<AccountComparisonResult>());
      expect(result.mailboxes, isEmpty);
      expect(result.emails, isEmpty);
      expect(result.isIdentical, isTrue);
    });
  });

  group('comparableCounterpartsProvider', () {
    const imap = Account(
      id: 'imap',
      displayName: 'Alice (IMAP)',
      email: 'alice@example.com',
      imapHost: 'mail.example.com',
    );
    const jmap = Account(
      id: 'jmap',
      displayName: 'Alice (JMAP)',
      email: 'alice@example.com',
      type: AccountType.jmap,
      jmapUrl: 'https://mail.example.com/jmap',
    );
    const jmapOther = Account(
      id: 'jmap-other',
      displayName: 'Bob',
      email: 'bob@other.example',
      type: AccountType.jmap,
      jmapUrl: 'https://mail.other.example/jmap',
    );

    test('returns the IMAP/JMAP counterpart of the requested account',
        () async {
      final container = ProviderContainer(
        overrides: [
          accountRepositoryProvider.overrideWithValue(
            _accountRepoWith([imap, jmap, jmapOther]),
          ),
        ],
      );
      addTearDown(container.dispose);
      // .autoDispose fires the moment the read subscription ends. Hold an
      // explicit listener so the provider survives long enough for the
      // stream to emit its first value.
      final sub =
          container.listen(comparableCounterpartsProvider('imap'), (_, __) {});
      addTearDown(sub.close);

      final counterparts = await container
          .read(comparableCounterpartsProvider('imap').future);
      expect(counterparts.map((a) => a.id).toList(), ['jmap']);
    });

    test('returns empty when the account is not in the observed list',
        () async {
      final container = ProviderContainer(
        overrides: [
          accountRepositoryProvider.overrideWithValue(_accountRepoWith([imap])),
        ],
      );
      addTearDown(container.dispose);
      final sub = container
          .listen(comparableCounterpartsProvider('missing'), (_, __) {});
      addTearDown(sub.close);

      final counterparts = await container
          .read(comparableCounterpartsProvider('missing').future);
      expect(counterparts, isEmpty);
    });

    test('static counterpartsOf matches the provider output', () {
      expect(
        AccountComparison.counterpartsOf(imap, [imap, jmap, jmapOther])
            .map((a) => a.id),
        ['jmap'],
      );
    });
  });
}
