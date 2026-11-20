// Integration tests for MailboxRepositoryImpl against a real Stalwart instance.
// Run via: stalwart-dev/test.sh
//
// Uses a per-isolate pool user from stalwart_harness.dart so multiple test
// files can run in parallel.

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';
import 'package:test/test.dart';

import '../unit/account_repository_impl_test.dart' show MapSecureStorage;
import '../unit/db_test_helper.dart';
import 'stalwart_harness.dart';

void main() {
  late StalwartEnv env;
  late StalwartTestUser user;
  late Account account;

  setUpAll(() {
    configureSqliteForTests();
    env = StalwartEnv.fromPlatform();
    user = pickPoolUser(env: env);
    account = user.imapAccount(id: 'test', env: env);
  });

  setUp(() => clearStandardMailboxes(env: env, user: user));

  ({
    AppDatabase db,
    AccountRepositoryImpl accounts,
    MailboxRepositoryImpl mailboxes,
  }) makeRepo() {
    final db = openTestDatabase();
    final accounts = AccountRepositoryImpl(db, MapSecureStorage());
    final mailboxes = MailboxRepositoryImpl(
      db,
      accounts,
      imapConnect: testImapConnect,
    );
    return (db: db, accounts: accounts, mailboxes: mailboxes);
  }

  // The flush a sync cycle starts with: the queued folder ops first.
  Future<void> flush(
    ({
      AppDatabase db,
      AccountRepositoryImpl accounts,
      MailboxRepositoryImpl mailboxes,
    }) r,
  ) =>
      EmailRepositoryImpl(r.db, r.accounts, imapConnect: testImapConnect)
          .flushPendingChanges('test', user.password);

  // An email repository on [r]'s database, with a temporary cache folder.
  EmailRepositoryImpl emailsOf(
    ({
      AppDatabase db,
      AccountRepositoryImpl accounts,
      MailboxRepositoryImpl mailboxes,
    }) r,
  ) {
    final cache = Directory.systemTemp.createTempSync('mailbox_imap_');
    addTearDown(() => cache.deleteSync(recursive: true));
    return EmailRepositoryImpl(
      r.db,
      r.accounts,
      imapConnect: testImapConnect,
      getCacheDir: () async => cache,
    );
  }

  // Deletes the folders called one of [names] an earlier run left (with
  // their mail, subfolders first) and flushes: deletes are queued.
  Future<void> dropFolders(
    ({
      AppDatabase db,
      AccountRepositoryImpl accounts,
      MailboxRepositoryImpl mailboxes,
    }) r,
    Set<String> names,
  ) async {
    await r.mailboxes.syncMailboxes('test');
    final stale = (await r.mailboxes.observeMailboxes('test').first)
        .where((m) => names.contains(m.name))
        .toList()
      ..sort((a, b) => b.displayPath.length.compareTo(a.displayPath.length));
    for (final m in stale) {
      await r.mailboxes.deleteMailbox('test', m.path, removeEmails: true);
    }
    await flush(r);
  }

  test('syncMailboxes stores mailboxes from IMAP in DB', () async {
    final r = makeRepo();
    await r.accounts.addAccount(account, user.password);
    await r.mailboxes.syncMailboxes('test');

    final mailboxes = await r.mailboxes.observeMailboxes('test').first;
    expect(mailboxes, isNotEmpty);
    expect(mailboxes.map((m) => m.path), contains('INBOX'));
  });

  test('syncMailboxes populates unread and total counts', () async {
    // Append a message so INBOX has at least 1 unseen message.
    final client = await connectImap(env: env, user: user);
    try {
      await appendMessage(
        client,
        subject: 'count-test',
        userEmail: user.email,
      );
    } finally {
      await client.logout();
    }

    final r = makeRepo();
    await r.accounts.addAccount(account, user.password);
    await r.mailboxes.syncMailboxes('test');

    final mailboxes = await r.mailboxes.observeMailboxes('test').first;
    final inbox = mailboxes.firstWhere((m) => m.path == 'INBOX');
    expect(inbox.totalCount, greaterThan(0));
    expect(inbox.unreadCount, greaterThan(0));
  });

  // Same input as the JMAP test in email_repository_jmap_test.dart: a "/" in
  // the typed name is a hierarchy separator, so both protocols end up with
  // Projects containing 2026.
  test('createMailbox with "/" creates a nested IMAP folder', () async {
    final r = makeRepo();
    await r.accounts.addAccount(account, user.password);

    Future<void> dropProjects() async {
      await r.mailboxes.syncMailboxes('test');
      final all = await r.mailboxes.observeMailboxes('test').first;
      final stale = all
          .where(
            (m) =>
                m.displayPath == 'Projects' ||
                m.displayPath.startsWith('Projects/'),
          )
          .toList()
        ..sort((a, b) => b.displayPath.length.compareTo(a.displayPath.length));
      for (final m in stale) {
        await r.mailboxes.deleteMailbox('test', m.path);
      }
      // Deletes are queued (phase 5b): the flush sends them.
      await flush(r);
    }

    await dropProjects();
    try {
      final leaf = await r.mailboxes.createMailbox('test', 'Projects/2026');
      expect(leaf.name, '2026');
      expect(leaf.displayPath, 'Projects/2026');
      await flush(r);

      await r.mailboxes.syncMailboxes('test');
      final all = await r.mailboxes.observeMailboxes('test').first;
      expect(all.where((m) => m.displayPath == 'Projects'), hasLength(1));
      final child = all.singleWhere((m) => m.displayPath == 'Projects/2026');
      expect(child.name, '2026');
    } finally {
      await dropProjects();
    }
  });

  test('deleteMailbox removes an IMAP folder that still contains mail',
      () async {
    final r = makeRepo();
    await r.accounts.addAccount(account, user.password);
    const folderName = 'DeleteWithMail';

    Future<void> dropFolder() async {
      await r.mailboxes.syncMailboxes('test');
      final all = await r.mailboxes.observeMailboxes('test').first;
      for (final m in all.where((m) => m.displayPath == folderName)) {
        await r.mailboxes.deleteMailbox('test', m.path, removeEmails: true);
      }
      await flush(r);
    }

    await dropFolder();
    final folder = await r.mailboxes.createMailbox('test', folderName);
    await flush(r);
    final client = await connectImap(env: env, user: user);
    try {
      await appendMessage(
        client,
        subject: 'doomed',
        userEmail: user.email,
        mailboxPath: folder.path,
      );
    } finally {
      await client.logout();
    }
    await r.mailboxes.syncMailboxes('test');
    await r.db.into(r.db.emails).insert(
          EmailsCompanion.insert(
            id: 'test:${folder.path}:1',
            accountId: 'test',
            mailboxPath: folder.path,
            uid: 1,
            receivedAt: DateTime.now(),
          ),
        );

    // Without removeEmails (the dialog said "empty") the mail is kept: the
    // queued delete is refused by the flush, a failed change, and the
    // folder shows again.
    await r.mailboxes.deleteMailbox('test', folder.path);
    await flush(r);
    final refused = await r.db.select(r.db.pendingChanges).getSingle();
    expect((refused.changeType, refused.state), ('delete_mailbox', 'failed'));
    final kept = await r.mailboxes.observeMailboxes('test').first;
    expect(kept.map((m) => m.path), contains(folder.path));

    await r.mailboxes.deleteMailbox('test', folder.path, removeEmails: true);
    await flush(r);

    final local = await (r.db.select(r.db.emails)
          ..where((t) => t.mailboxPath.equals(folder.path)))
        .get();
    expect(local, isEmpty);
    await r.mailboxes.syncMailboxes('test');
    final all = await r.mailboxes.observeMailboxes('test').first;
    expect(all.where((m) => m.displayPath == folderName), isEmpty);

    final check = await connectImap(env: env, user: user);
    try {
      final boxes = await check.listMailboxes();
      expect(boxes.where((b) => b.name == folderName), isEmpty);
    } finally {
      await check.logout();
    }
  });

  // #1242 on IMAP: a folder created offline takes a move and a rename at
  // once; the flush creates it, RENAMEs it and moves the mail into it, in
  // that order. Its mail and the folder row keep their ids.
  test(
      'offline: create a folder, move a mail into it and rename it; the '
      'flush does all three on the server', () async {
    final r = makeRepo();
    final emails = emailsOf(r);
    await r.accounts.addAccount(account, user.password);
    const created = 'P5Offline';
    const renamed = 'P5Renamed';
    Future<void> drop() => dropFolders(r, const {created, renamed});

    await drop();
    try {
      final client = await connectImap(env: env, user: user);
      try {
        await appendMessage(client, subject: 'p5-imap', userEmail: user.email);
      } finally {
        await client.logout();
      }
      await emails.syncEmails('test', 'INBOX');
      final mail = (await emails.observeEmails('test', 'INBOX').first).single;

      final folder = await r.mailboxes.createMailbox('test', created);
      await emails.moveEmail(mail.id, folder.path);
      final shown =
          await r.mailboxes.renameMailbox('test', folder.path, renamed);
      expect((shown.name, shown.displayPath), (renamed, renamed));

      await emails.flushPendingChanges('test', user.password);

      final check = await connectImap(env: env, user: user);
      try {
        final box = await check.selectMailboxByPath(renamed);
        expect(box.messagesExists, 1);
        final boxes = await check.listMailboxes();
        expect(boxes.where((b) => b.name == created), isEmpty);
      } finally {
        await check.logout();
      }
      final row = (await r.mailboxes.observeMailboxes('test').first)
          .singleWhere((m) => m.id == folder.id);
      expect((row.path, row.name), (renamed, renamed));
      expect((await emails.getEmail(mail.id))!.mailboxPath, renamed);

      await r.mailboxes.syncMailboxes('test');
      await emails.syncEmails('test', renamed);
      expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);
    } finally {
      await drop();
    }
  });
  // #1242 phase 5b on IMAP: offline, a folder is moved below another and a
  // second one is deleted after its mail was moved out. The flush sends the
  // move (RENAME, the folder's mail follows), the mail move, then the
  // DELETE, in that order; no mail is lost.
  test(
      'offline: move a folder, move the mail out of another and delete it; '
      'the flush does it all on the server', () async {
    final r = makeRepo();
    final emails = emailsOf(r);
    await r.accounts.addAccount(account, user.password);
    const parent = 'P5bParent';
    const moved = 'P5bMoved';
    const doomed = 'P5bDoomed';
    Future<void> drop() => dropFolders(r, const {parent, moved, doomed});

    await drop();
    try {
      final client = await connectImap(env: env, user: user);
      try {
        for (final f in const [parent, moved, doomed]) {
          await client.createMailbox(f);
        }
        await appendMessage(
          client,
          subject: 'p5b-in-moved',
          userEmail: user.email,
          mailboxPath: moved,
        );
        await appendMessage(
          client,
          subject: 'p5b-rescued',
          userEmail: user.email,
          mailboxPath: doomed,
        );
      } finally {
        await client.logout();
      }
      await r.mailboxes.syncMailboxes('test');
      await emails.syncEmails('test', moved);
      await emails.syncEmails('test', doomed);
      final inMoved = (await emails.observeEmails('test', moved).first).single;
      final rescued = (await emails.observeEmails('test', doomed).first).single;
      final movedRow = (await r.mailboxes.observeMailboxes('test').first)
          .singleWhere((m) => m.path == moved);

      final shown = await r.mailboxes
          .moveMailbox('test', moved, newParentDisplayPath: parent);
      expect(shown.displayPath, '$parent/$moved');
      await emails.moveEmail(rescued.id, 'INBOX');
      await r.mailboxes.deleteMailbox('test', doomed);
      expect(
        (await r.mailboxes.observeMailboxes('test').first).map((m) => m.path),
        isNot(contains(doomed)),
      );

      await flush(r);

      final check = await connectImap(env: env, user: user);
      try {
        final boxes = (await check.listMailboxes(recursive: true))
            .map((b) => b.path)
            .toList();
        expect(boxes, contains('$parent/$moved'));
        expect(boxes, isNot(contains(moved)));
        expect(boxes, isNot(contains(doomed)));
        final box = await check.selectMailboxByPath('$parent/$moved');
        expect(box.messagesExists, 1);
      } finally {
        await check.logout();
      }
      final row = (await r.mailboxes.observeMailboxes('test').first)
          .singleWhere((m) => m.id == movedRow.id);
      expect(row.path, '$parent/$moved');
      final mail = (await emails.getEmail(inMoved.id))!;
      expect(mail.mailboxPath, '$parent/$moved');
      expect((await emails.getEmail(rescued.id))!.mailboxPath, 'INBOX');

      await r.mailboxes.syncMailboxes('test');
      await emails.syncEmails('test', 'INBOX');
      await emails.syncEmails('test', '$parent/$moved');
      expect(
        await (r.db.select(r.db.pendingChanges)
              ..where((t) => t.state.isIn(const ['acked']).not()))
            .get(),
        isEmpty,
      );
      final inbox = await emails.observeEmails('test', 'INBOX').first;
      expect(inbox.map((e) => e.subject), contains('p5b-rescued'));
    } finally {
      await drop();
    }
  });

  // Another client (its own IMAP session) renames folder [from] to [to].
  Future<void> renameElsewhere(String from, String to) async {
    final other = await connectImap(env: env, user: user);
    try {
      final box =
          (await other.listMailboxes()).singleWhere((b) => b.path == from);
      await other.renameMailbox(box, to);
    } finally {
      await other.logout();
    }
  }

  // The one move queued in [r] names [path] and is pending; the flush sends
  // it, and the server's [path] then holds [messages] mails.
  Future<void> expectMoveFollows(
    ({
      AppDatabase db,
      AccountRepositoryImpl accounts,
      MailboxRepositoryImpl mailboxes,
    }) r,
    String path, {
    required int messages,
  }) async {
    final move = await (r.db.select(r.db.pendingChanges)
          ..where((t) => t.changeType.equals('move')))
        .getSingle();
    expect(move.state, 'pending');
    expect(move.payload, contains('"dest":"$path"'));

    await flush(r);
    final check = await connectImap(env: env, user: user);
    try {
      final box = await check.selectMailboxByPath(path);
      expect(box.messagesExists, messages);
    } finally {
      await check.logout();
    }
  }

  // A folder another client renames lists as one gone and one new. Stalwart
  // gives the renamed folder a new UIDVALIDITY but keeps its RFC 8474
  // MAILBOXID (OBJECTID), so the listing recognises it by that id (#1315;
  // before, by the Message-IDs it holds), and a move queued into it follows
  // instead of failing (phase 5b).
  test('a folder another client renames: a move queued into it follows',
      () async {
    final r = makeRepo();
    final emails = emailsOf(r);
    await r.accounts.addAccount(account, user.password);
    const before = 'P5bWork';
    const after = 'P5bJob';
    Future<void> drop() => dropFolders(r, const {before, after});

    await drop();
    try {
      final client = await connectImap(env: env, user: user);
      try {
        await client.createMailbox(before);
        await appendMessage(
          client,
          subject: 'p5b-rn-in-work',
          userEmail: user.email,
          mailboxPath: before,
        );
        await appendMessage(client, subject: 'p5b-rn', userEmail: user.email);
      } finally {
        await client.logout();
      }
      await r.mailboxes.syncMailboxes('test');
      await emails.syncEmails('test', before);
      await emails.syncEmails('test', 'INBOX');
      final mail = (await emails.observeEmails('test', 'INBOX').first)
          .singleWhere((e) => e.subject == 'p5b-rn');
      final folder = (await r.mailboxes.observeMailboxes('test').first)
          .singleWhere((m) => m.path == before);
      await emails.moveEmail(mail.id, before);

      // Another client renames the folder before our flush.
      await renameElsewhere(before, after);
      await r.mailboxes.syncMailboxes('test');

      final row = (await r.mailboxes.observeMailboxes('test').first)
          .singleWhere((m) => m.id == folder.id);
      expect(row.path, after);
      await expectMoveFollows(r, after, messages: 2);
    } finally {
      await drop();
    }
  });

  // #1315: an empty folder another client renames and moves at once (neither
  // its leaf nor its parent stay), under a new UIDVALIDITY: only its
  // MAILBOXID can tell, and the move queued into it follows.
  test(
      'an empty folder another client renames and moves at once is followed '
      'by its MAILBOXID', () async {
    final r = makeRepo();
    final emails = emailsOf(r);
    await r.accounts.addAccount(account, user.password);
    const before = 'M1315Empty';
    const parent = 'M1315Box';
    const after = '$parent/M1315Moved';
    Future<void> drop() => dropFolders(r, const {before, parent, 'M1315Moved'});

    await drop();
    try {
      final client = await connectImap(env: env, user: user);
      try {
        await client.createMailbox(before);
        await client.createMailbox(parent);
        await appendMessage(client, subject: 'm1315', userEmail: user.email);
      } finally {
        await client.logout();
      }
      await r.mailboxes.syncMailboxes('test');
      await emails.syncEmails('test', 'INBOX');
      final row = await (r.db.select(r.db.mailboxes)
            ..where((t) => t.path.equals(before)))
          .getSingle();
      expect(row.srvMailboxId, isNotNull, reason: 'Stalwart has OBJECTID');
      final mail = (await emails.observeEmails('test', 'INBOX').first)
          .singleWhere((e) => e.subject == 'm1315');
      await emails.moveEmail(mail.id, before);

      await renameElsewhere(before, after);
      await r.mailboxes.syncMailboxes('test');

      final moved = await (r.db.select(r.db.mailboxes)
            ..where((t) => t.id.equals(row.id)))
          .getSingle();
      expect((moved.path, moved.srvMailboxId), (after, row.srvMailboxId));
      await expectMoveFollows(r, after, messages: 1);
      await emails.syncEmails('test', after);
      expect(
        (await emails.observeEmails('test', after).first).map((e) => e.id),
        [mail.id],
      );
    } finally {
      await drop();
    }
  });

  // #1312: a SELECT error removes a folder only on a definite answer. The
  // folder another client deleted between the listing and its SELECT is
  // removed with its mail (Stalwart answers NONEXISTENT, or the LIST does
  // not have it); every other folder, and its mail, stays.
  test('a folder deleted elsewhere before its SELECT is removed, nothing else',
      () async {
    final r = makeRepo();
    final emails = emailsOf(r);
    await r.accounts.addAccount(account, user.password);
    const gone = 'G1312Gone';
    const kept = 'G1312Kept';
    Future<void> drop() => dropFolders(r, const {gone, kept});

    await drop();
    try {
      final client = await connectImap(env: env, user: user);
      try {
        for (final path in [gone, kept]) {
          await client.createMailbox(path);
          await appendMessage(
            client,
            subject: 'g1312-$path',
            userEmail: user.email,
            mailboxPath: path,
          );
        }
      } finally {
        await client.logout();
      }
      await r.mailboxes.syncMailboxes('test');
      await emails.syncEmails('test', gone);
      await emails.syncEmails('test', kept);

      final other = await connectImap(env: env, user: user);
      try {
        final box =
            (await other.listMailboxes()).singleWhere((b) => b.path == gone);
        await other.deleteMailbox(box);
      } finally {
        await other.logout();
      }

      final result = await emails.syncEmails('test', gone);
      expect(result.fetched, 0);
      final paths = [
        for (final m in await r.mailboxes.observeMailboxes('test').first)
          m.path,
      ];
      expect(paths, isNot(contains(gone)));
      expect(paths, containsAll(['INBOX', kept]));
      final subjects = [
        for (final e in await r.db.select(r.db.emails).get()) e.subject,
      ];
      expect(subjects, isNot(contains('g1312-$gone')));
      expect(subjects, contains('g1312-$kept'));

      // The next listing agrees and removes nothing more.
      await r.mailboxes.syncMailboxes('test');
      expect(
        [
          for (final m in await r.mailboxes.observeMailboxes('test').first)
            m.path,
        ],
        containsAll(['INBOX', kept]),
      );
    } finally {
      await drop();
    }
  });
}
