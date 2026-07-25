// Integration tests for DraftRepositoryImpl's IMAP sync against a real
// Stalwart instance. Closes #331 for the IMAP path.
//
// Run via: stalwart-dev/test.sh

import 'package:drift/drift.dart' show Value;
import 'package:enough_mail/enough_mail.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/draft_repository_impl.dart';
import 'package:test/test.dart';

import '../unit/account_repository_impl_test.dart' show MapSecureStorage;
import '../unit/db_test_helper.dart';
import 'stalwart_harness.dart';

const _draftsFolder = 'Drafts';

Future<int> _serverDraftCount(StalwartEnv env, StalwartTestUser user) async {
  final client = await connectImap(env: env, user: user);
  try {
    try {
      final box = await client.selectMailboxByPath(_draftsFolder);
      if (box.messagesExists == 0) return 0;
    } catch (_) {
      return 0;
    }
    final result = await client.uidSearchMessages(searchCriteria: 'NOT DELETED');
    return (result.matchingSequence?.toList() ?? const <int>[]).length;
  } finally {
    await client.logout();
  }
}

Future<List<MimeMessage>> _fetchServerDrafts(
  StalwartEnv env,
  StalwartTestUser user,
) async {
  final client = await connectImap(env: env, user: user);
  try {
    try {
      await client.selectMailboxByPath(_draftsFolder);
    } catch (_) {
      return const [];
    }
    final search =
        await client.uidSearchMessages(searchCriteria: 'NOT DELETED');
    final uids = search.matchingSequence?.toList() ?? const <int>[];
    if (uids.isEmpty) return const [];
    final seq = MessageSequence.fromIds(uids, isUid: true);
    final fetch =
        await client.uidFetchMessages(seq, '(UID FLAGS ENVELOPE BODY.PEEK[])');
    return fetch.messages;
  } finally {
    await client.logout();
  }
}

Future<void> _appendServerDraft(
  StalwartEnv env,
  StalwartTestUser user, {
  required String subject,
  required String body,
}) async {
  final client = await connectImap(env: env, user: user);
  try {
    try {
      await client.createMailbox(_draftsFolder);
    } catch (_) {
      // Already exists.
    }
    await client.selectMailboxByPath(_draftsFolder);
    final msg = MessageBuilder()
      ..from = [MailAddress(user.email, user.email)]
      ..to = [MailAddress(user.email, user.email)]
      ..subject = subject
      ..text = body;
    await client.appendMessage(
      msg.buildMimeMessage(),
      targetMailboxPath: _draftsFolder,
      flags: [r'\Draft'],
    );
  } finally {
    await client.logout();
  }
}

Future<void> _clearServerDrafts(StalwartEnv env, StalwartTestUser user) async {
  final client = await connectImap(env: env, user: user);
  try {
    await clearMailbox(client, mailboxPath: _draftsFolder);
  } finally {
    await client.logout();
  }
}

