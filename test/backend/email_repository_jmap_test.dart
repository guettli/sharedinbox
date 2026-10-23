// Integration tests for EmailRepositoryImpl JMAP path against a real Stalwart instance.
// Run via: stalwart-dev/test.sh
//
// Uses a per-isolate pool user from stalwart_harness.dart so multiple test
// files can run in parallel without racing on INBOX/Trash resets.

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:enough_mail/enough_mail.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';
import 'package:test/test.dart';

import '../unit/account_repository_impl_test.dart' show MapSecureStorage;
import '../unit/db_test_helper.dart';
import 'localhost_mapping_client.dart';
import 'stalwart_harness.dart';

void main() {
  late StalwartEnv env;
  late StalwartTestUser user;
  late Account account;
  late Directory cacheDir;

  setUpAll(() {
    configureSqliteForTests();
    env = StalwartEnv.fromPlatform();
    user = pickPoolUser(env: env);
    account = user.jmapAccount(id: 'test-jmap', env: env);
    cacheDir = Directory.systemTemp.createTempSync('repo_jmap_test_');
  });

  tearDownAll(() => cacheDir.deleteSync(recursive: true));

  setUp(() async {
    await clearStandardMailboxes(env: env, user: user);
  });

  ({
    AppDatabase db,
    AccountRepositoryImpl accounts,
    EmailRepositoryImpl emails,
    MailboxRepositoryImpl mailboxes,
  }) makeRepo() {
    final db = openTestDatabase();
    final accounts = AccountRepositoryImpl(db, MapSecureStorage());
    final httpClient = LocalhostMappingClient();
    final emails = EmailRepositoryImpl(
      db,
      accounts,
      getCacheDir: () async => cacheDir,
      httpClient: httpClient,
    );
    final mailboxes =
        MailboxRepositoryImpl(db, accounts, httpClient: httpClient);
    return (db: db, accounts: accounts, emails: emails, mailboxes: mailboxes);
  }

  // Syncs mailboxes and returns the JMAP ID for the INBOX mailbox.
  Future<String> setupAndGetInboxId(
    AppDatabase db,
    AccountRepositoryImpl accounts,
    MailboxRepositoryImpl mailboxes,
  ) async {
    await accounts.addAccount(account, user.password);
    await mailboxes.syncMailboxes('test-jmap');
    final row = await (db.select(db.mailboxes)
          ..where(
            (t) => t.accountId.equals('test-jmap') & t.role.equals('inbox'),
          )
          ..limit(1))
        .getSingleOrNull();
    if (row == null) throw StateError('INBOX not found after syncMailboxes');
    return row.path;
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

  test('syncEmails full sync fetches messages and stores in DB', () async {
    final subject = 'jmap-full-${DateTime.now().millisecondsSinceEpoch}';
    await appendToInbox(subject);

    final r = makeRepo();
    final inboxId = await setupAndGetInboxId(r.db, r.accounts, r.mailboxes);
    await r.emails.syncEmails('test-jmap', inboxId);

    final emails = await r.emails.observeEmails('test-jmap', inboxId).first;
    expect(emails, hasLength(1));
    expect(emails.first.subject, subject);
    expect(emails.first.isSeen, isFalse);
  });

  test(
    'syncEmails saves state and incremental sync picks up new messages',
    () async {
      final r = makeRepo();
      final inboxId = await setupAndGetInboxId(r.db, r.accounts, r.mailboxes);

      await appendToInbox('first');
      await r.emails.syncEmails('test-jmap', inboxId);
      expect(
        await r.emails.observeEmails('test-jmap', inboxId).first,
        hasLength(1),
      );

      await appendToInbox('second');
      await r.emails.syncEmails('test-jmap', inboxId);
      final emails = await r.emails.observeEmails('test-jmap', inboxId).first;
      expect(emails, hasLength(2));
      expect(emails.map((e) => e.subject).toSet(), {'first', 'second'});
    },
  );

  test('syncEmails removes email deleted on server from local DB', () async {
    await appendToInbox('keep');
    await appendToInbox('delete-me');

    final r = makeRepo();
    final inboxId = await setupAndGetInboxId(r.db, r.accounts, r.mailboxes);
    await r.emails.syncEmails('test-jmap', inboxId);
    expect(
      await r.emails.observeEmails('test-jmap', inboxId).first,
      hasLength(2),
    );

    // Delete via IMAP directly on the server.
    final imap = await connectImap(env: env, user: user);
    try {
      await imap.selectMailboxByPath('INBOX');
      final search = await imap.uidSearchMessages(
        searchCriteria: 'SUBJECT "delete-me"',
      );
      final uids = search.matchingSequence?.toList() ?? [];
      final seq = MessageSequence.fromIds(uids, isUid: true);
      await imap.uidMarkDeleted(seq);
      await imap.uidExpunge(seq);
    } finally {
      await imap.logout();
    }

    await r.emails.syncEmails('test-jmap', inboxId);
    final remaining = await r.emails.observeEmails('test-jmap', inboxId).first;
    expect(remaining, hasLength(1));
    expect(remaining.first.subject, 'keep');
  });

  test('getEmailBody fetches and caches body via JMAP', () async {
    await appendToInbox('body-test', body: 'Hello from JMAP integration');

    final r = makeRepo();
    final inboxId = await setupAndGetInboxId(r.db, r.accounts, r.mailboxes);
    await r.emails.syncEmails('test-jmap', inboxId);

    final emails = await r.emails.observeEmails('test-jmap', inboxId).first;
    final emailId = emails.first.id;

    final body = await r.emails.getEmailBody(emailId);
    expect(body.textBody, contains('Hello from JMAP integration'));

    // Second call should hit the cache (no network error = cache used).
    final cached = await r.emails.getEmailBody(emailId);
    expect(cached.textBody, body.textBody);
  });

  test('getEmailBody(forceRefresh: true) bypasses cache via JMAP', () async {
    await appendToInbox('force-refresh', body: 'Force refresh body');

    final r = makeRepo();
    final inboxId = await setupAndGetInboxId(r.db, r.accounts, r.mailboxes);
    await r.emails.syncEmails('test-jmap', inboxId);

    final emails = await r.emails.observeEmails('test-jmap', inboxId).first;
    final emailId = emails.first.id;

    // Warm the cache, then artificially rewind `cachedAt` so a refresh
    // is observable via a strictly-newer timestamp on the second fetch.
    await r.emails.getEmailBody(emailId);
    final stale = DateTime.now().subtract(const Duration(hours: 1));
    await (r.db.update(r.db.emailBodies)
          ..where((t) => t.emailId.equals(emailId)))
        .write(EmailBodiesCompanion(cachedAt: Value(stale)));

    final refreshed = await r.emails.getEmailBody(emailId, forceRefresh: true);
    expect(refreshed.textBody, contains('Force refresh body'));

    final row = await (r.db.select(r.db.emailBodies)
          ..where((t) => t.emailId.equals(emailId)))
        .getSingle();
    expect(row.cachedAt!.isAfter(stale), isTrue);
  });

  test(
    'getEmailBody self-heals when cached row has null mimeTreeJson (JMAP)',
    () async {
      await appendToInbox('self-heal', body: 'Self-heal body');

      final r = makeRepo();
      final inboxId = await setupAndGetInboxId(r.db, r.accounts, r.mailboxes);
      await r.emails.syncEmails('test-jmap', inboxId);

      final emails = await r.emails.observeEmails('test-jmap', inboxId).first;
      final emailId = emails.first.id;

      // Simulate a row written by an older app version: textBody only, no
      // bodyStructure or headers, and the timestamp well within TTL.
      await r.db.into(r.db.emailBodies).insertOnConflictUpdate(
            EmailBodiesCompanion.insert(
              emailId: emailId,
              textBody: const Value('legacy text'),
              attachmentsJson: const Value('[]'),
              cachedAt: Value(DateTime.now()),
              // headersJson and mimeTreeJson deliberately left absent.
            ),
          );
      var row = await (r.db.select(r.db.emailBodies)
            ..where((t) => t.emailId.equals(emailId)))
          .getSingle();
      expect(row.mimeTreeJson, isNull);
      expect(row.headersJson, isNull);

      // A normal (non-forced) read should trigger a network fetch because
      // the cached row lacks mimeTreeJson, and persist the refreshed data.
      await r.emails.getEmailBody(emailId);

      row = await (r.db.select(r.db.emailBodies)
            ..where((t) => t.emailId.equals(emailId)))
          .getSingle();
      expect(row.mimeTreeJson, isNotNull);
      expect(row.headersJson, isNotNull);
    },
  );

  test(
    'sendEmail submits via JMAP EmailSubmission and creates Sent copy',
    () async {
      final subject = 'jmap-send-${DateTime.now().millisecondsSinceEpoch}';
      final r = makeRepo();
      await r.accounts.addAccount(account, user.password);
      await r.mailboxes.syncMailboxes('test-jmap');

      await r.emails.sendEmail(
        'test-jmap',
        EmailDraft(
          from: EmailAddress(name: user.email, email: user.email),
          to: [EmailAddress(name: user.email, email: user.email)],
          cc: [],
          subject: subject,
          body: 'Integration test message via JMAP',
        ),
      );

      // A sent copy should appear in the Sent mailbox.
      final sentRow = await (r.db.select(r.db.mailboxes)
            ..where(
              (t) => t.accountId.equals('test-jmap') & t.role.equals('sent'),
            )
            ..limit(1))
          .getSingleOrNull();
      final sentId = sentRow?.path;

      if (sentId != null) {
        await r.emails.syncEmails('test-jmap', sentId);
        final sentEmails =
            await r.emails.observeEmails('test-jmap', sentId).first;
        expect(sentEmails.any((e) => e.subject == subject), isTrue);
      } else {
        // If no Sent mailbox exists, just verify sendEmail didn't throw.
      }
    },
  );

  test('flushPendingChanges marks email as seen on server', () async {
    await appendToInbox('flag-test');

    final r = makeRepo();
    final inboxId = await setupAndGetInboxId(r.db, r.accounts, r.mailboxes);
    await r.emails.syncEmails('test-jmap', inboxId);

    final emails = await r.emails.observeEmails('test-jmap', inboxId).first;
    await r.emails.setFlag(emails.first.id, seen: true);
    await r.emails.flushPendingChanges('test-jmap', user.password);

    final client = await connectImap(env: env, user: user);
    try {
      await client.selectMailboxByPath('INBOX');
      final seen = await client.uidSearchMessages(searchCriteria: 'SEEN');
      expect(seen.matchingSequence?.toList() ?? [], isNotEmpty);
    } finally {
      await client.logout();
    }
  });

  test('flushPendingChanges deletes email from server', () async {
    await appendToInbox('delete-test');

    final r = makeRepo();
    final inboxId = await setupAndGetInboxId(r.db, r.accounts, r.mailboxes);
    await r.emails.syncEmails('test-jmap', inboxId);

    final emails = await r.emails.observeEmails('test-jmap', inboxId).first;
    await r.emails.deleteEmail(emails.first.id);
    await r.emails.flushPendingChanges('test-jmap', user.password);

    final client = await connectImap(env: env, user: user);
    try {
      final inbox = await client.selectMailboxByPath('INBOX');
      expect(inbox.messagesExists, 0);
    } finally {
      await client.logout();
    }
  });

  test('flushPendingChanges moves email to Trash on server', () async {
    await appendToInbox('move-test');

    final r = makeRepo();
    final inboxId = await setupAndGetInboxId(r.db, r.accounts, r.mailboxes);
    await r.emails.syncEmails('test-jmap', inboxId);

    // Find a destination mailbox (Trash).
    final trashRow = await (r.db.select(r.db.mailboxes)
          ..where(
            (t) => t.accountId.equals('test-jmap') & t.role.equals('trash'),
          )
          ..limit(1))
        .getSingleOrNull();
    if (trashRow == null) {
      markTestSkipped('No trash mailbox found on this Stalwart instance');
      return;
    }
    final trashId = trashRow.path;

    final emails = await r.emails.observeEmails('test-jmap', inboxId).first;
    await r.emails.moveEmail(emails.first.id, trashId);
    await r.emails.flushPendingChanges('test-jmap', user.password);

    // Re-sync both mailboxes to see updated state.
    await r.emails.syncEmails('test-jmap', inboxId);
    final inboxAfter = await r.emails.observeEmails('test-jmap', inboxId).first;
    expect(inboxAfter, isEmpty);

    await r.emails.syncEmails('test-jmap', trashId);
    final trashAfter = await r.emails.observeEmails('test-jmap', trashId).first;
    expect(trashAfter, isNotEmpty);
  });

  test('local Sieve star + keyword + fileinto reach the JMAP server', () async {
    await appendToInbox('Lunch on Friday');
    final r = makeRepo();
    final inboxId = await setupAndGetInboxId(r.db, r.accounts, r.mailboxes);
    final trash = await (r.db.select(r.db.mailboxes)
          ..where(
            (t) => t.accountId.equals('test-jmap') & t.role.equals('trash'),
          ))
        .getSingleOrNull();
    if (trash == null) {
      markTestSkipped('No trash mailbox found on this Stalwart instance');
      return;
    }
    await r.db.into(r.db.localSieveScripts).insert(
          LocalSieveScriptsCompanion.insert(
            accountId: 'test-jmap',
            name: 'lunch',
            content: Value('''
require ["fileinto", "imap4flags"];
if header :contains "subject" "lunch" {
  setflag "\\\\Flagged";
  addflag "Work";
  fileinto "${trash.name}";
}
'''),
            isActive: const Value(true),
          ),
        );
    await r.emails.syncEmails('test-jmap', inboxId);
    expect(await r.emails.applySieveRules('test-jmap'), 1);
    await r.emails.flushPendingChanges('test-jmap', user.password);
    expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);

    // Read the server truth over IMAP, as the flag_seen test above does.
    final client = await connectImap(env: env, user: user);
    addTearDown(client.logout);
    expect((await client.selectMailboxByPath('INBOX')).messagesExists, 0);
    await client.selectMailboxByPath(trash.name);
    final fetch =
        await client.fetchMessages(MessageSequence.fromAll(), 'FLAGS');
    final flags = (fetch.messages.single.flags ?? [])
        .map((f) => f.toLowerCase())
        .toList();
    expect(flags, containsAll([r'\flagged', 'work']));
    expect(flags, isNot(contains(r'\seen')));
  });

  test(
    'snooze on an account without a Snoozed mailbox creates it and lands '
    'the mail there with the snz keyword',
    () async {
      // A fresh JMAP account has no Snoozed folder. Drop one an earlier test
      // run may have left for this pool user.
      final setup = await connectImap(env: env, user: user);
      for (final box in await setup.listMailboxes()) {
        if (box.name == 'Snoozed') await setup.deleteMailbox(box);
      }
      await setup.logout();

      await appendToInbox('snooze-first');
      await appendToInbox('snooze-second');
      final r = makeRepo();
      final inboxId = await setupAndGetInboxId(r.db, r.accounts, r.mailboxes);
      await r.emails.syncEmails('test-jmap', inboxId);
      final inbox = await r.emails.observeEmails('test-jmap', inboxId).first;
      expect(inbox, hasLength(2));

      final until = DateTime.now().add(const Duration(days: 1));
      // Two snoozes before one flush: the second must reuse the mailbox the
      // first created rather than trip over the placeholder again.
      for (final e in inbox) {
        await r.emails.snoozeEmail(e.id, until);
      }
      await r.emails.flushPendingChanges('test-jmap', user.password);
      expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);

      final snoozedRows = await (r.db.select(r.db.mailboxes)
            ..where(
              (t) => t.accountId.equals('test-jmap') & t.name.equals('Snoozed'),
            ))
          .get();
      expect(snoozedRows, hasLength(1));
      final snoozedId = snoozedRows.single.path;
      expect(snoozedId, isNot('Snoozed'));
      final local = await (r.db.select(r.db.emails)
            ..where((t) => t.accountId.equals('test-jmap')))
          .get();
      expect(local.map((e) => e.mailboxPath).toSet(), {snoozedId});
      expect(await r.emails.isSnoozedMailbox('test-jmap', snoozedId), isTrue);

      final client = await connectImap(env: env, user: user);
      addTearDown(client.logout);
      expect((await client.selectMailboxByPath('INBOX')).messagesExists, 0);
      await client.selectMailboxByPath('Snoozed');
      final fetch =
          await client.fetchMessages(MessageSequence.fromAll(), 'FLAGS');
      expect(fetch.messages, hasLength(2));
      for (final m in fetch.messages) {
        expect(
          (m.flags ?? []).where((f) => f.toLowerCase().startsWith('snz:')),
          hasLength(1),
        );
      }
    },
  );

  // The batch Archive prompt's "Create "Archive"" must work for JMAP accounts
  // too: Mailbox/set creates the mailbox with role archive, and a move into it
  // reaches the server.
  test('createMailboxWithRole archive creates the mailbox and accepts a move',
      () async {
    // Drops any Archive left behind by an earlier run so the create below is
    // not refused as a duplicate name/role.
    Future<void> dropArchive(
      MailboxRepositoryImpl mailboxes,
      String accountId,
    ) async {
      final client = await connectImap(env: env, user: user);
      try {
        await clearMailbox(client, mailboxPath: 'Archive');
      } finally {
        await client.logout();
      }
      await mailboxes.syncMailboxes(accountId);
      final old = await mailboxes.findMailboxByRole(accountId, 'archive');
      if (old != null) await mailboxes.deleteMailbox(accountId, old.path);
    }

    await appendToInbox('archive-me');
    final r = makeRepo();
    final inboxId = await setupAndGetInboxId(r.db, r.accounts, r.mailboxes);
    await dropArchive(r.mailboxes, 'test-jmap');
    try {
      final archive = await r.mailboxes
          .createMailboxWithRole('test-jmap', 'Archive', 'archive');
      expect(archive.role, 'archive');
      expect(
        (await r.mailboxes.findMailboxByRole('test-jmap', 'archive'))?.path,
        archive.path,
      );

      await r.emails.syncEmails('test-jmap', inboxId);
      final inbox = await r.emails.observeEmails('test-jmap', inboxId).first;
      await r.emails.moveEmail(inbox.single.id, archive.path);
      await r.emails.flushPendingChanges('test-jmap', user.password);

      // The server, not just the local cache, has the role and the mail.
      await r.mailboxes.syncMailboxes('test-jmap');
      final synced =
          await r.mailboxes.findMailboxByRole('test-jmap', 'archive');
      expect(synced?.path, archive.path);
      await r.emails.syncEmails('test-jmap', inboxId);
      expect(
        await r.emails.observeEmails('test-jmap', inboxId).first,
        isEmpty,
      );
      await r.emails.syncEmails('test-jmap', archive.path);
      final archived =
          await r.emails.observeEmails('test-jmap', archive.path).first;
      expect(archived.map((e) => e.subject), ['archive-me']);
    } finally {
      await dropArchive(r.mailboxes, 'test-jmap');
    }
  });

  // "Projects/2026" typed into Move → Create new folder must give the same
  // tree as on IMAP: a top-level Projects with a child 2026 — not one
  // top-level mailbox literally named "Projects/2026" — and a second nested
  // create must reuse the existing Projects.
  test('createMailbox with "/" creates a nested JMAP hierarchy', () async {
    final r = makeRepo();
    await r.accounts.addAccount(account, user.password);

    Future<void> dropProjects() async {
      await r.mailboxes.syncMailboxes('test-jmap');
      final all = await r.mailboxes.observeMailboxes('test-jmap').first;
      final stale = all
          .where(
            (m) =>
                m.displayPath == 'Projects' ||
                m.displayPath.startsWith('Projects/'),
          )
          .toList()
        // Children first: JMAP refuses to destroy a mailbox with children.
        ..sort((a, b) => b.displayPath.length.compareTo(a.displayPath.length));
      for (final m in stale) {
        await r.mailboxes.deleteMailbox('test-jmap', m.path);
      }
    }

    await dropProjects();
    try {
      final leaf =
          await r.mailboxes.createMailbox('test-jmap', 'Projects/2026');
      expect(leaf.name, '2026');
      expect(leaf.displayPath, 'Projects/2026');

      // Re-read the server's view, not just the optimistic local rows.
      await r.mailboxes.syncMailboxes('test-jmap');
      var all = await r.mailboxes.observeMailboxes('test-jmap').first;
      final projects = all.where((m) => m.displayPath == 'Projects').toList();
      expect(projects, hasLength(1));
      expect(projects.single.name, 'Projects');
      expect(projects.single.parentId, isNull);
      final child = all.singleWhere((m) => m.path == leaf.path);
      expect(child.name, '2026');
      expect(child.parentId, projects.single.path);
      expect(child.displayPath, 'Projects/2026');
      expect(all.where((m) => m.name.contains('/')), isEmpty);

      final second =
          await r.mailboxes.createMailbox('test-jmap', 'Projects/2027');
      expect(second.parentId, projects.single.path);
      await r.mailboxes.syncMailboxes('test-jmap');
      all = await r.mailboxes.observeMailboxes('test-jmap').first;
      expect(all.where((m) => m.name == 'Projects'), hasLength(1));
      expect(
        all.singleWhere((m) => m.path == second.path).displayPath,
        'Projects/2027',
      );
    } finally {
      await dropProjects();
    }
  });

  // The user confirmed "Delete "X"? It contains N mails". Without
  // onDestroyRemoveEmails Stalwart answers mailboxHasEmail and nothing
  // happens; with it the folder and its own mail go, while a mail that is
  // also in INBOX only loses the deleted folder (RFC 8621 §2.5).
  test('deleteMailbox removes a JMAP folder that still contains mail',
      () async {
    final r = makeRepo();
    final inboxId = await setupAndGetInboxId(r.db, r.accounts, r.mailboxes);
    const folderName = 'DeleteWithMail';

    Future<void> dropFolder() async {
      await r.mailboxes.syncMailboxes('test-jmap');
      final all = await r.mailboxes.observeMailboxes('test-jmap').first;
      for (final m in all.where((m) => m.displayPath == folderName)) {
        await r.mailboxes
            .deleteMailbox('test-jmap', m.path, removeEmails: true);
      }
    }

    await dropFolder();
    final folder = await r.mailboxes.createMailbox('test-jmap', folderName);
    final jmap = await connectJmap(env: env, user: user);

    await appendToInbox('only-in-folder');
    await appendToInbox('in-both');
    final queried = await jmap.call([
      [
        'Email/query',
        {
          'accountId': jmap.accountId,
          'filter': {'inMailbox': inboxId},
        },
        'q',
      ],
      [
        'Email/get',
        {
          'accountId': jmap.accountId,
          '#ids': {'resultOf': 'q', 'name': 'Email/query', 'path': '/ids'},
          'properties': ['subject'],
        },
        'g',
      ],
    ]);
    final found = ((queried[1] as List)[1] as Map<String, dynamic>)['list']
        as List<dynamic>;
    final idBySubject = {
      for (final e in found.cast<Map<String, dynamic>>())
        e['subject'] as String: e['id'] as String,
    };
    final onlyId = idBySubject['only-in-folder']!;
    final bothId = idBySubject['in-both']!;
    await jmap.call([
      [
        'Email/set',
        {
          'accountId': jmap.accountId,
          'update': {
            onlyId: {
              'mailboxIds': {folder.path: true},
            },
            bothId: {'mailboxIds/${folder.path}': true},
          },
        },
        's',
      ],
    ]);
    await r.mailboxes.syncMailboxes('test-jmap');
    await r.emails.syncEmails('test-jmap', folder.path);
    expect(
      await r.emails.observeEmails('test-jmap', folder.path).first,
      isNotEmpty,
    );

    // Sync INBOX once now so the check after the delete goes through the
    // incremental Email/changes path, not a fresh full sync.
    await r.emails.syncEmails('test-jmap', inboxId);

    await r.mailboxes
        .deleteMailbox('test-jmap', folder.path, removeEmails: true);

    final localEmails = await (r.db.select(r.db.emails)
          ..where((t) => t.mailboxPath.equals(folder.path)))
        .get();
    expect(localEmails, isEmpty);
    await r.mailboxes.syncMailboxes('test-jmap');
    final all = await r.mailboxes.observeMailboxes('test-jmap').first;
    expect(all.where((m) => m.path == folder.path), isEmpty);

    final got = await jmap.call([
      [
        'Email/get',
        {
          'accountId': jmap.accountId,
          'ids': [onlyId, bothId],
          'properties': ['mailboxIds'],
        },
        'g',
      ],
    ]);
    final args = (got[0] as List)[1] as Map<String, dynamic>;
    expect(args['notFound'], [onlyId]);
    final survivor = (args['list'] as List).single as Map<String, dynamic>;
    expect(survivor['id'], bothId);
    expect((survivor['mailboxIds'] as Map).keys, [inboxId]);

    await r.emails.syncEmails('test-jmap', inboxId);
    final inbox = await r.emails.observeEmails('test-jmap', inboxId).first;
    expect(inbox.map((e) => e.subject), ['in-both']);
  });
}
