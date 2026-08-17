// Integration tests for EmailRepositoryImpl against a real Stalwart instance.
// Run via: stalwart-dev/test.sh
//
// Uses a per-isolate pool user from stalwart_harness.dart so multiple test
// files can run in parallel without racing on INBOX/Trash resets.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:enough_mail/enough_mail.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';
import 'package:test/test.dart';

import '../unit/account_repository_impl_test.dart' show MapSecureStorage;
import '../unit/db_test_helper.dart';
import 'stalwart_harness.dart';

Future<void> _ensureMailbox(ImapClient client, String mailboxPath) async {
  try {
    await client.selectMailboxByPath(mailboxPath);
  } catch (_) {
    await client.createMailbox(mailboxPath);
  }
}

void main() {
  late StalwartEnv env;
  late StalwartTestUser user;
  late Account account;
  late Directory cacheDir;

  setUpAll(() {
    configureSqliteForTests();
    env = StalwartEnv.fromPlatform();
    user = pickPoolUser(env: env);
    account = user.imapAccount(id: 'test', env: env);
    cacheDir = Directory.systemTemp.createTempSync('repo_imap_test_');
  });

  tearDownAll(() => cacheDir.deleteSync(recursive: true));

  setUp(() async {
    await clearStandardMailboxes(env: env, user: user);
  });

  ({AppDatabase db, AccountRepositoryImpl accounts, EmailRepositoryImpl emails})
      makeRepo() {
    final db = openTestDatabase();
    final storage = MapSecureStorage();
    final accounts = AccountRepositoryImpl(db, storage);
    final emails = EmailRepositoryImpl(
      db,
      accounts,
      imapConnect: testImapConnect,
      smtpConnect: testSmtpConnect,
      getCacheDir: () async => cacheDir,
    );
    return (db: db, accounts: accounts, emails: emails);
  }

  Future<void> appendToInbox(String subject, {String body = 'Body'}) async {
    final client = await connectImap(env: env, user: user);
    try {
      final msg = MessageBuilder()
        ..from = [MailAddress(user.email, user.email)]
        ..to = [MailAddress(user.email, user.email)]
        ..subject = subject
        ..text = body;
      await client.appendMessage(
        msg.buildMimeMessage(),
        targetMailboxPath: 'INBOX',
      );
    } finally {
      await client.logout();
    }
  }

  test('syncEmails fetches messages from INBOX and stores in DB', () async {
    final subject = 'sync-${DateTime.now().millisecondsSinceEpoch}';
    await appendToInbox(subject);

    final r = makeRepo();
    await r.accounts.addAccount(account, user.password);
    await r.emails.syncEmails('test', 'INBOX');

    final emails = await r.emails.observeEmails('test', 'INBOX').first;
    expect(emails, hasLength(1));
    expect(emails.first.subject, subject);
    expect(emails.first.isSeen, isFalse);
  });

  test('syncEmails saves IMAP checkpoint after full sync', () async {
    await appendToInbox('checkpoint-test');

    final r = makeRepo();
    await r.accounts.addAccount(account, user.password);
    await r.emails.syncEmails('test', 'INBOX');

    final states = await (r.db.select(r.db.syncStates)
          ..where((t) => t.resourceType.equals('IMAP:INBOX')))
        .get();
    expect(states, hasLength(1));
    final checkpoint = jsonDecode(states.first.state) as Map<String, dynamic>;
    expect(checkpoint['uidValidity'], isA<int>());
    expect((checkpoint['lastUid'] as int), greaterThan(0));
  });

  test(
    'syncEmails incremental sync fetches only messages newer than checkpoint',
    () async {
      await appendToInbox('first');

      final r = makeRepo();
      await r.accounts.addAccount(account, user.password);
      await r.emails.syncEmails('test', 'INBOX');

      final afterFirst = await r.emails.observeEmails('test', 'INBOX').first;
      expect(afterFirst, hasLength(1));
      expect(afterFirst.first.subject, 'first');

      await appendToInbox('second');
      await r.emails.syncEmails('test', 'INBOX');

      final afterSecond = await r.emails.observeEmails('test', 'INBOX').first;
      expect(afterSecond, hasLength(2));
      expect(afterSecond.map((e) => e.subject).toSet(), {'first', 'second'});
    },
  );

  test(
    'CONDSTORE fast-path: second sync skips fetch when nothing changed',
    () async {
      await appendToInbox('condstore-test');

      final r = makeRepo();
      await r.accounts.addAccount(account, user.password);

      // First sync — full sync, saves modseq checkpoint.
      await r.emails.syncEmails('test', 'INBOX');
      final stateAfterFirst = await (r.db.select(r.db.syncStates)
            ..where((t) => t.resourceType.equals('IMAP:INBOX')))
          .get();
      expect(stateAfterFirst, hasLength(1));

      // Second sync with no server changes — CONDSTORE fast-path should skip
      // fetching. DB email count must stay the same.
      await r.emails.syncEmails('test', 'INBOX');
      final emails = await r.emails.observeEmails('test', 'INBOX').first;
      expect(emails, hasLength(1));
    },
  );

  // Marks the given INBOX UID seen on the server via a fresh IMAP session.
  Future<void> markSeenOnServer(int uid) async {
    final client = await connectImap(env: env, user: user);
    try {
      await client.selectMailboxByPath('INBOX');
      await client.uidMarkSeen(MessageSequence.fromIds([uid], isUid: true));
    } finally {
      await client.logout();
    }
  }

  test('CONDSTORE flag refresh updates flags in local DB', () async {
    await appendToInbox('flag-refresh-test');

    final r = makeRepo();
    await r.accounts.addAccount(account, user.password);
    await r.emails.syncEmails('test', 'INBOX');

    final emails = await r.emails.observeEmails('test', 'INBOX').first;
    expect(emails.first.isSeen, isFalse);

    // Mark seen directly on server, advancing modseq.
    await markSeenOnServer(emails.first.uid);

    // Second sync — modseq changed, should refresh flags.
    await r.emails.syncEmails('test', 'INBOX');

    final refreshed = await r.emails.observeEmails('test', 'INBOX').first;
    expect(refreshed.first.isSeen, isTrue);
  });

  // #407: even when HIGHESTMODSEQ does NOT advance after a server-side flag
  // change (as Stalwart 0.14.x sometimes fails to do for JMAP-side keyword
  // edits), the periodic flag reconcile must still detect and correct the
  // drift so the paired IMAP account converges with server truth.
  test('flag reconcile catches drift even when HIGHESTMODSEQ is stuck',
      () async {
    await appendToInbox('stuck-modseq-test');

    final r = makeRepo();
    await r.accounts.addAccount(account, user.password);
    await r.emails.syncEmails('test', 'INBOX');

    final emails = await r.emails.observeEmails('test', 'INBOX').first;
    expect(emails.first.isSeen, isFalse);

    // Mark seen directly on the server, which normally advances HIGHESTMODSEQ.
    await markSeenOnServer(emails.first.uid);

    // Simulate Stalwart's stuck-MODSEQ quirk by rolling the stored
    // highestModSeq forward to whatever the server will report next sync
    // — that way the CONDSTORE fast path's `serverModSeq != storedModSeq`
    // gate skips the refresh, mimicking the bug's precondition.
    final probe = await connectImap(env: env, user: user);
    final int currentServerModSeq;
    try {
      final mbox = await probe.selectMailboxByPath('INBOX');
      currentServerModSeq = mbox.highestModSequence ?? 0;
    } finally {
      await probe.logout();
    }
    final states = await (r.db.select(r.db.syncStates)
          ..where((t) => t.resourceType.equals('IMAP:INBOX')))
        .get();
    expect(states, hasLength(1));
    final checkpoint = jsonDecode(states.first.state) as Map<String, dynamic>;
    checkpoint['highestModSeq'] = currentServerModSeq;
    await (r.db.update(r.db.syncStates)
          ..where((t) => t.resourceType.equals('IMAP:INBOX')))
        .write(SyncStatesCompanion(state: Value(jsonEncode(checkpoint))));
    // Also delete the flag-reconcile timestamp written by the initial full
    // sync so the throttle doesn't suppress the reconcile on the next sync.
    await (r.db.delete(r.db.syncStates)
          ..where((t) => t.resourceType.equals('IMAP:FlagReconcile:INBOX')))
        .go();

    await r.emails.syncEmails('test', 'INBOX');

    final refreshed = await r.emails.observeEmails('test', 'INBOX').first;
    expect(
      refreshed.first.isSeen,
      isTrue,
      reason: 'reconcile must catch the flag change even when CONDSTORE '
          'reports no MODSEQ advance',
    );
  });

  // #565: a mail-to-self shows a local copy immediately; starring it must
  // survive the very sync that delivers the real message. The delivery
  // advances HIGHESTMODSEQ, so the incremental sync runs the CONDSTORE flag
  // refresh (_refreshFlagsImap) right after the dissolve carries the star
  // over — and that refresh used to overwrite the just-transferred star back
  // to server truth (unflagged).
  test('self-message star survives the delivering sync (#565)', () async {
    final r = makeRepo();
    await r.accounts.addAccount(account, user.password);

    // The local copy is written into the mailbox tagged with role 'inbox', so
    // that cache row must exist before enqueueSend runs.
    await r.db.into(r.db.mailboxes).insert(
          MailboxesCompanion.insert(
            id: 'test:INBOX',
            accountId: 'test',
            path: 'INBOX',
            name: 'INBOX',
            role: const Value('inbox'),
          ),
        );

    // Establish the INBOX checkpoint (and modseq) before the self-mail is
    // delivered, so the delivery is what advances HIGHESTMODSEQ.
    await r.emails.syncEmails('test', 'INBOX');

    final subject = 'self-star-${DateTime.now().millisecondsSinceEpoch}';
    final outboxId = await r.emails.enqueueSend(
      'test',
      EmailDraft(
        from: EmailAddress(name: user.email, email: user.email),
        to: [EmailAddress(name: user.email, email: user.email)],
        cc: const [],
        subject: subject,
        body: 'note to self',
      ),
    );
    expect(outboxId, isNonZero);

    // The virtual copy appears in the inbox immediately; star it.
    final local = (await r.emails.observeEmails('test', 'INBOX').first)
        .firstWhere((e) => e.subject == subject);
    expect(local.isLocal, isTrue, reason: 'mail-to-self shows a local copy');
    await r.emails.setFlag(local.id, flagged: true);

    // Actually send it, then sync until the delivered message dissolves the
    // virtual copy into the real one.
    await r.emails.flushOutbox('test', user.password);

    var arrived = false;
    var stillStarred = false;
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      await r.emails.syncEmails('test', 'INBOX');
      final match = (await r.emails.observeEmails('test', 'INBOX').first)
          .where((e) => e.subject == subject && !e.isLocal)
          .toList();
      if (match.isNotEmpty) {
        arrived = true;
        stillStarred = match.single.isFlagged;
        break;
      }
    }

    expect(arrived, isTrue, reason: 'real message should arrive via sync');
    expect(
      stillStarred,
      isTrue,
      reason: 'the star set on the local copy must carry over to the real '
          'message and survive the CONDSTORE flag refresh (#565)',
    );
  });

  test('syncEmails reconciliation removes emails deleted on server', () async {
    await appendToInbox('keep');
    await appendToInbox('delete-me');

    final r = makeRepo();
    await r.accounts.addAccount(account, user.password);
    await r.emails.syncEmails('test', 'INBOX');
    expect(await r.emails.observeEmails('test', 'INBOX').first, hasLength(2));

    // Delete second message directly on the server.
    final imap = await connectImap(env: env, user: user);
    try {
      await imap.selectMailboxByPath('INBOX');
      final search = await imap.uidSearchMessages(
        searchCriteria: 'SUBJECT "delete-me"',
      );
      final uids = search.matchingSequence?.toList() ?? [];
      expect(uids, hasLength(1));
      final seq = MessageSequence.fromIds(uids, isUid: true);
      await imap.uidMarkDeleted(seq);
      await imap.uidExpunge(seq);
    } finally {
      await imap.logout();
    }

    await r.emails.syncEmails('test', 'INBOX');

    final remaining = await r.emails.observeEmails('test', 'INBOX').first;
    expect(remaining, hasLength(1));
    expect(remaining.first.subject, 'keep');
  });

  test('getEmailBody fetches body from IMAP and caches it', () async {
    await appendToInbox('body-test', body: 'Hello from IMAP body');

    final r = makeRepo();
    await r.accounts.addAccount(account, user.password);
    await r.emails.syncEmails('test', 'INBOX');

    final emails = await r.emails.observeEmails('test', 'INBOX').first;
    final emailId = emails.first.id;

    final body = await r.emails.getEmailBody(emailId);
    expect(body.textBody, contains('Hello from IMAP body'));

    // Second call returns cached result without another IMAP connection.
    // We verify by checking the body is identical (no error = no IMAP call).
    final cached = await r.emails.getEmailBody(emailId);
    expect(cached.textBody, body.textBody);
  });

  test(
    'blob expiry: re-fetches body when cachedAt is null (legacy row)',
    () async {
      await appendToInbox('legacy-body-test', body: 'Fresh from server');

      final r = makeRepo();
      await r.accounts.addAccount(account, user.password);
      await r.emails.syncEmails('test', 'INBOX');

      final emails = await r.emails.observeEmails('test', 'INBOX').first;
      final emailId = emails.first.id;

      // Simulate a legacy row with no cachedAt.
      await r.db.into(r.db.emailBodies).insertOnConflictUpdate(
            EmailBodiesCompanion.insert(
              emailId: emailId,
              textBody: const Value('stale text'),
              cachedAt: const Value(null),
            ),
          );

      final body = await r.emails.getEmailBody(emailId);
      expect(body.textBody, contains('Fresh from server'));
    },
  );

  test(
    'getEmailBody(forceRefresh: true) bypasses the IMAP body cache',
    () async {
      await appendToInbox('force-refresh', body: 'Force refresh content');

      final r = makeRepo();
      await r.accounts.addAccount(account, user.password);
      await r.emails.syncEmails('test', 'INBOX');

      final emails = await r.emails.observeEmails('test', 'INBOX').first;
      final emailId = emails.first.id;

      await r.emails.getEmailBody(emailId);
      // Rewind cachedAt so the refresh produces a strictly newer timestamp.
      final stale = DateTime.now().subtract(const Duration(hours: 1));
      await (r.db.update(r.db.emailBodies)
            ..where((t) => t.emailId.equals(emailId)))
          .write(EmailBodiesCompanion(cachedAt: Value(stale)));

      final refreshed =
          await r.emails.getEmailBody(emailId, forceRefresh: true);
      expect(refreshed.textBody, contains('Force refresh content'));

      final row = await (r.db.select(r.db.emailBodies)
            ..where((t) => t.emailId.equals(emailId)))
          .getSingle();
      expect(row.cachedAt!.isAfter(stale), isTrue);
    },
  );

  test(
    'blob expiry: re-fetches body when cached row has null mimeTreeJson',
    () async {
      await appendToInbox('null-mime-tree', body: 'Self-heal body');

      final r = makeRepo();
      await r.accounts.addAccount(account, user.password);
      await r.emails.syncEmails('test', 'INBOX');

      final emails = await r.emails.observeEmails('test', 'INBOX').first;
      final emailId = emails.first.id;

      // Simulate a row written by an older app version: textBody only, no
      // mimeTreeJson, and the timestamp well within TTL.
      await r.db.into(r.db.emailBodies).insertOnConflictUpdate(
            EmailBodiesCompanion.insert(
              emailId: emailId,
              textBody: const Value('legacy text'),
              attachmentsJson: const Value('[]'),
              cachedAt: Value(DateTime.now()),
            ),
          );
      var row = await (r.db.select(r.db.emailBodies)
            ..where((t) => t.emailId.equals(emailId)))
          .getSingle();
      expect(row.mimeTreeJson, isNull);

      // A normal read should trigger a network fetch because the cached row
      // lacks mimeTreeJson, and persist the refreshed data.
      final body = await r.emails.getEmailBody(emailId);
      expect(body.textBody, contains('Self-heal body'));

      row = await (r.db.select(r.db.emailBodies)
            ..where((t) => t.emailId.equals(emailId)))
          .getSingle();
      expect(row.mimeTreeJson, isNotNull);
    },
  );

  test(
    'blob expiry: re-fetches body when cachedAt is older than 7 days',
    () async {
      await appendToInbox('old-body-test', body: 'Current content');

      final r = makeRepo();
      await r.accounts.addAccount(account, user.password);
      await r.emails.syncEmails('test', 'INBOX');

      final emails = await r.emails.observeEmails('test', 'INBOX').first;
      final emailId = emails.first.id;

      // Simulate a row cached 8 days ago.
      await r.db.into(r.db.emailBodies).insertOnConflictUpdate(
            EmailBodiesCompanion.insert(
              emailId: emailId,
              textBody: const Value('old text'),
              cachedAt: Value(DateTime.now().subtract(const Duration(days: 8))),
            ),
          );

      final body = await r.emails.getEmailBody(emailId);
      expect(body.textBody, contains('Current content'));
    },
  );

  test('sendEmail delivers via SMTP and appends copy to Sent folder', () async {
    final subject = 'send-${DateTime.now().millisecondsSinceEpoch}';
    final r = makeRepo();
    await r.accounts.addAccount(account, user.password);

    await r.emails.sendEmail(
      'test',
      EmailDraft(
        from: EmailAddress(name: user.email, email: user.email),
        to: [EmailAddress(name: user.email, email: user.email)],
        cc: [],
        subject: subject,
        body: 'Integration test message',
      ),
    );

    final client = await connectImap(env: env, user: user);
    try {
      final sent = await client.selectMailboxByPath('Sent');
      expect(sent.messagesExists, greaterThan(0));
    } finally {
      await client.logout();
    }
  });

  test('searchEmails returns messages matching query', () async {
    final uniqueWord = 'searchable-${DateTime.now().millisecondsSinceEpoch}';
    await appendToInbox(uniqueWord);

    final r = makeRepo();
    await r.accounts.addAccount(account, user.password);
    await r.emails.syncEmails('test', 'INBOX');

    final results = await r.emails.searchEmails('test', 'INBOX', uniqueWord);
    expect(results, hasLength(1));
    expect(results.first.subject, uniqueWord);
  });

  test('searchEmails returns empty list when no messages match', () async {
    await appendToInbox('unrelated subject');

    final r = makeRepo();
    await r.accounts.addAccount(account, user.password);
    await r.emails.syncEmails('test', 'INBOX');

    final results = await r.emails.searchEmails(
      'test',
      'INBOX',
      'xyzzy-no-match',
    );
    expect(results, isEmpty);
  });

  test('flushPendingChanges applies flag_seen to server', () async {
    await appendToInbox('flag-test');

    final r = makeRepo();
    await r.accounts.addAccount(account, user.password);
    await r.emails.syncEmails('test', 'INBOX');

    final emails = await r.emails.observeEmails('test', 'INBOX').first;
    await r.emails.setFlag(emails.first.id, seen: true);
    await r.emails.flushPendingChanges('test', user.password);

    final client = await connectImap(env: env, user: user);
    try {
      await client.selectMailboxByPath('INBOX');
      final seen = await client.uidSearchMessages(searchCriteria: 'SEEN');
      expect(seen.matchingSequence?.toList() ?? [], isNotEmpty);
    } finally {
      await client.logout();
    }
  });

  test('flushPendingChanges moves email to destination folder', () async {
    await appendToInbox('move-test');

    final setup = await connectImap(env: env, user: user);
    try {
      await _ensureMailbox(setup, 'Trash');
    } finally {
      await setup.logout();
    }

    final r = makeRepo();
    await r.accounts.addAccount(account, user.password);
    await r.emails.syncEmails('test', 'INBOX');

    final emails = await r.emails.observeEmails('test', 'INBOX').first;
    await r.emails.moveEmail(emails.first.id, 'Trash');
    await r.emails.flushPendingChanges('test', user.password);

    final client = await connectImap(env: env, user: user);
    try {
      final inbox = await client.selectMailboxByPath('INBOX');
      expect(inbox.messagesExists, 0);
      final trash = await client.selectMailboxByPath('Trash');
      expect(trash.messagesExists, greaterThan(0));
    } finally {
      await client.logout();
    }
  });

  test('flushPendingChanges deletes email from server', () async {
    await appendToInbox('delete-test');

    final r = makeRepo();
    await r.accounts.addAccount(account, user.password);
    await r.emails.syncEmails('test', 'INBOX');

    final emails = await r.emails.observeEmails('test', 'INBOX').first;
    await r.emails.deleteEmail(emails.first.id);
    await r.emails.flushPendingChanges('test', user.password);

    final client = await connectImap(env: env, user: user);
    try {
      final inbox = await client.selectMailboxByPath('INBOX');
      expect(inbox.messagesExists, 0);
    } finally {
      await client.logout();
    }
  });

  // Regression: the in-app "sync" button calls syncEmails directly and does
  // not invoke flushPendingChanges itself. After a local delete, the message
  // is removed from the local DB optimistically but still lives on the server
  // until the pending change is flushed. If syncEmails runs before that flush,
  // it must not resurrect the deleted row from the server.
  test('syncEmails after local delete does not resurrect message', () async {
    await appendToInbox('delete-and-sync');

    final r = makeRepo();
    await r.accounts.addAccount(account, user.password);
    await r.emails.syncEmails('test', 'INBOX');

    final emails = await r.emails.observeEmails('test', 'INBOX').first;
    expect(emails, hasLength(1));

    // User taps delete in the UI: enqueues a pending change, drops local row.
    await r.emails.deleteEmail(emails.first.id);
    expect(await r.emails.observeEmails('test', 'INBOX').first, isEmpty);

    // User taps the sync button: syncEmails runs without flushPendingChanges.
    await r.emails.syncEmails('test', 'INBOX');

    final after = await r.emails.observeEmails('test', 'INBOX').first;
    expect(
      after,
      isEmpty,
      reason: 'deleted message must not reappear on next sync',
    );

    // The pending delete must still be queued for the next flush.
    final pending = await r.db.select(r.db.pendingChanges).get();
    expect(pending, hasLength(1));
    expect(pending.first.changeType, 'delete');
  });

  test(
    'downloadAttachment fetches binary attachment bytes from IMAP',
    () async {
      final attachmentBytes = Uint8List.fromList(
        List.generate(32, (i) => i + 1),
      );
      const attachmentName = 'hello.bin';
      const attachmentMime = 'application/octet-stream';

      // Build a multipart email with a binary attachment and append it.
      final client = await connectImap(env: env, user: user);
      try {
        final builder = MessageBuilder()
          ..from = [MailAddress(user.email, user.email)]
          ..to = [MailAddress(user.email, user.email)]
          ..subject = 'attach-${DateTime.now().millisecondsSinceEpoch}'
          ..text = 'See attachment.';
        builder.addBinary(
          attachmentBytes,
          MediaType.fromText(attachmentMime),
          filename: attachmentName,
        );
        await client.appendMessage(
          builder.buildMimeMessage(),
          targetMailboxPath: 'INBOX',
        );
      } finally {
        await client.logout();
      }

      final r = makeRepo();
      await r.accounts.addAccount(account, user.password);
      await r.emails.syncEmails('test', 'INBOX');

      final emails = await r.emails.observeEmails('test', 'INBOX').first;
      expect(emails, hasLength(1));
      expect(emails.first.hasAttachment, isTrue);

      final body = await r.emails.getEmailBody(emails.first.id);
      expect(body.attachments, hasLength(1));
      expect(body.attachments.first.filename, attachmentName);
      expect(body.attachments.first.contentType, attachmentMime);
      expect(body.attachments.first.fetchPartId, isNotEmpty);

      final path = await r.emails.downloadAttachment(
        emails.first.id,
        body.attachments.first,
      );
      final downloaded = await File(path).readAsBytes();
      expect(downloaded, equals(attachmentBytes));
    },
  );
}
