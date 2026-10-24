// Bcc against a real Stalwart (#1126): a Bcc recipient gets the message, the
// delivered copies carry no Bcc header, and the sender's own copies (Sent,
// server drafts) keep it.
// Run via: stalwart-dev/test.sh
//
// The sender is this isolate's pool user. The recipients are the fixed
// alice@/bob@ principals, which no other backend test uses, plus the pool's
// matching bobN; every check looks a message up by its unique subject, so
// other tests' mail never gets in the way.

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show BooleanExpressionOperators;
import 'package:enough_mail/enough_mail.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/draft_repository_impl.dart';
import 'package:test/test.dart';

import '../unit/account_repository_impl_test.dart' show MapSecureStorage;
import '../unit/db_test_helper.dart';
import 'localhost_mapping_client.dart';
import 'send_repos.dart';
import 'stalwart_harness.dart';

final _alice = StalwartTestUser(email: 'alice@example.com', password: 'secret');
final _bob = StalwartTestUser(email: 'bob@example.com', password: 'secret');

/// The header block of the message with [subject] in [user]'s [mailbox],
/// waiting up to [timeout] for delivery.
Future<String> _headersOf(
  StalwartEnv env,
  StalwartTestUser user,
  String mailbox,
  String subject, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    final client = await connectImap(env: env, user: user);
    try {
      var uids = const <int>[];
      try {
        await client.selectMailboxByPath(mailbox);
        final found = await client.uidSearchMessages(
          searchCriteria: 'SUBJECT "$subject"',
        );
        uids = found.matchingSequence?.toList() ?? const <int>[];
      } on ImapException {
        // Not selectable yet: retry.
      }
      if (uids.isNotEmpty) {
        expect(uids, hasLength(1), reason: '$mailbox of ${user.email}');
        final fetched = await client.uidFetchMessages(
          MessageSequence.fromId(uids.single, isUid: true),
          'BODY.PEEK[HEADER]',
        );
        return fetched.messages.single.renderMessage();
      }
    } finally {
      await client.logout();
    }
    if (DateTime.now().isAfter(deadline)) {
      fail('"$subject" never reached $mailbox of ${user.email}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}

final _bccLine = RegExp(r'^bcc:', multiLine: true, caseSensitive: false);

void main() {
  late StalwartEnv env;
  late StalwartTestUser user;
  late StalwartTestUser poolBob;
  late Directory cacheDir;

  setUpAll(() {
    configureSqliteForTests();
    env = StalwartEnv.fromPlatform();
    user = pickPoolUser(env: env);
    poolBob = pickPoolUser(env: env, prefix: 'bob');
    cacheDir = Directory.systemTemp.createTempSync('bcc_send_test_');
  });

  tearDownAll(() => cacheDir.deleteSync(recursive: true));

  /// Sends To alice, Bcc bob and bobN from [account] and checks every copy.
  Future<void> sendAndCheck(Account account, String subject) async {
    final (:db, :emails) =
        await openSendRepos(account, user.password, cacheDir);

    await emails.sendEmail(
      account.id,
      EmailDraft(
        from: EmailAddress(name: user.email, email: user.email),
        to: [EmailAddress(name: 'Alice', email: _alice.email)],
        cc: const [],
        bcc: [
          EmailAddress(name: 'Bob', email: _bob.email),
          EmailAddress(name: 'Bob N', email: poolBob.email),
        ],
        subject: subject,
        body: 'Bcc integration test',
      ),
    );

    final toCopy = await _headersOf(env, _alice, 'INBOX', subject);
    expect(toCopy, isNot(contains(_bccLine)), reason: toCopy);
    expect(toCopy, isNot(contains(_bob.email)), reason: toCopy);
    expect(toCopy, isNot(contains(poolBob.email)), reason: toCopy);

    // Each Bcc recipient gets it, and learns nothing of the other one.
    for (final (me, other) in [(_bob, poolBob), (poolBob, _bob)]) {
      final bccCopy = await _headersOf(env, me, 'INBOX', subject);
      expect(bccCopy, isNot(contains(_bccLine)), reason: bccCopy);
      expect(bccCopy, isNot(contains(other.email)), reason: bccCopy);
    }

    final sentRow = await (db.select(db.mailboxes)
          ..where((t) => t.accountId.equals(account.id) & t.role.equals('sent'))
          ..limit(1))
        .getSingle();
    // A JMAP mailbox row's path is its id; its name is the IMAP name.
    final sentCopy = await _headersOf(
      env,
      user,
      account.type == AccountType.jmap ? sentRow.name : sentRow.path,
      subject,
    );
    expect(sentCopy, contains(_bccLine), reason: sentCopy);
    expect(sentCopy, contains(_bob.email), reason: sentCopy);
    expect(sentCopy, contains(poolBob.email), reason: sentCopy);

    // The local Sent row shows Bcc right away (#1097's detail header line).
    final local = (await emails.observeEmails(account.id, sentRow.path).first)
        .where((e) => e.subject == subject);
    expect(
      local.single.bcc.map((a) => a.email),
      [_bob.email, poolBob.email],
    );
    await db.close();
  }

  test(
    'IMAP/SMTP: Bcc is delivered but hidden, Sent keeps it',
    () => sendAndCheck(
      user.imapAccount(id: 'bcc-imap', env: env),
      'bcc-imap-${DateTime.now().microsecondsSinceEpoch}',
    ),
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'JMAP: Bcc is delivered but hidden, Sent keeps it',
    () => sendAndCheck(
      user.jmapAccount(id: 'bcc-jmap', env: env),
      'bcc-jmap-${DateTime.now().microsecondsSinceEpoch}',
    ),
    timeout: const Timeout(Duration(minutes: 2)),
  );

  /// Pushes a draft with Bcc from a fresh device and pulls it on another.
  Future<void> draftRoundTrip(Account Function(String id) makeAccount) async {
    final subject = 'bcc-draft-${DateTime.now().microsecondsSinceEpoch}';
    DraftRepositoryImpl device(
      AppDatabase db,
      AccountRepositoryImpl accounts,
    ) =>
        DraftRepositoryImpl(
          db,
          accounts,
          imapConnect: testImapConnect,
          httpClient: LocalhostMappingClient(),
        );

    final db1 = openTestDatabase();
    final accounts1 = AccountRepositoryImpl(db1, MapSecureStorage());
    final account = makeAccount('bcc-draft');
    await accounts1.addAccount(account, _alice.password);
    final drafts1 = device(db1, accounts1);
    final saved = await drafts1.saveDraft(
      accountId: account.id,
      toText: _bob.email,
      ccText: '',
      bccText: 'carol@example.com',
      subjectText: subject,
      bodyText: 'Draft with Bcc',
    );
    await drafts1.syncDrafts(account.id);

    final db2 = openTestDatabase();
    final accounts2 = AccountRepositoryImpl(db2, MapSecureStorage());
    await accounts2.addAccount(account, _alice.password);
    final drafts2 = device(db2, accounts2);
    await drafts2.syncDrafts(account.id);
    final pulled = (await drafts2.listNewMessageDrafts())
        .where((d) => d.subjectText == subject);
    expect(pulled.single.bccText, 'carol@example.com');

    // Leave the server's Drafts as it was.
    await drafts1.deleteDraft(saved.id);
    await drafts1.syncDrafts(account.id);
    await db1.close();
    await db2.close();
  }

  test('IMAP: a draft keeps its Bcc on the server', () async {
    await draftRoundTrip((id) => _alice.imapAccount(id: id, env: env));
  });

  test('JMAP: a draft keeps its Bcc on the server', () async {
    await draftRoundTrip((id) => _alice.jmapAccount(id: id, env: env));
  });
}
