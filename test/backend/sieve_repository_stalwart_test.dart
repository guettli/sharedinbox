// Integration tests for SieveRepository against a real Stalwart instance.
//
// Covers both transport paths for server-side filters:
//   * JMAP        — `SieveScript/set { onSuccessActivateScript }` (RFC 9661)
//   * ManageSieve — `SETACTIVE "<name>"` (RFC 5804 §2.8)
//
// This is the regression harness for #321: previously, JMAP activation sent a
// non-existent `SieveScript/activate` method and Stalwart replied with an
// `unknownMethod` error, so filter activation had never actually worked
// against Stalwart. Uses a per-isolate pool user from stalwart_harness.dart
// so tests can run in parallel with the rest of the backend suite without
// racing on shared mailboxes or Sieve scripts.
//
// Run via: stalwart-dev/test.sh

import 'dart:io';

import 'package:enough_mail/enough_mail.dart' as mail;
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/jmap/jmap_client.dart';
import 'package:sharedinbox/data/jmap/sieve_repository.dart';
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:test/test.dart';

import '../unit/account_repository_impl_test.dart' show MapSecureStorage;
import '../unit/db_test_helper.dart';
import 'localhost_mapping_client.dart';
import 'stalwart_harness.dart';

const _keepScript = 'require ["fileinto"];\nkeep;\n';

String _fileIntoScript(String subject, String folder) =>
    'require ["fileinto"];\n'
    'if header :contains "Subject" "$subject" {\n'
    '  fileinto "$folder";\n'
    '  stop;\n'
    '}\n'
    'keep;\n';

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

Future<void> _smtpDeliver({
  required StalwartEnv env,
  required StalwartTestUser user,
  required String subject,
}) async {
  final smtp = mail.SmtpClient('sharedinbox-sieve-test');
  await smtp.connectToServer(env.smtpHost, env.smtpPort, isSecure: false);
  await smtp.ehlo();
  await smtp.authenticate(user.email, user.password);
  final builder = mail.MessageBuilder()
    ..from = [mail.MailAddress(user.email, user.email)]
    ..to = [mail.MailAddress(user.email, user.email)]
    ..subject = subject
    ..text = 'sieve activation e2e';
  await smtp.sendMessage(builder.buildMimeMessage());
  await smtp.quit();
}

Future<bool> _folderContainsSubject({
  required StalwartEnv env,
  required StalwartTestUser user,
  required String folder,
  required String subject,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final imap = await connectImap(env: env, user: user);
    try {
      try {
        final box = await imap.selectMailboxByPath(folder);
        if (box.messagesExists > 0) {
          final result = await imap.uidSearchMessages(
            searchCriteria: 'SUBJECT "$subject"',
          );
          final uids = result.matchingSequence?.toList() ?? const <int>[];
          if (uids.isNotEmpty) return true;
        }
      } catch (_) {
        // Folder may not exist until Stalwart lazily creates it — retry.
      }
    } finally {
      await imap.logout();
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  return false;
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
      await clearStandardMailboxes(env: env, user: user);
      await _purgeScripts(r.sieve, account.id);
    });

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

    test('deactivateScript clears the active flag', () async {
      final r = await _makeRepo(account: account, user: user);
      final s = await r.sieve.saveScript(
        account.id,
        name: 'jmap-off',
        content: _keepScript,
      );
      await r.sieve.activateScript(account.id, s.id);

      await r.sieve.deactivateScript(account.id);

      final scripts = await r.sieve.listScripts(account.id);
      expect(scripts.any((s) => s.isActive), isFalse);
    });

    test('activating a non-existent id throws JmapException', () async {
      final r = await _makeRepo(account: account, user: user);
      await expectLater(
        r.sieve.activateScript(account.id, 'no-such-script'),
        throwsA(isA<JmapException>()),
      );
    });

    test('activated fileinto script delivers into target folder', () async {
      final r = await _makeRepo(account: account, user: user);
      final subject =
          'sieve-jmap-e2e-${DateTime.now().microsecondsSinceEpoch}-$pid';
      final script = await r.sieve.saveScript(
        account.id,
        name: 'jmap-e2e',
        content: _fileIntoScript(subject, 'Trash'),
      );
      await r.sieve.activateScript(account.id, script.id);

      await _smtpDeliver(env: env, user: user, subject: subject);

      final landed = await _folderContainsSubject(
        env: env,
        user: user,
        folder: 'Trash',
        subject: subject,
      );
      expect(
        landed,
        isTrue,
        reason: 'Expected activated Sieve script to route the message to Trash',
      );
    });
  });

  group('ManageSieve transport', () {
    late Account account;

    setUp(() async {
      account = user.imapAccount(id: 'sieve-imap', env: env);
      final r = await _makeRepo(account: account, user: user);
      await clearStandardMailboxes(env: env, user: user);
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

    test('activated fileinto script delivers into target folder', () async {
      final r = await _makeRepo(account: account, user: user);
      final subject =
          'sieve-imap-e2e-${DateTime.now().microsecondsSinceEpoch}-$pid';
      await r.sieve.saveScript(
        account.id,
        name: 'imap-e2e',
        content: _fileIntoScript(subject, 'Trash'),
      );
      await r.sieve.activateScript(account.id, 'imap-e2e');

      await _smtpDeliver(env: env, user: user, subject: subject);

      final landed = await _folderContainsSubject(
        env: env,
        user: user,
        folder: 'Trash',
        subject: subject,
      );
      expect(
        landed,
        isTrue,
        reason: 'Expected activated Sieve script to route the message to Trash',
      );
    });
  });
}
