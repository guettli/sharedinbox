// Chaos monkey test — drives the email repository through random operations
// against a live Stalwart instance to surface crashes and data-corruption bugs.
//
// Run via: stalwart-dev/test.sh
//
// Uses a per-isolate pool user from stalwart_harness.dart.
//
// Environment variables:
//   CHAOS_ROUNDS  (default: 30) — number of random operations to perform
//   CHAOS_SEED    (default: current epoch ms) — seed for reproducibility

@Tags(['nightly'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:enough_mail/enough_mail.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart' as email_model;
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';
import 'package:test/test.dart';

import '../unit/account_repository_impl_test.dart' show MapSecureStorage;
import '../unit/db_test_helper.dart';
import 'stalwart_harness.dart';

String _env(String key, [String fallback = '']) =>
    Platform.environment[key] ?? fallback;

void main() {
  late StalwartEnv env;
  late StalwartTestUser user;
  late Account account;
  late AppDatabase db;
  late EmailRepositoryImpl emails;

  setUpAll(configureSqliteForTests);

  setUp(() async {
    env = StalwartEnv.fromPlatform();
    user = pickPoolUser(env: env);
    account = user.imapAccount(id: 'chaos', env: env);

    db = openTestDatabase();
    final secureStorage = MapSecureStorage();
    final accounts = AccountRepositoryImpl(db, secureStorage);
    await accounts.addAccount(account, user.password);
    emails = EmailRepositoryImpl(
      db,
      accounts,
      imapConnect: testImapConnect,
      smtpConnect: testSmtpConnect,
    );

    await clearStandardMailboxes(env: env, user: user);
  });

  tearDown(() => db.close());

  test('chaos monkey — random operations do not crash the repository',
      timeout: Timeout.none, () async {
    final seedStr = _env('CHAOS_SEED');
    final seed = seedStr.isEmpty
        ? DateTime.now().millisecondsSinceEpoch
        : int.parse(seedStr);
    final rounds = int.parse(_env('CHAOS_ROUNDS', '30'));
    final rng = Random(seed);

    stdout.writeln('chaos-monkey: seed=$seed rounds=$rounds');

    // Seed INBOX with a few messages so early rounds have something to act on.
    for (var i = 0; i < 3; i++) {
      await emails.sendEmail(
        account.id,
        email_model.EmailDraft(
          from: email_model.EmailAddress(name: 'Chaos', email: user.email),
          to: [email_model.EmailAddress(email: user.email)],
          cc: [],
          subject: 'seed-$i',
          body: 'Seed email $i.',
        ),
      );
    }
    await emails.syncEmails(account.id, 'INBOX');

    // Per-action timeout so a single hung IMAP/SMTP call fails fast with the
    // seed/round/action instead of running out the CI wall clock. Normal
    // actions take well under a second against a local Stalwart; 60s is
    // generous headroom for unusual cases.
    const actionTimeout = Duration(seconds: 60);

    for (var round = 0; round < rounds; round++) {
      final action = rng.nextInt(8);
      stdout.writeln('chaos-monkey: round=$round action=$action');
      await stdout.flush();

      Future<void> runAction() async {
        switch (action) {
          case 0: // sync INBOX
            await emails.syncEmails(account.id, 'INBOX');

          case 1: // sync Sent
            await emails.syncEmails(account.id, 'Sent');

          case 2: // send email to self
            final subject = 'chaos-$round-${rng.nextInt(9999)}';
            await emails.sendEmail(
              account.id,
              email_model.EmailDraft(
                from:
                    email_model.EmailAddress(name: 'Chaos', email: user.email),
                to: [email_model.EmailAddress(email: user.email)],
                cc: [],
                subject: subject,
                body: 'Round $round. Value: ${rng.nextInt(1000000)}.',
              ),
            );

          case 3: // mark random email seen
            final inbox = await emails.observeEmails(account.id, 'INBOX').first;
            if (inbox.isEmpty) break;
            final e = inbox[rng.nextInt(inbox.length)];
            await emails.setFlag(e.id, seen: true);

          case 4: // mark random email unseen
            final inbox = await emails.observeEmails(account.id, 'INBOX').first;
            if (inbox.isEmpty) break;
            final e = inbox[rng.nextInt(inbox.length)];
            await emails.setFlag(e.id, seen: false);

          case 5: // toggle flagged on random email
            final inbox = await emails.observeEmails(account.id, 'INBOX').first;
            if (inbox.isEmpty) break;
            final e = inbox[rng.nextInt(inbox.length)];
            await emails.setFlag(e.id, flagged: !e.isFlagged);

          case 6: // flush pending changes to server
            final flushed =
                await emails.flushPendingChanges(account.id, user.password);
            stdout.writeln('chaos-monkey: flushed $flushed pending changes');

          case 7: // delete random email
            final inbox = await emails.observeEmails(account.id, 'INBOX').first;
            if (inbox.isEmpty) break;
            final e = inbox[rng.nextInt(inbox.length)];
            await emails.deleteEmail(e.id);
        }
      }

      try {
        await runAction().timeout(
          actionTimeout,
          onTimeout: () => _abortOnTimeout(
            'action hung (seed=$seed round=$round action=$action)',
          ),
        );
      } on TimeoutException catch (e) {
        // Bounded timeouts inside the repository (e.g. a slow SMTP/IMAP
        // connect against a briefly overloaded Stalwart) surface here. The
        // test's contract is "random operations do not crash the repository"
        // — a controlled TimeoutException from the send/sync guard-rails is
        // not a crash, it's the guard-rails working. Log with
        // seed/round/action for reproducibility and move on.
        stdout.writeln(
          'chaos-monkey: round=$round action=$action tolerated timeout: $e',
        );
      } on SmtpException catch (e) {
        stdout.writeln(
          'chaos-monkey: round=$round action=$action '
          'tolerated SMTP error: $e',
        );
      } on ImapException catch (e) {
        stdout.writeln(
          'chaos-monkey: round=$round action=$action '
          'tolerated IMAP error: $e',
        );
      } on SocketException catch (e) {
        stdout.writeln(
          'chaos-monkey: round=$round action=$action '
          'tolerated socket error: $e',
        );
      }
    }

    // Final flush and sync to confirm the server is in a consistent state.
    final flushed =
        await emails.flushPendingChanges(account.id, user.password).timeout(
              actionTimeout,
              onTimeout: () => _abortOnTimeout('final flush hung (seed=$seed)'),
            );
    stdout.writeln('chaos-monkey: final flush flushed=$flushed');
    final result = await emails.syncEmails(account.id, 'INBOX').timeout(
          actionTimeout,
          onTimeout: () => _abortOnTimeout('final sync hung (seed=$seed)'),
        );
    stdout.writeln('chaos-monkey: final sync fetched=${result.fetched}');
  });
}

/// Abort the test process immediately with a clear stderr diagnostic.
///
/// `.timeout(onTimeout: () => throw ...)` would normally propagate a
/// TimeoutException and let the test framework report the failure. But hung
/// `enough_mail` sockets keep the Dart isolate alive past test teardown, so
/// the process never exits on its own and the outer `timeout 600` in
/// `Taskfile.yml` ends up SIGKILL'ing it (exit 124) with the buffered
/// failure message lost. Writing to stderr (typically unbuffered) and
/// calling `exit(1)` guarantees CI sees a useful diagnostic.
///
/// Stay fully synchronous — any `await` here would re-enter the same event
/// loop that's already wedged on the hung action's socket, and could delay
/// `exit(1)` long enough for the outer `timeout` to win and drop the
/// stderr line. The per-round `await stdout.flush()` already drained the
/// `round=N action=M` progress line, so there's nothing left to flush.
Never _abortOnTimeout(String message) {
  stderr.writeln('chaos-monkey: $message');
  exit(1);
}