void main() {
  late StalwartEnv env;
  late StalwartTestUser user;
  late Account account;

  setUpAll(() {
    configureSqliteForTests();
    env = StalwartEnv.fromPlatform();
    user = pickPoolUser(env: env);
    account = user.imapAccount(id: 'draft-imap', env: env);
  });

  setUp(() async {
    await _clearServerDrafts(env, user);
  });

  ({
    AppDatabase db,
    AccountRepositoryImpl accounts,
    DraftRepositoryImpl drafts,
  }) makeRepo() {
    final db = openTestDatabase();
    final accounts = AccountRepositoryImpl(db, MapSecureStorage());
    final drafts = DraftRepositoryImpl(
      db,
      accounts,
      imapConnect: testImapConnect,
    );
    return (db: db, accounts: accounts, drafts: drafts);
  }

  test('saveDraft + syncDrafts pushes new draft into server Drafts folder',
      () async {
    final r = makeRepo();
    await r.accounts.addAccount(account, user.password);
    final subject = 'imap-new-${DateTime.now().millisecondsSinceEpoch}';

    await r.drafts.saveDraft(
      accountId: account.id,
      toText: user.email,
      ccText: '',
      subjectText: subject,
      bodyText: 'Hello from draft sync',
    );
    await r.drafts.syncDrafts(account.id);

    final serverMessages = await _fetchServerDrafts(env, user);
    expect(serverMessages, hasLength(1));
    expect(serverMessages.single.envelope?.subject, subject);
    expect(serverMessages.single.flags, contains(r'\Draft'));
  });

  test('syncDrafts records the server UID and clears dirty on the local row',
      () async {
    final r = makeRepo();
    await r.accounts.addAccount(account, user.password);
    final saved = await r.drafts.saveDraft(
      accountId: account.id,
      toText: user.email,
      ccText: '',
      subjectText: 'imap-uid-${DateTime.now().millisecondsSinceEpoch}',
      bodyText: 'body',
    );
    await r.drafts.syncDrafts(account.id);

    final row = await r.drafts.getDraft(saved.id);
    expect(row, isNotNull);
    expect(row!.dirty, isFalse);
    expect(row.imapServerId, isNotNull);
    expect(int.tryParse(row.imapServerId!), isNotNull);
  });

  test(
    'editing a synced draft replaces the server copy (old UID removed)',
    () async {
      final r = makeRepo();
      await r.accounts.addAccount(account, user.password);
      final saved = await r.drafts.saveDraft(
        accountId: account.id,
        toText: user.email,
        ccText: '',
        subjectText: 'imap-edit-original',
        bodyText: 'first',
      );
      await r.drafts.syncDrafts(account.id);
      final firstRow = (await r.drafts.getDraft(saved.id))!;
      final firstUid = firstRow.imapServerId;

      // Edit the draft. saveDraft flips dirty back to true.
      await r.drafts.saveDraft(
        id: saved.id,
        accountId: account.id,
        toText: user.email,
        ccText: '',
        subjectText: 'imap-edit-updated',
        bodyText: 'second',
      );
      await r.drafts.syncDrafts(account.id);

      final serverMessages = await _fetchServerDrafts(env, user);
      expect(serverMessages, hasLength(1),
          reason: 'Old copy should be expunged when a new copy is APPENDed');
      expect(serverMessages.single.envelope?.subject, 'imap-edit-updated');

      final secondRow = (await r.drafts.getDraft(saved.id))!;
      expect(secondRow.dirty, isFalse);
      expect(secondRow.imapServerId, isNotNull);
      expect(secondRow.imapServerId, isNot(firstUid));
    },
  );

  test('syncDrafts pulls a server-only draft into the local table', () async {
    final r = makeRepo();
    await r.accounts.addAccount(account, user.password);

    await _appendServerDraft(
      env,
      user,
      subject: 'imap-server-only',
      body: 'from webmail',
    );

    await r.drafts.syncDrafts(account.id);

    final rows = await (r.db.select(r.db.drafts)
          ..where((t) => t.accountId.equals(account.id)))
        .get();
    expect(rows, hasLength(1));
    expect(rows.single.subjectText, 'imap-server-only');
    expect(rows.single.bodyText, contains('from webmail'));
    expect(rows.single.imapServerId, isNotNull);
    expect(rows.single.dirty, isFalse);
  });

  test(
    'deleteDraft writes a tombstone and syncDrafts removes the server copy',
    () async {
      final r = makeRepo();
      await r.accounts.addAccount(account, user.password);
      final saved = await r.drafts.saveDraft(
        accountId: account.id,
        toText: user.email,
        ccText: '',
        subjectText: 'imap-delete-me',
        bodyText: 'body',
      );
      await r.drafts.syncDrafts(account.id);
      expect(await _serverDraftCount(env, user), 1);

      await r.drafts.deleteDraft(saved.id);
      final tombstones = await r.db.select(r.db.draftTombstones).get();
      expect(tombstones, hasLength(1));

      await r.drafts.syncDrafts(account.id);

      expect(await _serverDraftCount(env, user), 0);
      final remainingTombstones =
          await r.db.select(r.db.draftTombstones).get();
      expect(remainingTombstones, isEmpty);
    },
  );

  test(
    'syncDrafts drops local rows whose server copy has disappeared',
    () async {
      final r = makeRepo();
      await r.accounts.addAccount(account, user.password);
      final saved = await r.drafts.saveDraft(
        accountId: account.id,
        toText: user.email,
        ccText: '',
        subjectText: 'imap-vanish',
        bodyText: 'body',
      );
      await r.drafts.syncDrafts(account.id);
      expect(await r.drafts.getDraft(saved.id), isNotNull);

      // Simulate deletion happening on another device / in webmail.
      await _clearServerDrafts(env, user);

      await r.drafts.syncDrafts(account.id);

      expect(await r.drafts.getDraft(saved.id), isNull);
    },
  );

  test('syncDrafts does not push tombstones for unsynced drafts', () async {
    final r = makeRepo();
    await r.accounts.addAccount(account, user.password);
    final saved = await r.drafts.saveDraft(
      accountId: account.id,
      toText: user.email,
      ccText: '',
      subjectText: 'imap-local-only',
      bodyText: 'body',
    );

    // Delete before it was ever pushed — no tombstone should be created.
    await r.drafts.deleteDraft(saved.id);

    final tombstones = await r.db.select(r.db.draftTombstones).get();
    expect(tombstones, isEmpty);

    // A sync cycle should be a no-op on the server side.
    await r.drafts.syncDrafts(account.id);
    expect(await _serverDraftCount(env, user), 0);
  });

  test(
    'sync round trip: push then a fresh DB pulls the same draft down',
    () async {
      final r1 = makeRepo();
      await r1.accounts.addAccount(account, user.password);
      final subject = 'imap-roundtrip-${DateTime.now().millisecondsSinceEpoch}';
      await r1.drafts.saveDraft(
        accountId: account.id,
        toText: user.email,
        ccText: '',
        subjectText: subject,
        bodyText: 'roundtrip body',
      );
      await r1.drafts.syncDrafts(account.id);

      // Second device / fresh DB pulling the same server draft.
      final r2 = makeRepo();
      await r2.accounts.addAccount(account, user.password);
      await r2.drafts.syncDrafts(account.id);

      final rows = await (r2.db.select(r2.db.drafts)
            ..where((t) => t.accountId.equals(account.id)))
          .get();
      expect(rows, hasLength(1));
      expect(rows.single.subjectText, subject);
      expect(rows.single.bodyText, contains('roundtrip body'));
    },
  );

  test('local dirty rows are not clobbered by pull reconciliation', () async {
    final r = makeRepo();
    await r.accounts.addAccount(account, user.password);
    final saved = await r.drafts.saveDraft(
      accountId: account.id,
      toText: user.email,
      ccText: '',
      subjectText: 'imap-dirty-guard',
      bodyText: 'body',
    );
    // Simulate: had a server UID, then the server copy disappeared, but the
    // user just edited the row locally (dirty=true, imapServerId still set).
    await (r.db.update(r.db.drafts)..where((t) => t.id.equals(saved.id)))
        .write(const DraftsCompanion(
      imapServerId: Value('99999'),
      dirty: Value(true),
    ));

    await r.drafts.syncDrafts(account.id);

    // The dirty local row must still exist — it will be re-appended.
    final row = await r.drafts.getDraft(saved.id);
    expect(row, isNotNull);
    expect(row!.dirty, isFalse);
    expect(row.imapServerId, isNot('99999'));
  });
}
