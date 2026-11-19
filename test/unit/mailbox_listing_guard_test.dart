// A folder and its cached mail are removed only on evidence that is not a
// server or connection glitch (#1312): an empty or partial folder listing is
// not trusted until the next listing confirms it, and a SELECT error removes
// a folder only on `NO [NONEXISTENT]` or a LIST without it.

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';

import 'db_test_helper.dart';
import 'helpers/fake_secure_storage.dart';
import 'helpers/jmap_test_server.dart';
import 'helpers/stateful_imap_rig.dart';
import 'recording_app_log_repository.dart';

const _account = statefulRigAccount;

/// The folders of the IMAP rig: five, so three missing are "most".
const _imapFolders = ['INBOX', 'Archive', 'Work', 'Lists', 'Old'];

Future<List<String>> _folderPaths(AppDatabase db, String accountId) async => [
      for (final r in await (db.select(db.mailboxes)
            ..where((t) => t.accountId.equals(accountId))
            ..orderBy([(t) => OrderingTerm(expression: t.path)]))
          .get())
        r.path,
    ];

Future<String?> _pendingPrune(AppDatabase db, String accountId) async =>
    (await (db.select(db.syncStates)
              ..where(
                (t) =>
                    t.accountId.equals(accountId) &
                    t.resourceType.equals(pendingPruneKey),
              ))
            .getSingleOrNull())
        ?.state;

List<Map<String, Object?>> _events(
  RecordingAppLogRepository logs,
  String event,
) =>
    [
      for (final r in logs.inserts)
        if (r['event'] == event) r,
    ];

