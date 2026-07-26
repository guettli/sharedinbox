// Integration tests for DraftRepositoryImpl's two-way sync against a real
// Stalwart instance. Closes #331. Covers both IMAP and JMAP paths in one
// file so shared setup and server-round-trip helpers don't need to be
// duplicated between per-protocol suites.
//
// Run via: stalwart-dev/test.sh

import 'package:enough_mail/enough_mail.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/jmap/jmap_client.dart';
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/draft_repository_impl.dart';
import 'package:test/test.dart';

import '../unit/account_repository_impl_test.dart' show MapSecureStorage;
import '../unit/db_test_helper.dart';
import 'localhost_mapping_client.dart';
import 'stalwart_harness.dart';

const _draftsFolder = 'Drafts';

// ── Server-side helpers used by both suites ──────────────────────────────

Future<int> _serverDraftCountImap(
  StalwartEnv env,
  StalwartTestUser user,
) async {
  final client = await connectImap(env: env, user: user);
  try {
    try {
      final box = await client.selectMailboxByPath(_draftsFolder);
      if (box.messagesExists == 0) return 0;
    } catch (_) {
      return 0;
    }
    final result =
        await client.uidSearchMessages(searchCriteria: 'NOT DELETED');
    return (result.matchingSequence?.toList() ?? const <int>[]).length;
  } finally {
    await client.logout();
  }
}

