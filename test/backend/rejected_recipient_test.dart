// A recipient the server refuses must never be dropped silently, against a
// real Stalwart. Stalwart answers RCPT TO for an unknown local address with
// `550 5.1.2 Mailbox does not exist.`
// Run via: stalwart-dev/test.sh
//
// IMAP/SMTP: one refused address aborts the whole send before DATA, so the
// other recipient gets nothing and the outbox row fails naming the address.
// JMAP: Stalwart accepts the EmailSubmission and reports refusals only in its
// deliveryStatus; the app reads it back. All refused -> the row fails and
// the Sent copy is destroyed; partly refused -> sent, with a warning.

import 'dart:io';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart'
    show SendNowOutcome, SendNowResult;
import 'package:sharedinbox/data/db/database.dart' show AppDatabase;
import 'package:test/test.dart';

import '../unit/db_test_helper.dart';
import 'send_repos.dart';
import 'stalwart_harness.dart';

final _alice = StalwartTestUser(email: 'alice@example.com', password: 'secret');

/// How many messages with [subject] are in [user]'s [mailbox] right now.
Future<int> _count(
  StalwartEnv env,
  String subject, {
  StalwartTestUser? user,
  String mailbox = 'INBOX',
}) async {
  final client = await connectImap(env: env, user: user ?? _alice);
  try {
    await client.selectMailboxByPath(mailbox);
    final found =
        await client.uidSearchMessages(searchCriteria: 'SUBJECT "$subject"');
    return found.matchingSequence?.length ?? 0;
  } finally {
    await client.logout();
  }
}

void main() {
  late StalwartEnv env;
  late StalwartTestUser user;
  late Directory cacheDir;

  setUpAll(() {
    configureSqliteForTests();
    env = StalwartEnv.fromPlatform();
    user = pickPoolUser(env: env);
    cacheDir = Directory.systemTemp.createTempSync('rejected_rcpt_test_');
  });

  tearDownAll(() => cacheDir.deleteSync(recursive: true));

  /// Queues a message from [account] To a nonexistent address (plus Cc alice
  /// when [ccAlice]) and sends it now.
  Future<
      ({
        AppDatabase db,
        SendNowResult result,
        String subject,
      })> send(
    Account account, {
    required bool ccAlice,
  }) async {
    final (:db, :emails) =
        await openSendRepos(account, user.password, cacheDir);
    addTearDown(db.close);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final subject = 'rejected-rcpt-${account.id}-$stamp';
    final rowId = await emails.enqueueSend(
      account.id,
      EmailDraft(
        from: EmailAddress(name: user.email, email: user.email),
        to: [EmailAddress(email: 'nobody-$stamp@example.com')],
        cc: [if (ccAlice) EmailAddress(email: _alice.email)],
        subject: subject,
        body: 'Rejected recipient test',
      ),
    );
    final result = await emails.sendNow(account.id, outboxRowId: rowId);
    return (db: db, result: result, subject: subject);
  }

  test(
    'IMAP/SMTP: a refused To fails the send and the Cc gets nothing',
    () async {
      final r = await send(
        user.imapAccount(id: 'rcpt-imap', env: env),
        ccAlice: true,
      );
      expect(r.result.outcome, SendNowOutcome.permanentlyFailed);
      expect(r.result.message, startsWith('Rejected recipient nobody-'));
      expect(r.result.message, contains('5.1.2'));
      // Local delivery takes well under this; the bug delivered it to alice.
      await Future<void>.delayed(const Duration(seconds: 5));
      expect(await _count(env, r.subject), 0);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'JMAP: a submission whose only recipient is refused fails the send',
    () async {
      final r = await send(
        user.jmapAccount(id: 'rcpt-jmap', env: env),
        ccAlice: false,
      );
      expect(r.result.outcome, SendNowOutcome.permanentlyFailed);
      expect(r.result.message, startsWith('Rejected recipient nobody-'));
      expect(r.result.message, contains('5.1.2'));
      // The Email/set that doubles as the Sent copy is destroyed again.
      final sent = await (r.db.select(r.db.mailboxes)
            ..where((t) => t.role.equals('sent')))
          .getSingle();
      expect(
        await _count(env, r.subject, user: user, mailbox: sent.name),
        0,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'JMAP: a partly refused submission still reaches the others',
    () async {
      // The server delivers to the accepted recipients regardless and a
      // submission cannot be recalled, so the row counts as sent (failing it
      // would only re-send to alice); the refusal goes to the app log.
      final r = await send(
        user.jmapAccount(id: 'rcpt-jmap-cc', env: env),
        ccAlice: true,
      );
      expect(r.result.outcome, SendNowOutcome.sent);
      expect(r.result.warning, startsWith('Not delivered to nobody-'));
      expect(r.result.warning, contains('5.1.2'));
      // The app-log entry is written unawaited.
      final logDeadline = DateTime.now().add(const Duration(seconds: 5));
      var logged = 0;
      while (logged == 0 && DateTime.now().isBefore(logDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        logged = (await (r.db.select(r.db.appLogs)
                  ..where(
                    (t) => t.event.equals('outbox.send.recipient_rejected'),
                  ))
                .get())
            .length;
      }
      expect(logged, 1);
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (await _count(env, r.subject) == 0) {
        if (DateTime.now().isAfter(deadline)) fail('alice never got it');
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