void main() {
  setUpAll(configureSqliteForTests);

  group('IMAP', () {
    late RecordingAppLogRepository logs;

    setUp(() async {
      logs = await openRigWithMailA(
        uidValidityByFolder: {
          for (final (i, path) in _imapFolders.indexed) path: 11 * (i + 1),
        },
        folders: [
          ('INBOX', 'inbox'),
          ('Archive', 'archive'),
          for (final path in _imapFolders.skip(2)) (path, ''),
        ],
      );
    });
    tearDown(() => db.close());

    Future<void> listFolders() => rig.mailboxes.syncMailboxes(_account.id);

    Future<List<String>> cachedMessageIds() async => [
          for (final e in await (db.select(db.emails)
                ..orderBy([(t) => OrderingTerm(expression: t.messageId)]))
              .get())
            e.messageId ?? '',
        ];

    test('an empty listing removes nothing and logs why', () async {
      server.listHides = (_) => true;

      await listFolders();

      expect(
        await _folderPaths(db, _account.id),
        unorderedEquals(_imapFolders),
      );
      expect(await cachedMessageIds(), ['a@test', 'filler@test']);
      final warn = _events(logs, 'mailbox.listing_untrusted').single;
      expect(warn['level'], AppLogLevel.warn);
      final data = jsonDecode(warn['dataJson']! as String) as Map;
      expect(data['reason'], 'empty listing');
      expect(data['listed'], 0);
      expect(data['missing'], 5);
      expect(data['kept'], 5);
      expect(data['removed'], 0);
      expect(_events(logs, 'mailbox.removed_gone'), isEmpty);
    });

    test('a listing without INBOX keeps INBOX and its mail', () async {
      server.listHides = (path) => path == 'INBOX';

      await listFolders();

      expect(await _folderPaths(db, _account.id), contains('INBOX'));
      expect(await cachedMessageIds(), contains('a@test'));
      final warn = _events(logs, 'mailbox.listing_untrusted').single;
      expect(
        (jsonDecode(warn['dataJson']! as String) as Map)['reason'],
        'inbox missing',
      );
      expect(jsonDecode((await _pendingPrune(db, _account.id))!), ['INBOX']);

      // The next listing has it again: nothing is pending any more.
      server.listHides = null;
      await listFolders();
      expect(await _pendingPrune(db, _account.id), isNull);
      expect(
        await _folderPaths(db, _account.id),
        unorderedEquals(_imapFolders),
      );
    });

    test('most folders missing, confirmed by the next listing: removed',
        () async {
      for (final path in ['Archive', 'Work', 'Lists']) {
        server.deleteFolder(path);
      }

      await listFolders();
      expect(
        await _folderPaths(db, _account.id),
        unorderedEquals(_imapFolders),
      );
      expect(await cachedMessageIds(), contains('filler@test'));
      expect(
        jsonDecode((await _pendingPrune(db, _account.id))!),
        ['Archive', 'Lists', 'Work'],
      );

      await listFolders();
      expect(await _folderPaths(db, _account.id), ['INBOX', 'Old']);
      expect(await cachedMessageIds(), ['a@test']);
      expect(await _pendingPrune(db, _account.id), isNull);
      expect(_events(logs, 'mailbox.removed_gone'), hasLength(3));
      final last = _events(logs, 'mailbox.listing_untrusted').last;
      final second = jsonDecode(last['dataJson']! as String) as Map;
      expect(second['removed'], 3);
      expect(second['kept'], 0);
    });

    test(
        'most folders missing, not confirmed by the next listing: nothing lost',
        () async {
      server.listHides =
          (path) => const {'Archive', 'Work', 'Lists'}.contains(path);
      await listFolders();
      server.listHides = null;
      await listFolders();

      expect(
        await _folderPaths(db, _account.id),
        unorderedEquals(_imapFolders),
      );
      expect(await cachedMessageIds(), ['a@test', 'filler@test']);
      expect(await _pendingPrune(db, _account.id), isNull);
      expect(_events(logs, 'mailbox.listing_untrusted'), hasLength(1));
      expect(_events(logs, 'mailbox.removed_gone'), isEmpty);
    });

    test('a few folders missing are removed at once', () async {
      server.deleteFolder('Archive');

      await listFolders();

      expect(
        await _folderPaths(db, _account.id),
        unorderedEquals(['INBOX', 'Work', 'Lists', 'Old']),
      );
      expect(await cachedMessageIds(), ['a@test']);
      expect(_events(logs, 'mailbox.listing_untrusted'), isEmpty);
      expect(_events(logs, 'mailbox.removed_gone'), hasLength(1));
    });

    test('a SELECT "not found" without NONEXISTENT of a listed folder keeps it',
        () async {
      server.selectError =
          (path) => path == 'Archive' ? 'NO Mailbox not found (busy)' : null;

      await expectLater(
        emails.syncEmails(_account.id, 'Archive'),
        throwsA(anything),
      );

      expect(await _folderPaths(db, _account.id), contains('Archive'));
      expect(await cachedMessageIds(), contains('filler@test'));
      expect(_events(logs, 'mailbox.select_failed_kept'), hasLength(1));
      expect(_events(logs, 'mailbox.removed_gone'), isEmpty);
    });

    test('a SELECT "not found" with an empty LIST keeps the folder', () async {
      server.selectError =
          (path) => path == 'Archive' ? 'NO Mailbox not found' : null;
      server.listHides = (_) => true;

      await expectLater(
        emails.syncEmails(_account.id, 'Archive'),
        throwsA(anything),
      );

      expect(await _folderPaths(db, _account.id), contains('Archive'));
      expect(_events(logs, 'mailbox.select_failed_kept'), hasLength(1));
    });

    test('a SELECT "does not exist" confirmed by LIST removes the folder',
        () async {
      // The fake answers a missing folder with a plain `NO Mailbox does not
      // exist`; the LIST then does not have it.
      server.deleteFolder('Archive');

      final result = await emails.syncEmails(_account.id, 'Archive');

      expect(result.fetched, 0);
      expect(await _folderPaths(db, _account.id), isNot(contains('Archive')));
      expect(await cachedMessageIds(), ['a@test']);
      expect(_events(logs, 'mailbox.removed_gone'), hasLength(1));
    });

    test('a definite NO [NONEXISTENT] removes the folder', () async {
      // Still listed: the response code alone decides.
      server.selectError = (path) =>
          path == 'Archive' ? 'NO [NONEXISTENT] Mailbox does not exist' : null;

      final result = await emails.syncEmails(_account.id, 'Archive');

      expect(result.fetched, 0);
      expect(await _folderPaths(db, _account.id), isNot(contains('Archive')));
      expect(await cachedMessageIds(), ['a@test']);
      expect(_events(logs, 'mailbox.removed_gone'), hasLength(1));
      expect(_events(logs, 'mailbox.select_failed_kept'), isEmpty);
    });

    test('a flush keeps a change whose folder SELECT fails vaguely', () async {
      await emails.setFlag((await rowOfA()).id, seen: true);
      server.selectError =
          (path) => path == 'INBOX' ? 'NO Mailbox not found (busy)' : null;

      await emails.flushPendingChanges(_account.id, 'pw');

      final op = (await rigOps()).single;
      expect(op.changeType, 'flag_seen');
      expect(op.state, isNot('failed'));
      expect(op.attempts, 1);
      expect(_events(logs, 'pending_change.select_failed_kept'), hasLength(1));
      expect(_events(logs, 'pending_change.skipped_gone'), isEmpty);
      expect(await rowsOfA(), hasLength(1));

      // Once SELECT works again, the change reaches the server.
      server.selectError = null;
      now = now.add(const Duration(hours: 1));
      await emails.flushPendingChanges(_account.id, 'pw');
      expect(server.find('a@test')!.message.seen, isTrue);
    });
  });

  group('JMAP', () {
    const accountId = 'jmap-1';
    const jmapAccount = Account(
      id: accountId,
      displayName: 'Alice',
      email: 'alice@example.com',
      type: AccountType.jmap,
      jmapUrl: 'https://jmap.example.com/.well-known/jmap',
    );
    // Five mailboxes, by id; mb-inbox has the inbox role.
    const allIds = ['mb-inbox', 'mb-a', 'mb-b', 'mb-c', 'mb-d'];

    late AppDatabase db;
    late RecordingAppLogRepository logs;
    late MailboxRepositoryImpl mailboxes;
    // What the fake server lists, and what its `Mailbox/changes` reports.
    late List<String> listed;
    late List<String> destroyed;
    var state = 0;

    Map<String, dynamic> mailboxObject(String id) => {
          'id': id,
          'name': id,
          if (id == 'mb-inbox') 'role': 'inbox',
          'unreadEmails': 0,
          'totalEmails': 0,
        };

    setUp(() async {
      db = openTestDatabase();
      logs = RecordingAppLogRepository();
      listed = [...allIds];
      destroyed = [];
      state = 0;
      final accounts = AccountRepositoryImpl(db, FakeSecureStorage());
      mailboxes = MailboxRepositoryImpl(
        db,
        accounts,
        appLogger: AppLogger(logs),
        httpClient: jmapFakeServer(
          accountId: 'acct1',
          handle: (call) => switch (call.method) {
            'Mailbox/get' => [
                'Mailbox/get',
                {
                  'accountId': 'acct1',
                  'state': 's${++state}',
                  'list': [
                    for (final id in listed)
                      if (call.args['ids'] == null || call.ids.contains(id))
                        mailboxObject(id),
                  ],
                },
                call.callId,
              ],
            'Mailbox/changes' => [
                'Mailbox/changes',
                {
                  'accountId': 'acct1',
                  'oldState': call.args['sinceState'],
                  'newState': 's${++state}',
                  'hasMoreChanges': false,
                  'created': <String>[],
                  'updated': <String>[],
                  'destroyed': destroyed,
                },
                call.callId,
              ],
            _ => null,
          },
        ),
      );
      await accounts.addAccount(jmapAccount, 'pw');
      // A first listing caches every mailbox; each has one mail.
      await mailboxes.syncMailboxes(accountId);
      for (final id in allIds) {
        await insertJmapEmailRow(db, accountId, 'e-$id', mailboxPath: id);
        await (db.update(db.emails)
              ..where((t) => t.id.equals('$accountId:e-$id')))
            .write(EmailsCompanion(srvMailboxPath: Value(id)));
      }
      // Every later listing is a full `Mailbox/get`.
      await mailboxes.clearForResync(accountId);
      logs.rows.clear();
    });
    tearDown(() => db.close());

    Future<int> mailCount() async => (await db.select(db.emails).get()).length;

    Future<String?> mailboxState() async => (await (db.select(db.syncStates)
              ..where(
                (t) =>
                    t.accountId.equals(accountId) &
                    t.resourceType.equals('Mailbox'),
              ))
            .getSingleOrNull())
        ?.state;

    test('an empty Mailbox/get removes nothing and keeps no state', () async {
      listed = [];

      await mailboxes.syncMailboxes(accountId);

      expect(await _folderPaths(db, accountId), unorderedEquals(allIds));
      expect(await mailCount(), 5);
      expect(await mailboxState(), isNull);
      expect(_events(logs, 'mailbox.listing_untrusted'), hasLength(1));
    });

    test('a Mailbox/get without the inbox role keeps the inbox', () async {
      listed = ['mb-a', 'mb-b', 'mb-c', 'mb-d'];

      await mailboxes.syncMailboxes(accountId);

      expect(await _folderPaths(db, accountId), contains('mb-inbox'));
      expect(await mailCount(), 5);
      final warn = _events(logs, 'mailbox.listing_untrusted').single;
      expect(
        (jsonDecode(warn['dataJson']! as String) as Map)['reason'],
        'inbox missing',
      );
    });

    test('most mailboxes missing, confirmed by the next Mailbox/get: removed',
        () async {
      listed = ['mb-inbox', 'mb-d'];

      await mailboxes.syncMailboxes(accountId);
      expect(await _folderPaths(db, accountId), unorderedEquals(allIds));
      expect(await mailboxState(), isNull);

      await mailboxes.syncMailboxes(accountId);
      expect(
        await _folderPaths(db, accountId),
        unorderedEquals(['mb-inbox', 'mb-d']),
      );
      expect(await mailCount(), 2);
      expect(await mailboxState(), isNotNull);
      expect(await _pendingPrune(db, accountId), isNull);
      expect(_events(logs, 'mailbox.removed_gone'), hasLength(3));
    });

    test('most mailboxes missing, not confirmed: nothing lost', () async {
      listed = ['mb-inbox', 'mb-d'];
      await mailboxes.syncMailboxes(accountId);
      listed = [...allIds];
      await mailboxes.syncMailboxes(accountId);

      expect(await _folderPaths(db, accountId), unorderedEquals(allIds));
      expect(await mailCount(), 5);
      expect(await mailboxState(), isNotNull);
      expect(await _pendingPrune(db, accountId), isNull);
      expect(_events(logs, 'mailbox.removed_gone'), isEmpty);
    });

    test('Mailbox/changes destroying a plain mailbox removes it', () async {
      await mailboxes.syncMailboxes(accountId);
      destroyed = ['mb-a'];
      listed = ['mb-inbox', 'mb-b', 'mb-c', 'mb-d'];

      await mailboxes.syncMailboxes(accountId);

      expect(await _folderPaths(db, accountId), isNot(contains('mb-a')));
      expect(await mailCount(), 4);
      expect(_events(logs, 'mailbox.listing_untrusted'), isEmpty);
    });

    test('Mailbox/changes destroying the inbox: kept until a listing confirms',
        () async {
      await mailboxes.syncMailboxes(accountId);
      destroyed = ['mb-inbox'];

      await mailboxes.syncMailboxes(accountId);
      expect(await _folderPaths(db, accountId), contains('mb-inbox'));
      expect(await mailCount(), 5);
      expect(await mailboxState(), isNull);
      expect(_events(logs, 'mailbox.listing_untrusted'), hasLength(1));

      // The full listing that follows still has it: kept for good.
      destroyed = [];
      await mailboxes.syncMailboxes(accountId);
      expect(await _folderPaths(db, accountId), contains('mb-inbox'));
      expect(await _pendingPrune(db, accountId), isNull);
      expect(await mailboxState(), isNotNull);

      // Destroyed again, and the full listing confirms it: removed.
      destroyed = ['mb-inbox'];
      await mailboxes.syncMailboxes(accountId);
      listed = ['mb-a', 'mb-b', 'mb-c', 'mb-d'];
      await mailboxes.syncMailboxes(accountId);
      expect(await _folderPaths(db, accountId), isNot(contains('mb-inbox')));
      expect(await mailCount(), 4);
    });
  });
}