Future<List<MimeMessage>> _fetchServerDraftsImap(
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

Future<void> _appendServerDraftImap(
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

Future<void> _clearServerDraftsImap(
  StalwartEnv env,
  StalwartTestUser user,
) async {
  final client = await connectImap(env: env, user: user);
  try {
    await clearMailbox(client, mailboxPath: _draftsFolder);
  } finally {
    await client.logout();
  }
}

Future<String?> _findDraftsMailboxIdJmap(JmapClient jmap) async {
  final resp = await jmap.call([
    [
      'Mailbox/get',
      {'accountId': jmap.accountId, 'ids': null},
      '0',
    ],
  ]);
  final triple = resp[0] as List<dynamic>;
  final args = triple[1] as Map<String, dynamic>;
  final list = args['list'] as List<dynamic>;
  for (final mailbox in list) {
    final map = mailbox as Map<String, dynamic>;
    if (map['role'] == 'drafts' || map['name'] == _draftsFolder) {
      return map['id'] as String?;
    }
  }
  return null;
}

Future<List<Map<String, dynamic>>> _fetchServerDraftsJmap(
  JmapClient jmap,
  String mailboxId,
) async {
  final queryResp = await jmap.call([
    [
      'Email/query',
      {
        'accountId': jmap.accountId,
        'filter': {'inMailbox': mailboxId},
      },
      '0',
    ],
  ]);
  final queryArgs =
      (queryResp[0] as List<dynamic>)[1] as Map<String, dynamic>;
  final ids = List<String>.from((queryArgs['ids'] as List? ?? []));
  if (ids.isEmpty) return const [];

  final getResp = await jmap.call([
    [
      'Email/get',
      {
        'accountId': jmap.accountId,
        'ids': ids,
        'properties': [
          'id',
          'subject',
          'keywords',
          'textBody',
          'bodyValues',
        ],
        'fetchTextBodyValues': true,
      },
      '0',
    ],
  ]);
  final getArgs = (getResp[0] as List<dynamic>)[1] as Map<String, dynamic>;
  return List<Map<String, dynamic>>.from(getArgs['list'] as List<dynamic>);
}

Future<void> _appendServerDraftJmap(
  JmapClient jmap,
  String mailboxId, {
  required String fromEmail,
  required String toEmail,
  required String subject,
  required String body,
}) async {
  const bodyPartId = '1';
  final resp = await jmap.call([
    [
      'Email/set',
      {
        'accountId': jmap.accountId,
        'create': {
          'seed': {
            'mailboxIds': {mailboxId: true},
            'keywords': {r'$draft': true},
            'from': [
              {'email': fromEmail},
            ],
            'to': [
              {'email': toEmail},
            ],
            'subject': subject,
            'bodyValues': {
              bodyPartId: {
                'value': body,
                'isEncodingProblem': false,
                'isTruncated': false,
              },
            },
            'textBody': [
              {'partId': bodyPartId, 'type': 'text/plain'},
            ],
          },
        },
      },
      '0',
    ],
  ]);
  final args = (resp[0] as List<dynamic>)[1] as Map<String, dynamic>;
  final notCreated = args['notCreated'] as Map<String, dynamic>?;
  if (notCreated != null && notCreated.isNotEmpty) {
    throw JmapException('Email/set seed failed: $notCreated');
  }
}

void main() {
  late StalwartEnv env;
  late StalwartTestUser user;
  late Account imapAccount;
  late Account jmapAccount;

  setUpAll(() {
    configureSqliteForTests();
    env = StalwartEnv.fromPlatform();
    user = pickPoolUser(env: env);
    imapAccount = user.imapAccount(id: 'draft-imap', env: env);
    jmapAccount = user.jmapAccount(id: 'draft-jmap', env: env);
  });

  setUp(() async {
    // Both suites talk to the same server-side Drafts folder for the shared
    // pool user, so clearing once between tests keeps them independent.
    await _clearServerDraftsImap(env, user);
  });

  group('IMAP', () {
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

    Future<int> saveAndSync({
      required DraftRepositoryImpl drafts,
      required String subject,
      required String body,
    }) async {
      final saved = await drafts.saveDraft(
        accountId: imapAccount.id,
        toText: user.email,
        ccText: '',
        subjectText: subject,
        bodyText: body,
      );
      await drafts.syncDrafts(imapAccount.id);
      return saved.id;
    }

    test(
      r'save-then-sync appends a \Draft-flagged message on the server',
      () async {
        final r = makeRepo();
        await r.accounts.addAccount(imapAccount, user.password);
        final subject = 'imap-new-${DateTime.now().millisecondsSinceEpoch}';

        final localId = await saveAndSync(
          drafts: r.drafts,
          subject: subject,
          body: 'Hello from draft sync',
        );

        final serverMessages = await _fetchServerDraftsImap(env, user);
        expect(serverMessages, hasLength(1));
        expect(serverMessages.single.envelope?.subject, subject);
        expect(serverMessages.single.flags, contains(r'\Draft'));

        // Local row records the returned UID and is no longer dirty.
        final row = (await r.drafts.getDraft(localId))!;
        expect(row.dirty, isFalse);
        expect(int.tryParse(row.imapServerId ?? ''), isNotNull);
      },
    );

    test(
      'editing a synced draft expunges the old UID and appends a new one',
      () async {
        final r = makeRepo();
        await r.accounts.addAccount(imapAccount, user.password);
        final localId = await saveAndSync(
          drafts: r.drafts,
          subject: 'imap-edit-original',
          body: 'first',
        );
        final firstUid = (await r.drafts.getDraft(localId))!.imapServerId;

        // Edit and resync.
        await r.drafts.saveDraft(
          id: localId,
          accountId: imapAccount.id,
          toText: user.email,
          ccText: '',
          subjectText: 'imap-edit-updated',
          bodyText: 'second',
        );
        await r.drafts.syncDrafts(imapAccount.id);

        final serverMessages = await _fetchServerDraftsImap(env, user);
        expect(
          serverMessages,
          hasLength(1),
          reason: 'Old copy should be expunged when a new copy is APPENDed',
        );
        expect(serverMessages.single.envelope?.subject, 'imap-edit-updated');

        final updated = (await r.drafts.getDraft(localId))!;
        expect(updated.dirty, isFalse);
        expect(updated.imapServerId, isNot(firstUid));
      },
    );

    test(
      'a draft written on the server is pulled into the local table',
      () async {
        final r = makeRepo();
        await r.accounts.addAccount(imapAccount, user.password);

        // Simulate another device / webmail creating the draft server-side.
        await _appendServerDraftImap(
          env,
          user,
          subject: 'imap-server-only',
          body: 'from webmail',
        );
        await r.drafts.syncDrafts(imapAccount.id);

        final rows = await (r.db.select(r.db.drafts)
              ..where((t) => t.accountId.equals(imapAccount.id)))
            .get();
        expect(rows, hasLength(1));
        expect(rows.single.subjectText, 'imap-server-only');
        expect(rows.single.bodyText, contains('from webmail'));
        expect(rows.single.imapServerId, isNotNull);
        expect(rows.single.dirty, isFalse);
      },
    );

    test(
      'deleteDraft + sync removes the server copy (the post-send flow)',
      () async {
        final r = makeRepo();
        await r.accounts.addAccount(imapAccount, user.password);
        final localId = await saveAndSync(
          drafts: r.drafts,
          subject: 'imap-delete-me',
          body: 'body',
        );
        expect(await _serverDraftCountImap(env, user), 1);

        // This is exactly what compose_screen does after enqueueSend().
        await r.drafts.deleteDraft(localId);
        expect(await r.db.select(r.db.draftTombstones).get(), hasLength(1));

        await r.drafts.syncDrafts(imapAccount.id);

        expect(await _serverDraftCountImap(env, user), 0);
        expect(await r.db.select(r.db.draftTombstones).get(), isEmpty);
      },
    );
  });

  group('JMAP', () {
    ({
      AppDatabase db,
      AccountRepositoryImpl accounts,
      DraftRepositoryImpl drafts,
      LocalhostMappingClient http,
    }) makeRepo() {
      final db = openTestDatabase();
      final accounts = AccountRepositoryImpl(db, MapSecureStorage());
      final http = LocalhostMappingClient();
      final drafts = DraftRepositoryImpl(db, accounts, httpClient: http);
      return (db: db, accounts: accounts, drafts: drafts, http: http);
    }

    Future<JmapClient> openJmap(LocalhostMappingClient http) {
      return JmapClient.connect(
        httpClient: http,
        jmapUrl: Uri.parse(jmapAccount.jmapUrl!),
        username: user.email,
        password: user.password,
      );
    }

    test(
      r'save-then-sync creates a $draft-keyworded email in Drafts',
      () async {
        final r = makeRepo();
        await r.accounts.addAccount(jmapAccount, user.password);
        final subject = 'jmap-new-${DateTime.now().millisecondsSinceEpoch}';

        final saved = await r.drafts.saveDraft(
          accountId: jmapAccount.id,
          toText: user.email,
          ccText: '',
          subjectText: subject,
          bodyText: 'Hello from JMAP draft sync',
        );
        await r.drafts.syncDrafts(jmapAccount.id);

        final jmap = await openJmap(r.http);
        final mailboxId = await _findDraftsMailboxIdJmap(jmap);
        expect(
          mailboxId,
          isNotNull,
          reason: 'Drafts mailbox should exist after syncDrafts',
        );
        final serverDrafts = await _fetchServerDraftsJmap(jmap, mailboxId!);
        expect(serverDrafts, hasLength(1));
        expect(serverDrafts.single['subject'], subject);
        final keywords =
            serverDrafts.single['keywords'] as Map<String, dynamic>?;
        expect(keywords?[r'$draft'], isTrue);

        final row = (await r.drafts.getDraft(saved.id))!;
        expect(row.dirty, isFalse);
        expect(row.jmapServerId, isNotNull);
      },
    );

    test(
      'editing a synced draft destroys the old JMAP email id',
      () async {
        final r = makeRepo();
        await r.accounts.addAccount(jmapAccount, user.password);
        final first = await r.drafts.saveDraft(
          accountId: jmapAccount.id,
          toText: user.email,
          ccText: '',
          subjectText: 'jmap-edit-original',
          bodyText: 'first',
        );
        await r.drafts.syncDrafts(jmapAccount.id);
        final firstId = (await r.drafts.getDraft(first.id))!.jmapServerId;

        await r.drafts.saveDraft(
          id: first.id,
          accountId: jmapAccount.id,
          toText: user.email,
          ccText: '',
          subjectText: 'jmap-edit-updated',
          bodyText: 'second',
        );
        await r.drafts.syncDrafts(jmapAccount.id);

        final jmap = await openJmap(r.http);
        final mailboxId = (await _findDraftsMailboxIdJmap(jmap))!;
        final serverDrafts = await _fetchServerDraftsJmap(jmap, mailboxId);
        expect(
          serverDrafts,
          hasLength(1),
          reason: 'Edit should destroy the old copy',
        );
        expect(serverDrafts.single['subject'], 'jmap-edit-updated');

        final updated = (await r.drafts.getDraft(first.id))!;
        expect(updated.dirty, isFalse);
        expect(updated.jmapServerId, isNot(firstId));
      },
    );

    test(
      'a JMAP-only draft (from webmail) shows up locally after syncDrafts',
      () async {
        final r = makeRepo();
        await r.accounts.addAccount(jmapAccount, user.password);

        // Prime the Drafts mailbox by pushing one via the repo, then wipe
        // the local DB so the second pass is a pure "pull".
        await r.drafts.saveDraft(
          accountId: jmapAccount.id,
          toText: user.email,
          ccText: '',
          subjectText: 'jmap-seed',
          bodyText: 'seed',
        );
        await r.drafts.syncDrafts(jmapAccount.id);
        await r.db.delete(r.db.drafts).go();

        final jmap = await openJmap(r.http);
        final mailboxId = (await _findDraftsMailboxIdJmap(jmap))!;
        await _appendServerDraftJmap(
          jmap,
          mailboxId,
          fromEmail: user.email,
          toEmail: user.email,
          subject: 'jmap-server-only',
          body: 'from webmail',
        );

        await r.drafts.syncDrafts(jmapAccount.id);

        final rows = await (r.db.select(r.db.drafts)
              ..where((t) => t.accountId.equals(jmapAccount.id)))
            .get();
        final serverOnly = rows
            .where((row) => row.subjectText == 'jmap-server-only')
            .toList();
        expect(serverOnly, hasLength(1));
        expect(serverOnly.single.bodyText, contains('from webmail'));
        expect(serverOnly.single.jmapServerId, isNotNull);
        expect(serverOnly.single.dirty, isFalse);
      },
    );

    test(
      'deleteDraft + sync destroys the JMAP copy (the post-send flow)',
      () async {
        final r = makeRepo();
        await r.accounts.addAccount(jmapAccount, user.password);
        final saved = await r.drafts.saveDraft(
          accountId: jmapAccount.id,
          toText: user.email,
          ccText: '',
          subjectText: 'jmap-delete-me',
          bodyText: 'body',
        );
        await r.drafts.syncDrafts(jmapAccount.id);

        final jmap = await openJmap(r.http);
        final mailboxId = (await _findDraftsMailboxIdJmap(jmap))!;
        expect(await _fetchServerDraftsJmap(jmap, mailboxId), hasLength(1));

        // Same call compose_screen makes after enqueueSend().
        await r.drafts.deleteDraft(saved.id);
        expect(await r.db.select(r.db.draftTombstones).get(), hasLength(1));

        await r.drafts.syncDrafts(jmapAccount.id);

        // Fresh JMAP session — state token may have advanced.
        final jmap2 = await openJmap(r.http);
        final mailboxId2 = (await _findDraftsMailboxIdJmap(jmap2))!;
        expect(await _fetchServerDraftsJmap(jmap2, mailboxId2), isEmpty);
        expect(await r.db.select(r.db.draftTombstones).get(), isEmpty);
      },
    );
  });
}
