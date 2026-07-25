// Integration tests for DraftRepositoryImpl's JMAP sync against a real
// Stalwart instance. Closes #331 for the JMAP path.
//
// Run via: stalwart-dev/test.sh

import 'package:drift/drift.dart' show Value;
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

Map<String, dynamic> _responseArgs(
  List<dynamic> responses,
  int index,
  String expectedMethod,
) {
  final triple = responses[index] as List<dynamic>;
  final method = triple[0] as String;
  if (method == 'error') {
    final err = triple[1] as Map<String, dynamic>;
    throw JmapException('$expectedMethod error: ${err['type']}');
  }
  return triple[1] as Map<String, dynamic>;
}

Future<String?> _findDraftsMailboxIdJmap(JmapClient jmap) async {
  final resp = await jmap.call([
    [
      'Mailbox/get',
      {'accountId': jmap.accountId, 'ids': null},
      '0',
    ],
  ]);
  final args = _responseArgs(resp, 0, 'Mailbox/get');
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
  final ids = List<String>.from(
    (_responseArgs(queryResp, 0, 'Email/query')['ids'] as List? ?? []),
  );
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
  final args = _responseArgs(getResp, 0, 'Email/get');
  return List<Map<String, dynamic>>.from(args['list'] as List<dynamic>);
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
  final args = _responseArgs(resp, 0, 'Email/set');
  final notCreated = args['notCreated'] as Map<String, dynamic>?;
  if (notCreated != null && notCreated.isNotEmpty) {
    throw JmapException('Email/set seed failed: $notCreated');
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
    account = user.jmapAccount(id: 'draft-jmap', env: env);
  });

  setUp(() async {
    // Clearing via IMAP is simpler and works regardless of whether Stalwart
    // has already provisioned the Drafts JMAP mailbox for the pool user.
    await _clearServerDraftsImap(env, user);
  });

  ({
    AppDatabase db,
    AccountRepositoryImpl accounts,
    DraftRepositoryImpl drafts,
    LocalhostMappingClient http,
  }) makeRepo() {
    final db = openTestDatabase();
    final accounts = AccountRepositoryImpl(db, MapSecureStorage());
    final http = LocalhostMappingClient();
    final drafts =
        DraftRepositoryImpl(db, accounts, httpClient: http);
    return (db: db, accounts: accounts, drafts: drafts, http: http);
  }

  Future<JmapClient> connectJmap(LocalhostMappingClient http) async {
    return JmapClient.connect(
      httpClient: http,
      jmapUrl: Uri.parse(account.jmapUrl!),
      username: user.email,
      password: user.password,
    );
  }

  test('saveDraft + syncDrafts creates a draft in the JMAP Drafts mailbox',
      () async {
    final r = makeRepo();
    await r.accounts.addAccount(account, user.password);
    final subject = 'jmap-new-${DateTime.now().millisecondsSinceEpoch}';

    await r.drafts.saveDraft(
      accountId: account.id,
      toText: user.email,
      ccText: '',
      subjectText: subject,
      bodyText: 'Hello from JMAP draft sync',
    );
    await r.drafts.syncDrafts(account.id);

    final jmap = await connectJmap(r.http);
    final mailboxId = await _findDraftsMailboxIdJmap(jmap);
    expect(mailboxId, isNotNull,
        reason: 'Drafts mailbox should exist after syncDrafts');
    final serverDrafts = await _fetchServerDraftsJmap(jmap, mailboxId!);
    expect(serverDrafts, hasLength(1));
    expect(serverDrafts.single['subject'], subject);
    final keywords = serverDrafts.single['keywords'] as Map<String, dynamic>?;
    expect(keywords?[r'$draft'], isTrue);
  });

  test('syncDrafts records the JMAP email id and clears dirty locally',
      () async {
    final r = makeRepo();
    await r.accounts.addAccount(account, user.password);
    final saved = await r.drafts.saveDraft(
      accountId: account.id,
      toText: user.email,
      ccText: '',
      subjectText: 'jmap-id-${DateTime.now().millisecondsSinceEpoch}',
      bodyText: 'body',
    );
    await r.drafts.syncDrafts(account.id);

    final row = await r.drafts.getDraft(saved.id);
    expect(row, isNotNull);
    expect(row!.dirty, isFalse);
    expect(row.jmapServerId, isNotNull);
    expect(row.jmapServerId!.isNotEmpty, isTrue);
  });

  test(
    'editing a synced draft destroys the previous JMAP copy and creates a new one',
    () async {
      final r = makeRepo();
      await r.accounts.addAccount(account, user.password);
      final saved = await r.drafts.saveDraft(
        accountId: account.id,
        toText: user.email,
        ccText: '',
        subjectText: 'jmap-edit-original',
        bodyText: 'first',
      );
      await r.drafts.syncDrafts(account.id);
      final firstRow = (await r.drafts.getDraft(saved.id))!;
      final firstId = firstRow.jmapServerId;

      await r.drafts.saveDraft(
        id: saved.id,
        accountId: account.id,
        toText: user.email,
        ccText: '',
        subjectText: 'jmap-edit-updated',
        bodyText: 'second',
      );
      await r.drafts.syncDrafts(account.id);

      final jmap = await connectJmap(r.http);
      final mailboxId = (await _findDraftsMailboxIdJmap(jmap))!;
      final serverDrafts = await _fetchServerDraftsJmap(jmap, mailboxId);
      expect(serverDrafts, hasLength(1),
          reason: 'Edit should destroy the old copy');
      expect(serverDrafts.single['subject'], 'jmap-edit-updated');

      final secondRow = (await r.drafts.getDraft(saved.id))!;
      expect(secondRow.dirty, isFalse);
      expect(secondRow.jmapServerId, isNotNull);
      expect(secondRow.jmapServerId, isNot(firstId));
    },
  );

  test('syncDrafts pulls a server-only JMAP draft into the local table',
      () async {
    final r = makeRepo();
    await r.accounts.addAccount(account, user.password);

    // Prime the JMAP Drafts mailbox by creating one via the repo, then wipe
    // the local DB so the second pass looks like a pure "pull".
    await r.drafts.saveDraft(
      accountId: account.id,
      toText: user.email,
      ccText: '',
      subjectText: 'jmap-seed',
      bodyText: 'seed',
    );
    await r.drafts.syncDrafts(account.id);
    await r.db.delete(r.db.drafts).go();

    // Now write a fresh draft directly through JMAP (simulating webmail).
    final jmap = await connectJmap(r.http);
    final mailboxId = (await _findDraftsMailboxIdJmap(jmap))!;
    await _appendServerDraftJmap(
      jmap,
      mailboxId,
      fromEmail: user.email,
      toEmail: user.email,
      subject: 'jmap-server-only',
      body: 'from webmail',
    );

    await r.drafts.syncDrafts(account.id);

    final rows = await (r.db.select(r.db.drafts)
          ..where((t) => t.accountId.equals(account.id)))
        .get();
    final serverOnly =
        rows.where((row) => row.subjectText == 'jmap-server-only').toList();
    expect(serverOnly, hasLength(1));
    expect(serverOnly.single.bodyText, contains('from webmail'));
    expect(serverOnly.single.jmapServerId, isNotNull);
    expect(serverOnly.single.dirty, isFalse);
  });

  test(
    'deleteDraft writes a tombstone and syncDrafts destroys the JMAP copy',
    () async {
      final r = makeRepo();
      await r.accounts.addAccount(account, user.password);
      final saved = await r.drafts.saveDraft(
        accountId: account.id,
        toText: user.email,
        ccText: '',
        subjectText: 'jmap-delete-me',
        bodyText: 'body',
      );
      await r.drafts.syncDrafts(account.id);

      final jmap = await connectJmap(r.http);
      final mailboxId = (await _findDraftsMailboxIdJmap(jmap))!;
      expect(await _fetchServerDraftsJmap(jmap, mailboxId), hasLength(1));

      await r.drafts.deleteDraft(saved.id);
      expect(await r.db.select(r.db.draftTombstones).get(), hasLength(1));

      await r.drafts.syncDrafts(account.id);

      // Re-connect for a fresh JMAP session — state may have advanced.
      final jmap2 = await connectJmap(r.http);
      final mailboxId2 = (await _findDraftsMailboxIdJmap(jmap2))!;
      expect(await _fetchServerDraftsJmap(jmap2, mailboxId2), isEmpty);
      expect(await r.db.select(r.db.draftTombstones).get(), isEmpty);
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
        subjectText: 'jmap-vanish',
        bodyText: 'body',
      );
      await r.drafts.syncDrafts(account.id);
      expect(await r.drafts.getDraft(saved.id), isNotNull);

      // Simulate another device deleting the server draft.
      await _clearServerDraftsImap(env, user);

      await r.drafts.syncDrafts(account.id);
      expect(await r.drafts.getDraft(saved.id), isNull);
    },
  );

  test('local dirty rows survive pull reconciliation until re-pushed',
      () async {
    final r = makeRepo();
    await r.accounts.addAccount(account, user.password);
    final saved = await r.drafts.saveDraft(
      accountId: account.id,
      toText: user.email,
      ccText: '',
      subjectText: 'jmap-dirty-guard',
      bodyText: 'body',
    );
    // Mark as if we had synced with a stale server id that no longer exists.
    await (r.db.update(r.db.drafts)..where((t) => t.id.equals(saved.id)))
        .write(const DraftsCompanion(
      jmapServerId: Value('gone-id'),
      dirty: Value(true),
    ));

    await r.drafts.syncDrafts(account.id);

    final row = await r.drafts.getDraft(saved.id);
    expect(row, isNotNull);
    expect(row!.dirty, isFalse);
    expect(row.jmapServerId, isNot('gone-id'));
  });
}
