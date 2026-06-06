// Chaos monkey test — drives the email repository through random operations
// against a live Stalwart instance to surface crashes and data-corruption bugs.
//
// Run via: stalwart-dev/test.sh
//
// Environment variables:
//   STALWART_IMAP_HOST, STALWART_IMAP_PORT
//   STALWART_SMTP_HOST, STALWART_SMTP_PORT
//   STALWART_USER_B / STALWART_PASS_B  (alice@example.com)
//   CHAOS_ROUNDS  (default: 30) — number of random operations to perform
//   CHAOS_SEED    (default: current epoch ms) — seed for reproducibility

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

String _env(String key, [String fallback = '']) =>
    Platform.environment[key] ?? fallback;

Future<ImapClient> _imapConnectPlain(
  Account account,
  String username,
  String password,
) async {
  final client =
      ImapClient(defaultResponseTimeout: const Duration(seconds: 20));
  await client.connectToServer(
    account.imapHost,
    account.imapPort,
    isSecure: false,
  );
  await client.login(username, password);
  return client;
}

Future<SmtpClient> _smtpConnectPlain(
  Account account,
  String username,
  String password,
) async {
  final atIndex = account.email.lastIndexOf('@');
  final domain =
      atIndex != -1 ? account.email.substring(atIndex + 1) : account.smtpHost;
  final client = SmtpClient(domain);
  await client.connectToServer(
    account.smtpHost,
    account.smtpPort,
    isSecure: false,
  );
  await client.ehlo();
  await client.authenticate(username, password);
  return client;
}

Future<void> _clearMailbox(
  Account account,
  String userEmail,
  String userPass,
  String mailboxPath,
) async {
  final client = await _imapConnectPlain(account, userEmail, userPass);
  try {
    final box = await client.selectMailboxByPath(mailboxPath);
    if (box.messagesExists == 0) return;
    final result = await client.uidSearchMessages(searchCriteria: 'ALL');
    final uids = result.matchingSequence?.toList() ?? [];
    if (uids.isEmpty) return;
    final seq = MessageSequence.fromIds(uids, isUid: true);
    await client.uidMarkDeleted(seq);
    await client.uidExpunge(seq);
  } finally {
    await client.logout();
  }
}

void main() {
  late String imapHost;
  late int imapPort;
  late String smtpHost;
  late int smtpPort;
  late String userEmail;
  late String userPass;
  late Account account;
  late AppDatabase db;
  late EmailRepositoryImpl emails;

  setUpAll(configureSqliteForTests);

  setUp(() async {
    imapHost = _env('STALWART_IMAP_HOST', '127.0.0.1');
    imapPort = int.parse(_env('STALWART_IMAP_PORT', '1430'));
    smtpHost = _env('STALWART_SMTP_HOST', '127.0.0.1');
    smtpPort = int.parse(_env('STALWART_SMTP_PORT', '1025'));
    userEmail = _env('STALWART_USER_B', 'alice@example.com');
    userPass = _env('STALWART_PASS_B', 'secret');

    account = Account(
      id: 'chaos',
      displayName: 'Chaos',
      email: userEmail,
      imapHost: imapHost,
      imapPort: imapPort,
      imapSsl: false,
      smtpHost: smtpHost,
      smtpPort: smtpPort,
    );

    db = openTestDatabase();
    final secureStorage = MapSecureStorage();
    final accounts = AccountRepositoryImpl(db, secureStorage);
    await accounts.addAccount(account, userPass);
    emails = EmailRepositoryImpl(
      db,
      accounts,
      imapConnect: _imapConnectPlain,
      smtpConnect: _smtpConnectPlain,
    );

    await _clearMailbox(account, userEmail, userPass, 'INBOX');
  });

  tearDown(() => db.close());

  test('chaos monkey — random operations do not crash the repository',
      () async {
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
          from: email_model.EmailAddress(name: 'Chaos', email: userEmail),
          to: [email_model.EmailAddress(email: userEmail)],
          cc: [],
          subject: 'seed-$i',
          body: 'Seed email $i.',
        ),
      );
    }
    await emails.syncEmails(account.id, 'INBOX');

    for (var round = 0; round < rounds; round++) {
      final action = rng.nextInt(8);
      stdout.writeln('chaos-monkey: round=$round action=$action');

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
              from: email_model.EmailAddress(name: 'Chaos', email: userEmail),
              to: [email_model.EmailAddress(email: userEmail)],
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
              await emails.flushPendingChanges(account.id, userPass);
          stdout.writeln('chaos-monkey: flushed $flushed pending changes');

        case 7: // delete random email
          final inbox = await emails.observeEmails(account.id, 'INBOX').first;
          if (inbox.isEmpty) break;
          final e = inbox[rng.nextInt(inbox.length)];
          await emails.deleteEmail(e.id);
      }
    }

    // Final flush and sync to confirm the server is in a consistent state.
    final flushed = await emails.flushPendingChanges(account.id, userPass);
    stdout.writeln('chaos-monkey: final flush flushed=$flushed');
    final result = await emails.syncEmails(account.id, 'INBOX');
    stdout.writeln('chaos-monkey: final sync fetched=${result.fetched}');
  });
}
