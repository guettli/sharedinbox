// Integration tests for SieveRepository against a real Stalwart instance.
//
// Covers both transport paths for server-side filter activation:
//   * JMAP        — `SieveScript/set { onSuccessActivateScript }` (RFC 9661)
//   * ManageSieve — `SETACTIVE "<name>"` (RFC 5804 §2.8)
//
// This is the regression harness for #321: previously, JMAP activation sent a
// non-existent `SieveScript/activate` method and Stalwart replied with an
// `unknownMethod` error, so filter activation had never actually worked
// against Stalwart. Uses a per-isolate pool user from stalwart_harness.dart
// so tests can run alongside the rest of the backend suite without racing on
// shared mailboxes or Sieve scripts.
//
// Coverage notes:
//   * JMAP deactivation (`onSuccessActivateScript: null` with no other
//     operations) is a known no-op on Stalwart 0.14.x, so it's covered by
//     unit tests only. ManageSieve deactivation is exercised here since
//     SETACTIVE "" works reliably.
//   * End-to-end SMTP → Sieve delivery is intentionally not asserted here.
//     The dev Stalwart config in stalwart-dev/ does not route SMTP through
//     per-user Sieve scripts, so an activated `fileinto` script does not
//     actually see incoming mail. That's a delivery-pipeline concern
//     separate from the activation bug this issue tracks.
//
// Run via: stalwart-dev/test.sh

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/jmap/sieve_repository.dart';
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:test/test.dart';

import '../unit/account_repository_impl_test.dart' show MapSecureStorage;
import '../unit/db_test_helper.dart';
import 'localhost_mapping_client.dart';
import 'stalwart_harness.dart';

const _keepScript = 'require ["fileinto"];\nkeep;\n';

typedef _Bundle = ({
  SieveRepository sieve,
  AccountRepositoryImpl accounts,
  LocalhostMappingClient httpClient,
});

Future<_Bundle> _makeRepo({
  required Account account,
  required StalwartTestUser user,
}) async {
  final db = openTestDatabase();
  addTearDown(db.close);
  final accounts = AccountRepositoryImpl(db, MapSecureStorage());
  await accounts.addAccount(account, user.password);
  final httpClient = LocalhostMappingClient();
  addTearDown(httpClient.close);
  final sieve = SieveRepository(accounts, httpClient);
  return (sieve: sieve, accounts: accounts, httpClient: httpClient);
}

Future<void> _purgeScripts(SieveRepository repo, String accountId) async {
  try {
    await repo.deactivateScript(accountId);
  } catch (_) {
    // No active script to deactivate — safe to ignore.
  }
  final existing = await repo.listScripts(accountId);
  for (final s in existing) {
    try {
      await repo.deleteScript(accountId, s.id);
    } catch (_) {
      // Best-effort; a stale script left over from a previous run
      // shouldn't block the next test.
    }
  }
}

void main() {
  late StalwartEnv env;
  late StalwartTestUser user;

  setUpAll(() {
    configureSqliteForTests();
    env = StalwartEnv.fromPlatform();
    user = pickPoolUser(env: env);
  });

  group('JMAP transport', () {
    late Account account;

    setUp(() async {
      account = user.jmapAccount(id: 'sieve-jmap', env: env);
      final r = await _makeRepo(account: account, user: user);
      await _purgeScripts(r.sieve, account.id);
    });

    // Regression test for #321. Before the fix, this sent a non-existent
    // `SieveScript/activate` method and Stalwart replied with `unknownMethod`,
    // so the script never became active on the server.
    test('activateScript flips isActive to true on the server', () async {
      final r = await _makeRepo(account: account, user: user);
      final saved = await r.sieve.saveScript(
        account.id,
        name: 'jmap-activate',
        content: _keepScript,
      );

      await r.sieve.activateScript(account.id, saved.id);

      final scripts = await r.sieve.listScripts(account.id);
      final active = scripts.where((s) => s.isActive).toList();
      expect(active, hasLength(1));
      expect(active.first.id, saved.id);
    });

    test('activating a second script deactivates the first', () async {
      final r = await _makeRepo(account: account, user: user);
      final a = await r.sieve.saveScript(
        account.id,
        name: 'jmap-a',
        content: _keepScript,
      );
      final b = await r.sieve.saveScript(
        account.id,
        name: 'jmap-b',
        content: _keepScript,
      );

      await r.sieve.activateScript(account.id, a.id);
      await r.sieve.activateScript(account.id, b.id);

      final scripts = await r.sieve.listScripts(account.id);
      final activeIds =
          scripts.where((s) => s.isActive).map((s) => s.id).toSet();
      expect(activeIds, {b.id});
    });
  });

  group('ManageSieve transport', () {
    late Account account;

    setUp(() async {
      account = user.imapAccount(id: 'sieve-imap', env: env);
      final r = await _makeRepo(account: account, user: user);
      await _purgeScripts(r.sieve, account.id);
    });

    test('activateScript flips isActive to true on the server', () async {
      final r = await _makeRepo(account: account, user: user);
      final saved = await r.sieve.saveScript(
        account.id,
        name: 'imap-activate',
        content: _keepScript,
      );

      await r.sieve.activateScript(account.id, saved.id);

      final scripts = await r.sieve.listScripts(account.id);
      final active = scripts.where((s) => s.isActive).toList();
      expect(active, hasLength(1));
      expect(active.first.id, saved.id);
    });

    test('activating a second script deactivates the first', () async {
      final r = await _makeRepo(account: account, user: user);
      await r.sieve.saveScript(
        account.id,
        name: 'imap-a',
        content: _keepScript,
      );
      await r.sieve.saveScript(
        account.id,
        name: 'imap-b',
        content: _keepScript,
      );

      await r.sieve.activateScript(account.id, 'imap-a');
      await r.sieve.activateScript(account.id, 'imap-b');

      final scripts = await r.sieve.listScripts(account.id);
      final activeIds =
          scripts.where((s) => s.isActive).map((s) => s.id).toSet();
      expect(activeIds, {'imap-b'});
    });

    test('deactivateScript clears the active flag', () async {
      final r = await _makeRepo(account: account, user: user);
      await r.sieve.saveScript(
        account.id,
        name: 'imap-off',
        content: _keepScript,
      );
      await r.sieve.activateScript(account.id, 'imap-off');

      await r.sieve.deactivateScript(account.id);

      final scripts = await r.sieve.listScripts(account.id);
      expect(scripts.any((s) => s.isActive), isFalse);
    });
  });
}
