// A folder and its cached mail are removed only on evidence that is not a
// server or connection glitch (#1312): a folder listing that is empty, leaves
// out the inbox or a role folder, or most folders is not trusted; a folder it
// left out is removed only when the server confirms it is gone (or after a
// minimum time and number of listings without an answer), and a SELECT error
// removes a folder only on `NO [NONEXISTENT]` or a LIST without it.

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
import 'helpers/stateful_fake_imap.dart';
import 'helpers/stateful_imap_rig.dart';
import 'recording_app_log_repository.dart';

const _account = statefulRigAccount;

/// The folders of the IMAP rig: five, so three missing are "most". INBOX
/// and Archive have a role, the others none.
const _imapFolders = ['INBOX', 'Archive', 'Work', 'Lists', 'Old'];

/// The folders without a role that most-missing tests leave out.
const _plain = {'Work', 'Lists', 'Old'};

Future<List<String>> _folderPaths(AppDatabase db, String accountId) async => [
      for (final r in await (db.select(db.mailboxes)
            ..where((t) => t.accountId.equals(accountId))
            ..orderBy([(t) => OrderingTerm(expression: t.path)]))
          .get())
        r.path,
    ];

/// The marked paths ([pendingPruneKey]), or null without marks.
Future<List<String>?> _marked(AppDatabase db, String accountId) async {
  final raw = (await (db.select(db.syncStates)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.resourceType.equals(pendingPruneKey),
            ))
          .getSingleOrNull())
      ?.state;
  if (raw == null) return null;
  return (jsonDecode(raw) as Map<String, dynamic>).keys.toList()..sort();
}

List<Map<String, Object?>> _events(
  RecordingAppLogRepository logs,
  String event,
) =>
    [
      for (final r in logs.inserts)
        if (r['event'] == event) r,
    ];

Map<String, dynamic> _data(Map<String, Object?> row) =>
    jsonDecode(row['dataJson']! as String) as Map<String, dynamic>;

