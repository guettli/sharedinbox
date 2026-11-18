// Folder ops offline (SYNC-REDESIGN.md §7, phase 5a; #1242): creating and
// renaming a folder are queued mailbox ops, folded into the mailbox rows
// (`local_name`), flushed before the email changes on IMAP and JMAP, with the
// same outcomes as email changes. A move into a folder created offline waits
// for the create and fails with it.

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/db/mailbox_fold.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_state_writer.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mailbox_state_writer.dart';

import 'db_test_helper.dart';
import 'helpers/jmap_test_server.dart';
import 'helpers/stateful_imap_rig.dart';
import 'recording_app_log_repository.dart';

const _acc = statefulRigAccount;

Future<void> _expectConsistent(AppDatabase db) async {
  expect(await EmailStateWriter(db).consistencyProblems(), isEmpty);
  expect(await MailboxStateWriter(db).consistencyProblems(), isEmpty);
}

Future<List<(String, String)>> _ops(AppDatabase db) async => [
      for (final o in await (db.select(db.pendingChanges)
            ..orderBy([(t) => OrderingTerm.asc(t.id)]))
          .get())
        (o.changeType, o.state),
    ];

void main() {
  setUpAll(configureSqliteForTests);

  group('fold', () {
    MailboxFoldOp op(int seq, String type, String name, String state) =>
        MailboxFoldOp(seq: seq, type: type, name: name, state: state);

    test('the latest foldable create or rename names the folder', () {
      expect(foldMailboxName(const []), isNull);
      expect(
        foldMailboxName([
          op(2, renameMailboxOp, 'B', 'pending'),
          op(1, createMailboxOp, 'A', 'acked'),
        ]),
        'B',
      );
      // A failed rename stops folding: the server's name shows again.
      expect(
        foldMailboxName([
          op(1, createMailboxOp, 'A', 'acked'),
          op(2, renameMailboxOp, 'B', 'failed'),
        ]),
        'A',
      );
      expect(
        localMailboxShown([op(1, createMailboxOp, 'A', 'failed')]),
        isFalse,
      );
      expect(localMailboxShown([op(1, createMailboxOp, 'A', 'stuck')]), isTrue);
    });

    test('IMAP display paths: a pending name replaces the leaf, also below',
        () {
      final paths = displayPaths(
        const [
          DisplayPathRow(path: 'INBOX', name: 'INBOX', srvName: 'INBOX'),
          DisplayPathRow(
            path: 'INBOX.Work',
            name: 'Job',
            srvName: 'Work',
            localName: 'Job',
          ),
          DisplayPathRow(path: 'INBOX.Work.2026', name: '2026'),
          DisplayPathRow(
            path: 'Mr. Smith',
            name: 'Smith',
            srvName: 'Mr. Smith',
            localName: 'Smith',
          ),
          DisplayPathRow(path: 'Archive/2025', name: '2025'),
        ],
        jmap: false,
      );
      expect(paths, {
        'INBOX': 'INBOX',
        'INBOX.Work': 'INBOX.Job',
        'INBOX.Work.2026': 'INBOX.Job.2026',
        'Mr. Smith': 'Smith',
        // No pending name, no cached parent: the server path as it is.
        'Archive/2025': 'Archive/2025',
      });
    });

    test('JMAP display paths: effective names along parentId', () {
      final paths = displayPaths(
        const [
          DisplayPathRow(path: 'p', name: 'Projects'),
          DisplayPathRow(path: '~new:1', name: '2026', parentId: 'p'),
          DisplayPathRow(path: 'c', name: 'Orphan', parentId: 'gone'),
        ],
        jmap: true,
      );
      expect(paths, {
        'p': 'Projects',
        '~new:1': 'Projects/2026',
        // An uncached parent truncates, never shows its id (#605).
        'c': 'Orphan',
      });
    });
  });

  group('IMAP', () {
    late RecordingAppLogRepository logs;

    setUp(() async => logs = await openRigInboxArchive());
    tearDown(() => db.close());

    Future<void> flush() => emails.flushPendingChanges(_acc.id, 'pw');
    // A flush with the network down: nothing is sent, nothing charged.
    Future<void> offlineFlush() => EmailRepositoryImpl(
          db,
          rig.accounts,
          imapConnect: (_, __, ___) =>
              Future.error(const SocketException('offline')),
        ).flushPendingChanges(_acc.id, 'pw');
    Future<List<String>> shownFolders() async => [
          for (final m in await rig.mailboxes.observeMailboxes(_acc.id).first)
            m.displayPath,
        ];
    Iterable<String> events() => logs.rows.map((r) => r.event);

    test(
        'offline: a folder created shows at once and mail moved into it '
        'waits; the next flush creates it, then moves the mail', () async {
      final folder = await rig.mailboxes.createMailbox(_acc.id, 'Projects');
      expect(folder.path, 'Projects');
      expect(await shownFolders(), contains('Projects'));
      final id = (await rowOfA()).id;
      await emails.moveEmail(id, 'Projects');
      expect((await rowOfA()).mailboxPath, 'Projects');

      await offlineFlush();
      expect(server.folders.keys, isNot(contains('Projects')));
      expect(
        (await db.select(db.pendingChanges).get()).map((o) => o.attempts),
        [0, 0],
      );
      await flush();

      expect(server.folderCommands, ['CREATE Projects']);
      expect(server.find('a@test')!.folder.path, 'Projects');
      final e = await rowOfA();
      expect(
        (e.id, e.mailboxPath, e.srvMailboxPath),
        (id, 'Projects', 'Projects'),
      );
      await _expectConsistent(db);

      // A folder listing confirms the create, the folder's sync the move.
      await rig.mailboxes.syncMailboxes(_acc.id);
      await emails.syncEmails(_acc.id, 'Projects');
      expect(await _ops(db), isEmpty);
      await _expectConsistent(db);
    });

    test(
        'a refused create fails, and the move waiting for it fails with it: '
        'the mail shows in its folder again', () async {
      server.refusesFolder = (path) => path == 'Bad';
      await rig.mailboxes.createMailbox(_acc.id, 'Bad');
      final id = (await rowOfA()).id;
      await emails.moveEmail(id, 'Bad');

      await flush();

      expect(await _ops(db), [
        ('create_mailbox', 'failed'),
        ('move', 'failed'),
      ]);
      final move = (await db.select(db.pendingChanges).get()).last;
      expect(move.lastError, contains('could not be created'));
      expect((await rowOfA()).mailboxPath, 'INBOX');
      expect(server.find('a@test')!.folder.path, 'INBOX');
      expect(await shownFolders(), isNot(contains('Bad')));
      expect(
        events(),
        containsAll([
          'pending_change.rejected',
          'pending_change.folder_not_created',
        ]),
      );
      final failed = await emails.observeFailedMutations(_acc.id).first;
      expect(
        failed.map((f) => f.changeType),
        containsAll(['create_mailbox', 'move']),
      );
      await _expectConsistent(db);

      // Retry: the folder shows again and is created at the next flush.
      server.refusesFolder = null;
      final create = (await db.select(db.pendingChanges).get()).first;
      await emails.retryMutation(create.id);
      expect(await shownFolders(), contains('Bad'));
      await flush();
      expect(server.folders.keys, contains('Bad'));
      await _expectConsistent(db);
    });

    test('a name the server has already is a failed change (no adoption)',
        () async {
      server.addFolder('Taken');
      await rig.mailboxes.createMailbox(_acc.id, 'Taken');

      await flush();

      expect(server.folderCommands, isEmpty);
      final change = await db.select(db.pendingChanges).getSingle();
      expect(change.state, 'failed');
      expect(change.lastError, contains('already exists'));
      await _expectConsistent(db);
    });

    test(
        'discarding a queued create removes the folder and fails the move '
        'waiting for it', () async {
      await rig.mailboxes.createMailbox(_acc.id, 'Later');
      final id = (await rowOfA()).id;
      await emails.moveEmail(id, 'Later');
      final create = (await db.select(db.pendingChanges).get()).first;

      await emails.discardMutation(create.id);

      expect(await shownFolders(), isNot(contains('Later')));
      expect(await _ops(db), [('move', 'failed')]);
      expect((await rowOfA()).mailboxPath, 'INBOX');
      await flush();
      expect(server.folderCommands, isEmpty);
      await _expectConsistent(db);
    });

    test(
        'deleting a folder created offline only gives up its creation, '
        'never asks the server', () async {
      await rig.mailboxes.createMailbox(_acc.id, 'Oops');

      await rig.mailboxes.deleteMailbox(_acc.id, 'Oops');

      expect(await shownFolders(), isNot(contains('Oops')));
      expect(await db.select(db.pendingChanges).get(), isEmpty);
      await _expectConsistent(db);
    });

    test(
        'offline rename shows at once; the flush renames, and the mail and '
        'the moves queued into the folder follow', () async {
      final archive = (await (db.select(db.mailboxes)
                ..where((t) => t.path.equals('Archive')))
              .getSingle())
          .id;
      final renamed =
          await rig.mailboxes.renameMailbox(_acc.id, 'Archive', 'Old Mail');
      expect((renamed.name, renamed.path), ('Old Mail', 'Archive'));
      expect(await shownFolders(), contains('Old Mail'));
      final id = (await rowOfA()).id;
      // Queued while the rename is: it names the folder by its path.
      await emails.moveEmail(id, 'Archive');

      await offlineFlush();
      expect(server.folders.keys, contains('Archive'));

      await flush();

      expect(server.folderCommands, ['RENAME Archive->Old Mail']);
      expect(server.find('a@test')!.folder.path, 'Old Mail');
      final row = await (db.select(db.mailboxes)
            ..where((t) => t.id.equals(archive)))
          .getSingle();
      expect(
        (row.path, row.name, row.srvName),
        ('Old Mail', 'Old Mail', 'Old Mail'),
      );
      final filler = await (db.select(db.emails)
            ..where((t) => t.messageId.equals('filler@test')))
          .getSingle();
      expect(filler.srvMailboxPath, 'Old Mail');
      expect(filler.mailboxPath, 'Old Mail');
      expect((await rowOfA()).mailboxPath, 'Old Mail');
      await _expectConsistent(db);

      await rig.mailboxes.syncMailboxes(_acc.id);
      expect(
        (await _ops(db)).where((o) => o.$1 == 'rename_mailbox'),
        isEmpty,
        reason: 'the listing confirmed the rename',
      );
      await _expectConsistent(db);
    });

    test(
        'a folder listing that started before the rename was confirmed '
        'neither brings the old folder back nor drops the renamed one',
        () async {
      await rig.mailboxes.renameMailbox(_acc.id, 'Archive', 'Old Mail');
      var flushed = false;
      server.beforeAnswer = (command) async {
        if (flushed || !command.startsWith('LIST')) return;
        flushed = true;
        // The answer (with "Archive") is fixed; the rename lands now.
        await flush();
      };

      await rig.mailboxes.syncMailboxes(_acc.id);
      server.beforeAnswer = null;

      expect(flushed, isTrue);
      final paths = (await db.select(db.mailboxes).get()).map((m) => m.path);
      expect(paths, unorderedEquals(['INBOX', 'Old Mail']));
      expect(await _ops(db), [('rename_mailbox', 'acked')]);

      // The next listing confirms it.
      await rig.mailboxes.syncMailboxes(_acc.id);
      expect(await _ops(db), isEmpty);
      await _expectConsistent(db);
    });

    test(
        'a folder another client deleted while its rename is queued: the '
        'rename fails, stays listed, and the App Log says so', () async {
      await rig.mailboxes.renameMailbox(_acc.id, 'Archive', 'Old Mail');
      server.folders.remove('Archive');

      await rig.mailboxes.syncMailboxes(_acc.id);

      final change = await db.select(db.pendingChanges).getSingle();
      expect((change.changeType, change.state), ('rename_mailbox', 'failed'));
      expect(change.lastError, 'folder removed on the server');
      expect(events(), contains('pending_change.folder_removed'));
      expect(await shownFolders(), ['INBOX']);
      await _expectConsistent(db);
    });

    test(
        'a folder created offline that another client created meanwhile is '
        'taken as created: no CREATE is sent', () async {
      await rig.mailboxes.createMailbox(_acc.id, 'Shared');
      server.addFolder('Shared');

      await rig.mailboxes.syncMailboxes(_acc.id);
      await flush();

      expect(server.folderCommands, isEmpty);
      expect(await _ops(db), [('create_mailbox', 'acked')]);
      final row = await (db.select(db.mailboxes)
            ..where((t) => t.path.equals('Shared')))
          .getSingle();
      expect(row.isLocal, isFalse);
      await _expectConsistent(db);
    });

    test('an acked rename a listing contradicts twice is dropped and logged',
        () async {
      final writer = MailboxStateWriter(db, appLogger: AppLogger(logs));
      await rig.mailboxes.renameMailbox(_acc.id, 'Archive', 'Old Mail');
      await flush();
      // Another client renamed it right after ours; our listings see the
      // folder at the same path under another name (as JMAP would).
      final row = await (db.select(db.mailboxes)
            ..where((t) => t.path.equals('Old Mail')))
          .getSingle();
      Future<void> listing(String name) async => writer.writeServer(
            accountId: _acc.id,
            path: 'Old Mail',
            name: name,
            role: row.role,
            parentId: null,
            unreadCount: 0,
            totalCount: 0,
            unreadSeq: 0,
            readSeq: await EmailStateWriter(db).nextReadSeq(),
          );

      await listing('Elsewhere');
      expect(await _ops(db), [('rename_mailbox', 'acked')]);
      expect(
        (await db.select(db.mailboxes).get())
            .singleWhere((m) => m.path == 'Old Mail')
            .name,
        'Old Mail',
        reason: 'one contradicting read is not enough',
      );
      await listing('Elsewhere');
      expect(await _ops(db), isEmpty);
      expect(
        (await db.select(db.mailboxes).get())
            .singleWhere((m) => m.path == 'Old Mail')
            .name,
        'Elsewhere',
      );
      await pumpEventQueue();
      expect(events(), contains('op.contradicted'));
    });
  });

  group('JMAP', () {
    final cacheDir = useJmapTestEnv('mailbox_ops_');
    const jmapAccount = Account(
      id: 'jmap-1',
      displayName: 'Alice',
      email: 'alice@example.com',
      type: AccountType.jmap,
      jmapUrl: 'https://jmap.example.com/.well-known/jmap',
    );

    late _JmapFolders server;
    late JmapTestRepos r;
    late MailboxRepositoryImpl mailboxes;

    setUp(() async {
      server = _JmapFolders();
      r = await openJmapTestRepos(
        httpClient: server.client,
        account: jmapAccount,
        cacheDir: cacheDir(),
      );
      mailboxes = MailboxRepositoryImpl(
        r.db,
        r.accounts,
        httpClient: server.client,
      );
      await mailboxes.syncMailboxes(jmapAccount.id);
      await insertJmapEmailRow(
        r.db,
        jmapAccount.id,
        'e1',
        mailboxPath: 'inbox',
      );
    });
    tearDown(() => r.db.close());

    Future<void> flush() => r.emails.flushPendingChanges(jmapAccount.id, 'pw');
    Future<Email> e1() => (r.db.select(r.db.emails)
          ..where((t) => t.id.equals('${jmapAccount.id}:e1')))
        .getSingle();

    test(
        'offline create, move into it, flush: the folder gets its server id, '
        'the move names it and lands there', () async {
      final folder = await mailboxes.createMailbox(jmapAccount.id, 'Projects');
      expect(folder.path, startsWith(localJmapMailboxPrefix));
      await r.emails.moveEmail('${jmapAccount.id}:e1', folder.path);
      expect((await e1()).mailboxPath, folder.path);

      // Offline: nothing is sent.
      server.offline = true;
      await flush();
      expect(server.created, isEmpty);
      server.offline = false;

      await flush();

      final id = server.created.single;
      expect(server.moves, {'e1': id});
      final row = await (r.db.select(r.db.mailboxes)
            ..where((t) => t.id.equals(folder.id)))
          .getSingle();
      expect((row.path, row.name, row.isLocal), (id, 'Projects', false));
      final e = await e1();
      expect((e.mailboxPath, e.srvMailboxPath), (id, id));
      await _expectConsistent(r.db);

      await mailboxes.syncMailboxes(jmapAccount.id);
      expect(
        (await _ops(r.db)).where((o) => o.$1 == 'create_mailbox'),
        isEmpty,
      );
      await _expectConsistent(r.db);
    });

    test(
        'a refused create fails the move waiting for it; the mail shows in '
        'its folder again', () async {
      server.refuseCreate = true;
      final folder = await mailboxes.createMailbox(jmapAccount.id, 'Bad');
      await r.emails.moveEmail('${jmapAccount.id}:e1', folder.path);

      await flush();

      expect(await _ops(r.db), [
        ('create_mailbox', 'failed'),
        ('move', 'failed'),
      ]);
      expect(server.moves, isEmpty);
      expect((await e1()).mailboxPath, 'inbox');
      final shown = await mailboxes.observeMailboxes(jmapAccount.id).first;
      expect(shown.map((m) => m.name), isNot(contains('Bad')));
      await _expectConsistent(r.db);
    });

    test(
        'offline rename shows at once; the flush sends it; the next listing '
        'confirms it', () async {
      final renamed =
          await mailboxes.renameMailbox(jmapAccount.id, 'archive', 'Old');
      expect(renamed.name, 'Old');
      expect(server.mailboxes['archive']!['name'], 'Archive');

      await flush();
      expect(server.mailboxes['archive']!['name'], 'Old');
      expect(await _ops(r.db), [('rename_mailbox', 'acked')]);

      await mailboxes.syncMailboxes(jmapAccount.id);
      expect(await _ops(r.db), isEmpty);
      final shown = await mailboxes.observeMailboxes(jmapAccount.id).first;
      expect(shown.singleWhere((m) => m.path == 'archive').name, 'Old');
      await _expectConsistent(r.db);
    });
  });
}

