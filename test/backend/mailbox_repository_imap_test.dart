// Integration tests for MailboxRepositoryImpl against a real Stalwart instance.
// Run via: stalwart-dev/test.sh
//
// Uses a per-isolate pool user from stalwart_harness.dart so multiple test
// files can run in parallel.

import 'dart:io';

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

    // Without removeEmails (the dialog said "empty") the mail is kept.
    await expectLater(
      r.mailboxes.deleteMailbox('test', folder.path),
      throwsA(isA<Exception>()),
    );
    final kept = await r.mailboxes.observeMailboxes('test').first;
    expect(kept.map((m) => m.path), contains(folder.path));

    await r.mailboxes.deleteMailbox('test', folder.path, removeEmails: true);

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
    final cache = Directory.systemTemp.createTempSync('p5_imap_');
    addTearDown(() => cache.deleteSync(recursive: true));
    final emails = EmailRepositoryImpl(
      r.db,
      r.accounts,
      imapConnect: testImapConnect,
      getCacheDir: () async => cache,
    );
    await r.accounts.addAccount(account, user.password);
    const created = 'P5Offline';
    const renamed = 'P5Renamed';

    Future<void> dropFolders() async {
      await r.mailboxes.syncMailboxes('test');
      final all = await r.mailboxes.observeMailboxes('test').first;
      for (final m in all.where(
        (m) => m.name == created || m.name == renamed,
      )) {
        await r.mailboxes.deleteMailbox('test', m.path, removeEmails: true);
      }
    }

    await dropFolders();
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
      await dropFolders();
    }
  });
}