void main() {
  setUpAll(configureSqliteForTests);

  group('IMAP listing', () {
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
      for (final path in _plain) {
        server.deliver(path, 'in-$path@test');
        await emails.syncEmails(_account.id, path);
      }
    });
    tearDown(() => db.close());

    Future<void> listFolders() => rig.mailboxes.syncMailboxes(_account.id);

    Future<List<String>> cachedMessageIds() async => [
          for (final e in await (db.select(db.emails)
                ..orderBy([(t) => OrderingTerm(expression: t.messageId)]))
              .get())
            e.messageId ?? '',
        ];

    const allMail = [
      'a@test',
      'filler@test',
      'in-Lists@test',
      'in-Old@test',
      'in-Work@test',
    ];

    test('an empty listing removes nothing and logs why', () async {
      server.listHides = (_) => true;

      await listFolders();

      expect(
        await _folderPaths(db, _account.id),
        unorderedEquals(_imapFolders),
      );
      expect(await cachedMessageIds(), allMail);
      final warn = _events(logs, 'mailbox.listing_untrusted').single;
      expect(warn['level'], AppLogLevel.warn);
      final data = _data(warn);
      expect(data['reason'], 'empty listing');
      expect(data['listed'], 0);
      expect(data['missing'], 5);
      expect(data['kept'], 5);
      expect(data['removed'], 0);
      expect(_events(logs, 'mailbox.removed_gone'), isEmpty);
      expect(await _marked(db, _account.id), [..._imapFolders]..sort());
    });

    test('a listing without INBOX keeps it; listed again, the mark is cleared',
        () async {
      server.listHides = (path) => path == 'INBOX';

      await listFolders();

      expect(await _folderPaths(db, _account.id), contains('INBOX'));
      expect(await cachedMessageIds(), contains('a@test'));
      final warn = _events(logs, 'mailbox.listing_untrusted').single;
      expect(_data(warn)['reason'], 'inbox missing');
      expect(await _marked(db, _account.id), ['INBOX']);

      server.listHides = null;
      await listFolders();
      expect(await _marked(db, _account.id), isNull);
      expect(
        await _folderPaths(db, _account.id),
        unorderedEquals(_imapFolders),
      );
      final cleared = _events(logs, 'mailbox.listing_untrusted_cleared').single;
      expect(cleared['level'], AppLogLevel.info);
      expect(_data(cleared)['paths'], ['INBOX']);
    });

    test('INBOX left out by many listings over hours is never removed',
        () async {
      server.listHides = (path) => path == 'INBOX';
      server.statusError = (path) => path == 'INBOX' ? 'NO busy' : null;

      for (var i = 0; i < 4; i++) {
        await listFolders();
        now = now.add(const Duration(hours: 1));
      }

      expect(await _folderPaths(db, _account.id), contains('INBOX'));
      expect(await cachedMessageIds(), contains('a@test'));
      expect(_events(logs, 'mailbox.removed_gone'), isEmpty);
    });

    test('INBOX listed as "Inbox" keeps the cached INBOX', () async {
      server.renameFolder('INBOX', 'Inbox');

      await listFolders();

      expect(await _folderPaths(db, _account.id), contains('INBOX'));
      expect(await cachedMessageIds(), contains('a@test'));
      expect(_events(logs, 'mailbox.removed_gone'), isEmpty);
    });

    test('most folders gone: kept, then removed when the server confirms',
        () async {
      for (final path in _plain) {
        server.deleteFolder(path);
      }

      await listFolders();
      expect(
        await _folderPaths(db, _account.id),
        unorderedEquals(_imapFolders),
      );
      expect(await cachedMessageIds(), allMail);
      expect(await _marked(db, _account.id), ['Lists', 'Old', 'Work']);
      expect(
        _data(_events(logs, 'mailbox.listing_untrusted').single)['reason'],
        'most folders missing',
      );

      // Next listing: STATUS of each answers NONEXISTENT.
      await listFolders();
      expect(await _folderPaths(db, _account.id), ['Archive', 'INBOX']);
      expect(await cachedMessageIds(), ['a@test', 'filler@test']);
      expect(await _marked(db, _account.id), isNull);
      expect(_events(logs, 'mailbox.removed_gone'), hasLength(3));
      final second = _data(_events(logs, 'mailbox.listing_untrusted').last);
      expect(second['removed'], 3);
      expect(second['confirmedGone'], 3);
      expect(second['kept'], 0);
    });

    test('most folders left out, listed again: nothing lost', () async {
      server.listHides = _plain.contains;
      await listFolders();
      server.listHides = null;
      await listFolders();

      expect(
        await _folderPaths(db, _account.id),
        unorderedEquals(_imapFolders),
      );
      expect(await cachedMessageIds(), allMail);
      expect(await _marked(db, _account.id), isNull);
      expect(_events(logs, 'mailbox.listing_untrusted'), hasLength(1));
      expect(_events(logs, 'mailbox.listing_untrusted_cleared'), hasLength(1));
      expect(_events(logs, 'mailbox.removed_gone'), isEmpty);
    });

    test('a glitch that outlasts many listings: STATUS finds them, kept',
        () async {
      server.listHides = _plain.contains;

      for (var i = 0; i < 5; i++) {
        await listFolders();
        now = now.add(const Duration(hours: 1));
      }

      expect(
        await _folderPaths(db, _account.id),
        unorderedEquals(_imapFolders),
      );
      expect(await cachedMessageIds(), allMail);
      expect(_data(_events(logs, 'mailbox.listing_untrusted').last), {
        'reason': 'most folders missing',
        'listed': 2,
        'missing': 3,
        'kept': 3,
        'removed': 0,
        'confirmedGone': 0,
        'removedAfterWaiting': 0,
        'stillThere': 3,
        'keptPaths': unorderedEquals(_plain),
      });
    });

    test('no definite answer: removed only after an hour and three listings',
        () async {
      server.listHides = _plain.contains;
      server.statusError = (path) => _plain.contains(path) ? 'NO busy' : null;

      // Three listings within minutes: kept.
      for (var i = 0; i < 3; i++) {
        await listFolders();
        now = now.add(const Duration(minutes: 1));
      }
      expect(
        await _folderPaths(db, _account.id),
        unorderedEquals(_imapFolders),
      );

      // An hour after the first: removed.
      now = now.add(const Duration(hours: 1));
      await listFolders();
      expect(await _folderPaths(db, _account.id), ['Archive', 'INBOX']);
      expect(
        _data(_events(logs, 'mailbox.listing_untrusted').last)[
            'removedAfterWaiting'],
        3,
      );
    });

    test('one plain folder gone is removed at once', () async {
      server.deleteFolder('Work');

      await listFolders();

      expect(
        await _folderPaths(db, _account.id),
        unorderedEquals(['INBOX', 'Archive', 'Lists', 'Old']),
      );
      expect(await cachedMessageIds(), isNot(contains('in-Work@test')));
      expect(_events(logs, 'mailbox.listing_untrusted'), isEmpty);
      expect(_events(logs, 'mailbox.removed_gone'), hasLength(1));
    });

    test('a role folder gone: kept by the first listing, then confirmed',
        () async {
      server.deleteFolder('Archive');

      await listFolders();
      expect(await _folderPaths(db, _account.id), contains('Archive'));
      expect(
        _data(_events(logs, 'mailbox.listing_untrusted').single)['reason'],
        'role folder missing',
      );

      await listFolders();
      expect(await _folderPaths(db, _account.id), isNot(contains('Archive')));
      expect(await cachedMessageIds(), isNot(contains('filler@test')));
    });

    test('a stand-in folder is kept by every untrusted listing', () async {
      await db.into(db.mailboxes).insert(
            MailboxesCompanion.insert(
              id: '${_account.id}:Standin',
              accountId: _account.id,
              path: 'Standin',
              name: 'Standin',
              isLocal: const Value(true),
            ),
          );
      for (final path in _plain) {
        server.deleteFolder(path);
      }

      // Untrusted, keeps everything.
      await listFolders();
      expect(await _folderPaths(db, _account.id), contains('Standin'));
      // Untrusted still (most folders missing), though it removes them all.
      await listFolders();
      expect(
        await _folderPaths(db, _account.id),
        ['Archive', 'INBOX', 'Standin'],
      );
      // A trusted listing drops the stand-in nobody needs.
      await listFolders();
      expect(await _folderPaths(db, _account.id), ['Archive', 'INBOX']);
    });
  });

  group('IMAP listing, three folders', () {
    late RecordingAppLogRepository logs;

    Future<void> open(List<(String, String)> folders) async {
      logs = RecordingAppLogRepository();
      rig = await StatefulImapRig.open(
        StatefulFakeImapServer(
          uidValidityByFolder: {
            for (final (i, (path, _)) in folders.indexed) path: 7 * (i + 1),
          },
        ),
        folders: folders,
        appLogger: AppLogger(logs),
      );
    }

    tearDown(() => db.close());

    test('INBOX, Sent, Trash: a listing of INBOX only keeps Sent and Trash',
        () async {
      await open([('INBOX', 'inbox'), ('Sent', 'sent'), ('Trash', 'trash')]);
      server.listHides = (path) => path != 'INBOX';

      await rig.mailboxes.syncMailboxes(_account.id);

      expect(
        await _folderPaths(db, _account.id),
        ['INBOX', 'Sent', 'Trash'],
      );
      expect(
        _data(_events(logs, 'mailbox.listing_untrusted').single)['reason'],
        'role folder missing',
      );
    });

    test('2 of 3 plain folders missing is not trusted', () async {
      await open([('INBOX', 'inbox'), ('A', ''), ('B', '')]);
      server.listHides = (path) => path != 'INBOX';

      await rig.mailboxes.syncMailboxes(_account.id);

      expect(await _folderPaths(db, _account.id), ['A', 'B', 'INBOX']);
      expect(
        _data(_events(logs, 'mailbox.listing_untrusted').single)['reason'],
        'most folders missing',
      );
    });
  });

  group('IMAP SELECT', () {
    late RecordingAppLogRepository logs;

    setUp(() async {
      logs = await openRigInboxArchive();
      server.deliver('Archive', 'b@test');
      await emails.syncEmails(_account.id, 'Archive');
    });
    tearDown(() => db.close());

    Future<List<String>> cachedMessageIds() async => [
          for (final e in await (db.select(db.emails)
                ..orderBy([(t) => OrderingTerm(expression: t.messageId)]))
              .get())
            e.messageId ?? '',
        ];

    test('"not found" without NONEXISTENT of a listed folder keeps it',
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

    test('"not found" with an empty LIST keeps the folder', () async {
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

    test('"does not exist" confirmed by LIST removes the folder', () async {
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
      expect(_events(logs, 'mailbox.removed_gone'), hasLength(1));
      expect(_events(logs, 'mailbox.select_failed_kept'), isEmpty);
    });

    test('NO [NONEXISTENT] for INBOX does not remove it', () async {
      server.selectError = (path) =>
          path == 'INBOX' ? 'NO [NONEXISTENT] Mailbox does not exist' : null;

      await expectLater(
        emails.syncEmails(_account.id, 'INBOX'),
        throwsA(anything),
      );

      expect(await _folderPaths(db, _account.id), contains('INBOX'));
      expect(await cachedMessageIds(), contains('a@test'));
    });

    test(
        'a flush keeps the changes of a folder whose SELECT fails vaguely; '
        'one LIST and one log line per pass', () async {
      for (final e in await db.select(db.emails).get()) {
        if (e.mailboxPath == 'Archive') await emails.setFlag(e.id, seen: true);
      }
      server.selectError =
          (path) => path == 'Archive' ? 'NO Mailbox not found (busy)' : null;
      final listsBefore = server.listCount;

      await emails.flushPendingChanges(_account.id, 'pw');

      final ops = await rigOps();
      expect(ops, hasLength(2));
      for (final op in ops) {
        expect(op.state, isNot('failed'));
        expect(op.attempts, 1);
      }
      expect(server.listCount - listsBefore, 1);
      expect(_events(logs, 'pending_change.select_failed_kept'), hasLength(1));
      expect(_events(logs, 'pending_change.skipped_gone'), isEmpty);
      expect(await cachedMessageIds(), contains('b@test'));

      // Once SELECT works again, the changes reach the server.
      server.selectError = null;
      now = now.add(const Duration(hours: 1));
      await emails.flushPendingChanges(_account.id, 'pw');
      expect(server.find('filler@test')!.message.seen, isTrue);
      expect(server.find('b@test')!.message.seen, isTrue);
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
    // What the fake server has (`Mailbox/get` of ids), what its full
    // listing shows, and what its `Mailbox/changes` reports.
    late List<String> existing;
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

    List<dynamic> mailboxGet(JmapCall call) {
      final asked = call.args['ids'] == null ? null : call.ids;
      return [
        'Mailbox/get',
        {
          'accountId': 'acct1',
          'state': 's${++state}',
          'list': [
            if (asked == null)
              for (final id in listed) mailboxObject(id)
            else
              for (final id in asked)
                if (existing.contains(id)) mailboxObject(id),
          ],
          'notFound': [
            for (final id in asked ?? const <String>[])
              if (!existing.contains(id)) id,
          ],
        },
        call.callId,
      ];
    }

    setUp(() async {
      db = openTestDatabase();
      logs = RecordingAppLogRepository();
      existing = [...allIds];
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
            'Mailbox/get' => mailboxGet(call),
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

    test(
        'a Mailbox/get without the inbox keeps it while Mailbox/get of its '
        'id finds it', () async {
      listed = ['mb-a', 'mb-b', 'mb-c', 'mb-d'];

      await mailboxes.syncMailboxes(accountId);
      await mailboxes.syncMailboxes(accountId);

      expect(await _folderPaths(db, accountId), contains('mb-inbox'));
      expect(await mailCount(), 5);
      expect(
        _data(_events(logs, 'mailbox.listing_untrusted').first)['reason'],
        'inbox missing',
      );
      final last = _data(_events(logs, 'mailbox.listing_untrusted').last);
      expect(last['stillThere'], 1);
    });

    test('most mailboxes destroyed: removed when notFound confirms', () async {
      existing = listed = ['mb-inbox', 'mb-d'];

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
      expect(await _marked(db, accountId), isNull);
      expect(_events(logs, 'mailbox.removed_gone'), hasLength(3));
    });

    test('most mailboxes left out, listed again: nothing lost', () async {
      listed = ['mb-inbox', 'mb-d'];
      await mailboxes.syncMailboxes(accountId);
      listed = [...allIds];
      await mailboxes.syncMailboxes(accountId);

      expect(await _folderPaths(db, accountId), unorderedEquals(allIds));
      expect(await mailCount(), 5);
      expect(await mailboxState(), isNotNull);
      expect(await _marked(db, accountId), isNull);
      expect(_events(logs, 'mailbox.removed_gone'), isEmpty);
    });

    test('Mailbox/changes destroying a plain mailbox removes it', () async {
      await mailboxes.syncMailboxes(accountId);
      destroyed = ['mb-a'];

      await mailboxes.syncMailboxes(accountId);

      expect(await _folderPaths(db, accountId), isNot(contains('mb-a')));
      expect(await mailCount(), 4);
      expect(_events(logs, 'mailbox.listing_untrusted'), isEmpty);
    });

    test('Mailbox/changes destroying the inbox: kept until confirmed',
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
      expect(await _marked(db, accountId), isNull);
      expect(await mailboxState(), isNotNull);

      // Destroyed again, and the server confirms it: removed.
      destroyed = ['mb-inbox'];
      await mailboxes.syncMailboxes(accountId);
      existing = listed = ['mb-a', 'mb-b', 'mb-c', 'mb-d'];
      await mailboxes.syncMailboxes(accountId);
      expect(await _folderPaths(db, accountId), isNot(contains('mb-inbox')));
      expect(await mailCount(), 4);
    });
  });
}