/// A JMAP server with a few mailboxes that creates and renames them and
/// moves mail ([moves]: email id → mailbox id).
class _JmapFolders {
  _JmapFolders() {
    client = jmapFakeServer(accountId: 'u1', handle: _handle, handleRaw: _raw);
  }

  late final http.Client client;
  bool offline = false;
  bool refuseCreate = false;
  final Map<String, Map<String, dynamic>> mailboxes = {
    'inbox': {'id': 'inbox', 'name': 'Inbox', 'role': 'inbox'},
    'archive': {'id': 'archive', 'name': 'Archive', 'role': 'archive'},
  };
  final List<String> created = [];
  final Map<String, String> moves = {};
  var _state = 1;

  http.Response? _raw(http.BaseRequest request) {
    if (offline) throw const SocketException('offline');
    return null;
  }

  List<dynamic>? _handle(JmapCall call) {
    switch (call.method) {
      case 'Mailbox/get':
        return [
          'Mailbox/get',
          {
            'accountId': 'u1',
            'state': 'm$_state',
            'list': [
              for (final m in mailboxes.values)
                {
                  ...m,
                  'parentId': m['parentId'],
                  'totalEmails': 0,
                  'unreadEmails': 0,
                },
            ],
          },
          call.callId,
        ];
      case 'Mailbox/changes':
        return [
          'Mailbox/changes',
          {
            'accountId': 'u1',
            'oldState': call.args['sinceState'],
            'newState': 'm$_state',
            'hasMoreChanges': false,
            'created': <String>[],
            'updated': mailboxes.keys.toList(),
            'destroyed': <String>[],
          },
          call.callId,
        ];
      case 'Mailbox/set':
        final result = <String, dynamic>{'accountId': 'u1'};
        final notCreated = <String, dynamic>{};
        final createdIds = <String, dynamic>{};
        final updated = <String, dynamic>{};
        final create = call.args['create'] as Map<String, dynamic>?;
        if (create != null) {
          for (final MapEntry(:key, :value) in create.entries) {
            if (refuseCreate) {
              notCreated[key] = {'type': 'invalidProperties'};
              continue;
            }
            final id = 'mbx-${created.length + 1}';
            created.add(id);
            mailboxes[id] = {
              'id': id,
              ...(value as Map<String, dynamic>),
            };
            createdIds[key] = {'id': id};
          }
        }
        final update = call.args['update'] as Map<String, dynamic>?;
        if (update != null) {
          for (final MapEntry(:key, :value) in update.entries) {
            mailboxes[key]!.addAll(value as Map<String, dynamic>);
            updated[key] = null;
          }
        }
        if (notCreated.isNotEmpty) result['notCreated'] = notCreated;
        if (createdIds.isNotEmpty) result['created'] = createdIds;
        if (updated.isNotEmpty) result['updated'] = updated;
        _state++;
        return ['Mailbox/set', result, call.callId];
      case 'Email/set':
        final update = call.args['update'] as Map<String, dynamic>;
        for (final MapEntry(:key, :value) in update.entries) {
          final ids = (value as Map<String, dynamic>)['mailboxIds'];
          if (ids is Map) moves[key] = ids.keys.single as String;
        }
        return [
          'Email/set',
          {
            'accountId': 'u1',
            'updated': {for (final id in update.keys) id: null},
          },
          call.callId,
        ];
    }
    return null;
  }
}
