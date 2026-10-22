import 'package:drift/drift.dart' show Value;
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/draft_repository_impl.dart';

import 'db_test_helper.dart';
import 'fake_imap.dart';
import 'helpers/jmap_test_server.dart';

class _StubAccounts implements AccountRepository {
  @override
  Stream<List<Account>> observeAccounts() => const Stream.empty();
  @override
  Future<Account?> getAccount(String id) async => null;
  @override
  Future<void> addAccount(Account account, String password) async {}
  @override
  Future<void> updateAccount(Account account, {String? password}) async {}
  @override
  Future<void> removeAccount(String id) async {}
  @override
  Future<String> getPassword(String accountId) async => '';
}

final _gmailDrafts = imap.Mailbox(
  encodedName: 'Drafts',
  encodedPath: '[Gmail]/Drafts',
  pathSeparator: '/',
  flags: [imap.MailboxFlag.drafts],
);

/// Accounts stub with one IMAP account.
class _ImapAccounts extends _StubAccounts {
  @override
  Future<Account?> getAccount(String id) async => const Account(
        id: 'acc-1',
        displayName: 'Bob',
        email: 'bob@example.com',
        imapHost: 'imap.example.com',
        smtpHost: 'smtp.example.com',
      );
}

/// Records which folder draft sync creates, selects and appends to.
class _DraftsSpyImapClient extends SelectingFakeImapClient
    with StubMailboxList {
  final created = <String>[];
  final selected = <String>[];
  final appendedTo = <String?>[];

  /// UIDs reported back in `APPENDUID`, one per append; none when empty.
  final appendUids = <int>[];

  /// Runs while an append is in flight, e.g. to edit the draft meanwhile.
  Future<void> Function()? onAppend;

  /// What `UID SEARCH` finds in the drafts mailbox.
  List<int> serverUids = [];

  @override
  Future<imap.Mailbox> createMailbox(String path) async {
    created.add(path);
    return fakeMailbox(path);
  }

  @override
  Future<imap.Mailbox> selectMailboxByPath(
    String path, {
    bool enableCondStore = false,
    imap.QResyncParameters? qresync,
  }) {
    selected.add(path);
    return super.selectMailboxByPath(path);
  }

  @override
  Future<imap.GenericImapResult> appendMessage(
    imap.MimeMessage message, {
    List<String>? flags,
    imap.Mailbox? targetMailbox,
    String? targetMailboxPath,
    Duration? responseTimeout,
  }) async {
    appendedTo.add(targetMailboxPath);
    await onAppend?.call();
    final result = imap.GenericImapResult();
    if (appendUids.isNotEmpty) {
      result.responseCode = 'APPENDUID 1 ${appendUids.removeAt(0)}';
    }
    return result;
  }

  final expunged = <imap.MessageSequence>[];
  List<imap.Mailbox> listed = [];

  @override
  List<imap.Mailbox> get listedMailboxes => listed;

  @override
  Future<imap.StoreImapResult> uidMarkDeleted(
    imap.MessageSequence sequence, {
    bool? silent,
    int? unchangedSinceModSequence,
  }) async =>
      imap.StoreImapResult();

  @override
  Future<imap.Mailbox> uidExpunge(imap.MessageSequence sequence) async {
    expunged.add(sequence);
    return fakeMailbox('x');
  }

  @override
  Future<imap.SearchImapResult> uidSearchMessages({
    String searchCriteria = 'UNSEEN',
    List<imap.ReturnOption>? returnOptions,
    Duration? responseTimeout,
  }) async =>
      imap.SearchImapResult()
        ..matchingSequence = serverUids.isEmpty
            ? null
            : imap.MessageSequence.fromIds(serverUids, isUid: true);
}

/// Accounts stub with one JMAP account.
class _JmapAccounts extends _StubAccounts {
  @override
  Future<Account?> getAccount(String id) async => const Account(
        id: 'acc-1',
        displayName: 'Bob',
        email: 'bob@example.com',
        type: AccountType.jmap,
        jmapUrl: 'https://jmap.example.com/.well-known/jmap',
      );
}

void main() {
  setUpAll(configureSqliteForTests);

  group('DraftRepositoryImpl', () {
    test(
      'saveDraft creates a new row and returns it with a non-zero id',
      () async {
        final repo = DraftRepositoryImpl(openTestDatabase(), _StubAccounts());
        final draft = await repo.saveDraft(
          toText: 'bob@example.com',
          ccText: '',
          subjectText: 'Hello',
          bodyText: 'Hi',
        );
        expect(draft.id, isNonZero);
        expect(draft.toText, 'bob@example.com');
        expect(draft.subjectText, 'Hello');
        expect(draft.dirty, isTrue);
      },
    );

    test('saveDraft with id updates existing row', () async {
      final repo = DraftRepositoryImpl(openTestDatabase(), _StubAccounts());
      final created = await repo.saveDraft(
        toText: 'a@example.com',
        ccText: '',
        subjectText: 'First',
        bodyText: '',
      );
      final updated = await repo.saveDraft(
        id: created.id,
        toText: 'b@example.com',
        ccText: '',
        subjectText: 'Updated',
        bodyText: 'body',
      );
      expect(updated.id, created.id);
      expect(updated.subjectText, 'Updated');

      final fetched = await repo.getDraft(created.id);
      expect(fetched?.subjectText, 'Updated');
    });

    test('getDraft returns null for unknown id', () async {
      final repo = DraftRepositoryImpl(openTestDatabase(), _StubAccounts());
      expect(await repo.getDraft(99999), isNull);
    });

    test('listNewMessageDrafts is empty when no draft exists', () async {
      final repo = DraftRepositoryImpl(openTestDatabase(), _StubAccounts());
      expect(await repo.listNewMessageDrafts(), isEmpty);
    });

    test(
      'listNewMessageDrafts returns new-message drafts newest first and '
      'skips reply drafts',
      () async {
        final repo = DraftRepositoryImpl(openTestDatabase(), _StubAccounts());
        final older = await repo.saveDraft(
          toText: 'a@example.com',
          ccText: '',
          subjectText: 'Older',
          bodyText: '',
        );
        // This draft is a reply and should NOT be returned.
        await repo.saveDraft(
          replyToEmailId: 'email-1',
          toText: 'x@example.com',
          ccText: '',
          subjectText: 'Reply draft',
          bodyText: '',
        );
        final newer = await repo.saveDraft(
          toText: 'b@example.com',
          ccText: '',
          subjectText: 'Newer',
          bodyText: '',
        );
        final found = await repo.listNewMessageDrafts();
        expect(found.map((d) => d.id), [newer.id, older.id]);
      },
    );

    test(
      'listNewMessageDrafts scopes the list to the given accountId',
      () async {
        final repo = DraftRepositoryImpl(openTestDatabase(), _StubAccounts());
        final imapDraft = await repo.saveDraft(
          accountId: 'imap-1',
          toText: 'a@example.com',
          ccText: '',
          subjectText: 'IMAP draft',
          bodyText: '',
        );
        final jmapDraft = await repo.saveDraft(
          accountId: 'jmap-1',
          toText: 'b@example.com',
          ccText: '',
          subjectText: 'JMAP draft',
          bodyText: '',
        );

        final imapFound = await repo.listNewMessageDrafts(accountId: 'imap-1');
        expect(imapFound.map((d) => d.id), [imapDraft.id]);

        final jmapFound = await repo.listNewMessageDrafts(accountId: 'jmap-1');
        expect(jmapFound.map((d) => d.id), [jmapDraft.id]);

        // Without an accountId, every account's drafts are returned.
        final all = await repo.listNewMessageDrafts();
        expect(all.map((d) => d.id), [jmapDraft.id, imapDraft.id]);

        expect(await repo.listNewMessageDrafts(accountId: 'other'), isEmpty);
      },
    );

    test('deleteDraft removes the row', () async {
      final repo = DraftRepositoryImpl(openTestDatabase(), _StubAccounts());
      final draft = await repo.saveDraft(
        toText: 'a@example.com',
        ccText: '',
        subjectText: 'To delete',
        bodyText: '',
      );
      await repo.deleteDraft(draft.id);
      expect(await repo.getDraft(draft.id), isNull);
    });

    test('saveDraft marks updated rows dirty so the next sync pushes them',
        () async {
      final db = openTestDatabase();
      final repo = DraftRepositoryImpl(db, _StubAccounts());
      final draft = await repo.saveDraft(
        accountId: 'acc-1',
        toText: 'a@example.com',
        ccText: '',
        subjectText: 'New',
        bodyText: '',
      );
      // Simulate a successful push that cleared the dirty flag.
      await (db.update(db.drafts)..where((t) => t.id.equals(draft.id))).write(
        const DraftsCompanion(
          dirty: Value(false),
          imapServerId: Value('42'),
        ),
      );
      final pushed = await repo.getDraft(draft.id);
      expect(pushed?.dirty, isFalse);

      // A subsequent edit must flip dirty back to true.
      await repo.saveDraft(
        id: draft.id,
        accountId: 'acc-1',
        toText: 'a@example.com',
        ccText: '',
        subjectText: 'Edited',
        bodyText: 'changed',
      );
      final edited = await repo.getDraft(draft.id);
      expect(edited?.dirty, isTrue);
      expect(edited?.imapServerId, '42');
    });

    AccountsCompanion accountRow(String id) => AccountsCompanion.insert(
          id: id,
          displayName: id,
          email: '$id@example.com',
          imapHost: '',
          imapPort: 993,
          imapSsl: true,
          smtpHost: '',
          smtpPort: 465,
          smtpSsl: true,
        );

    /// Saves a draft for acc-1 and marks it as pushed to the server
    /// under IMAP UID 17, as a completed sync would.
    Future<int> saveSyncedDraft(
      AppDatabase db,
      DraftRepositoryImpl repo,
    ) async {
      final draft = await repo.saveDraft(
        accountId: 'acc-1',
        toText: 'a@example.com',
        ccText: '',
        subjectText: 'Synced',
        bodyText: '',
      );
      await (db.update(db.drafts)..where((t) => t.id.equals(draft.id))).write(
        const DraftsCompanion(dirty: Value(false), imapServerId: Value('17')),
      );
      return draft.id;
    }

    test(
        'switching the account of a synced draft forgets its server id '
        'and queues the old copy for removal', () async {
      final db = openTestDatabase();
      for (final id in ['acc-1', 'acc-2']) {
        await db.into(db.accounts).insert(accountRow(id));
      }
      final repo = DraftRepositoryImpl(db, _StubAccounts());
      final draftId = await saveSyncedDraft(db, repo);

      await repo.saveDraft(
        id: draftId,
        accountId: 'acc-2',
        toText: 'a@example.com',
        ccText: '',
        subjectText: 'Synced',
        bodyText: '',
      );

      final moved = await repo.getDraft(draftId);
      expect(moved?.accountId, 'acc-2');
      // UID 17 means nothing in acc-2's Drafts folder: pushing must append
      // a fresh copy, not expunge acc-2's message 17.
      expect(moved?.imapServerId, isNull);
      expect(moved?.dirty, isTrue);
      final tombstones = await db.select(db.draftTombstones).get();
      expect(tombstones.single.accountId, 'acc-1');
      expect(tombstones.single.serverId, '17');
    });

    test('a draft of a deleted account can move to another account', () async {
      final db = openTestDatabase();
      await db.into(db.accounts).insert(accountRow('acc-2'));
      final repo = DraftRepositoryImpl(db, _StubAccounts());
      // acc-1 is gone; its draft stayed behind.
      final draft = await repo.saveDraft(
        accountId: 'acc-1',
        toText: '',
        ccText: '',
        subjectText: 'Orphan',
        bodyText: '',
      );
      await (db.update(db.drafts)..where((t) => t.id.equals(draft.id))).write(
        const DraftsCompanion(jmapServerId: Value('M42')),
      );

      await repo.saveDraft(
        id: draft.id,
        accountId: 'acc-2',
        toText: '',
        ccText: '',
        subjectText: 'Orphan',
        bodyText: '',
      );

      final moved = await repo.getDraft(draft.id);
      expect(moved?.accountId, 'acc-2');
      expect(moved?.jmapServerId, isNull);
      expect(await db.select(db.draftTombstones).get(), isEmpty);
    });

    test('deleteDraft of a deleted account works with foreign keys on',
        () async {
      // clearForResync switches foreign_keys on for the shared connection;
      // a tombstone for a missing account then fails the insert.
      final db = openTestDatabase();
      await db.customStatement('PRAGMA foreign_keys = ON');
      final repo = DraftRepositoryImpl(db, _StubAccounts());
      final draft = await repo.saveDraft(
        accountId: 'gone',
        toText: '',
        ccText: '',
        subjectText: 'Orphan',
        bodyText: '',
      );
      await (db.update(db.drafts)..where((t) => t.id.equals(draft.id))).write(
        const DraftsCompanion(imapServerId: Value('9')),
      );

      await repo.deleteDraft(draft.id);

      expect(await repo.getDraft(draft.id), isNull);
      expect(await db.select(db.draftTombstones).get(), isEmpty);
    });

    test('deleteDraft writes a tombstone when the row had a server id',
        () async {
      final db = openTestDatabase();
      await db.into(db.accounts).insert(accountRow('acc-1'));
      final repo = DraftRepositoryImpl(db, _StubAccounts());
      final draftId = await saveSyncedDraft(db, repo);

      await repo.deleteDraft(draftId);

      final tombstones = await db.select(db.draftTombstones).get();
      expect(tombstones, hasLength(1));
      expect(tombstones.single.serverId, '17');
      expect(tombstones.single.accountId, 'acc-1');
    });

    test('deleteDraft does not write a tombstone for unsynced rows', () async {
      final db = openTestDatabase();
      final repo = DraftRepositoryImpl(db, _StubAccounts());
      final draft = await repo.saveDraft(
        accountId: 'acc-1',
        toText: 'a@example.com',
        ccText: '',
        subjectText: 'Local only',
        bodyText: '',
      );
      await repo.deleteDraft(draft.id);

      final tombstones = await db.select(db.draftTombstones).get();
      expect(tombstones, isEmpty);
    });

    /// A repo for the IMAP account whose connections all go to [client].
    DraftRepositoryImpl imapRepo(
      AppDatabase db,
      _DraftsSpyImapClient client,
    ) =>
        DraftRepositoryImpl(
          db,
          _ImapAccounts(),
          imapConnect: (_, __, ___) async => client,
        );

    /// Saves a not yet synced draft for acc-1.
    Future<int> saveNewDraft(DraftRepositoryImpl repo) async {
      final draft = await repo.saveDraft(
        accountId: 'acc-1',
        toText: 'alice@example.com',
        ccText: '',
        subjectText: 'Hi',
        bodyText: 'Draft',
      );
      return draft.id;
    }

    /// Edits draft [id] of [accountId] as compose would.
    Future<void> editDraft(
      DraftRepositoryImpl repo,
      int id, {
      String accountId = 'acc-1',
      String bodyText = 'Edited',
    }) =>
        repo.saveDraft(
          id: id,
          accountId: accountId,
          toText: 'alice@example.com',
          ccText: '',
          subjectText: 'Hi',
          bodyText: bodyText,
        );

    test('an edit during the IMAP append is pushed by the next sync', () async {
      final db = openTestDatabase();
      final client = _DraftsSpyImapClient()..appendUids.addAll([42, 43]);
      final repo = imapRepo(db, client);
      final id = await saveNewDraft(repo);
      client.onAppend = () async {
        client.onAppend = null;
        await editDraft(repo, id);
      };

      await repo.syncDrafts('acc-1');

      // The edit is not lost: the row stays dirty, and remembers the copy
      // just appended so the next push replaces it.
      var row = await repo.getDraft(id);
      expect(row?.bodyText, 'Edited');
      expect(row?.imapServerId, '42');
      expect(row?.dirty, isTrue);

      client.serverUids = [43];
      await repo.syncDrafts('acc-1');

      row = await repo.getDraft(id);
      expect(client.appendedTo, hasLength(2));
      expect(client.expunged.single.toList(), [42]);
      expect(row?.imapServerId, '43');
      expect(row?.dirty, isFalse);
    });

    Future<AppDatabase> dbWithTwoAccounts() async {
      final db = openTestDatabase();
      for (final id in ['acc-1', 'acc-2']) {
        await db.into(db.accounts).insert(accountRow(id));
      }
      return db;
    }

    /// Syncs acc-1 while [meanwhile] changes its new draft during the append
    /// (which gets UID 42). Returns the draft as it is afterwards, once the
    /// checks common to a move and a delete have passed: UID 42 is queued
    /// for removal, is not imported back, and the next sync expunges it.
    Future<Draft?> raceImapAppend(
      Future<void> Function(DraftRepositoryImpl repo, int id) meanwhile,
    ) async {
      final db = await dbWithTwoAccounts();
      final client = _DraftsSpyImapClient()
        ..appendUids.add(42)
        ..serverUids = [42];
      final repo = imapRepo(db, client);
      final id = await saveNewDraft(repo);
      client.onAppend = () => meanwhile(repo, id);

      await repo.syncDrafts('acc-1');

      final rows = await db.select(db.drafts).get();
      expect(rows.where((r) => r.imapServerId == '42'), isEmpty);
      expect(rows.length, lessThanOrEqualTo(1));
      final tombstone = (await db.select(db.draftTombstones).get()).single;
      expect(tombstone.accountId, 'acc-1');
      expect(tombstone.serverId, '42');

      client
        ..onAppend = null
        ..serverUids = [];
      await repo.syncDrafts('acc-1');

      expect(client.expunged.single.toList(), [42]);
      expect(await db.select(db.draftTombstones).get(), isEmpty);
      return rows.isEmpty ? null : rows.single;
    }

    test(
        'an account switch during the IMAP append removes the copy it made '
        'on the old account', () async {
      final row = await raceImapAppend(
        (repo, id) => editDraft(repo, id, accountId: 'acc-2'),
      );
      expect(row?.accountId, 'acc-2');
      expect(row?.dirty, isTrue);
    });

    test('a delete during the IMAP append removes the copy it made', () async {
      final row = await raceImapAppend((repo, id) => repo.deleteDraft(id));
      expect(row, isNull);
    });

    /// A repo for the JMAP account acc-1 whose fake server keeps the drafts
    /// it is sent (as M1, M2, …) and records every `Email/set` in [sets].
    /// [duringFirstSet] runs while the first one is in flight. The server
    /// answers no `Email/get`, so a pull may only find drafts it knows.
    Future<(DraftRepositoryImpl, int)> jmapRepo(
      AppDatabase db,
      List<Map<String, dynamic>> sets,
      Future<void> Function(DraftRepositoryImpl repo, int id) duringFirstSet,
    ) async {
      late DraftRepositoryImpl repo;
      late int id;
      final onServer = <String>[];
      final server = jmapFakeServer(
        accountId: 'u1',
        handle: (call) async {
          switch (call.method) {
            case 'Mailbox/get':
              return [
                'Mailbox/get',
                {
                  'list': [
                    {'id': 'mb-drafts', 'name': 'Drafts', 'role': 'drafts'},
                  ],
                },
                call.callId,
              ];
            case 'Email/set':
              sets.add(call.args);
              final destroy = (call.args['destroy'] as List?) ?? const [];
              onServer.removeWhere(destroy.contains);
              if (!call.args.containsKey('create')) {
                return [
                  'Email/set',
                  {'destroyed': destroy},
                  call.callId,
                ];
              }
              if (sets.length == 1) await duringFirstSet(repo, id);
              final newId = 'M${sets.length}';
              onServer.add(newId);
              return [
                'Email/set',
                {
                  'created': {
                    'draft': {'id': newId},
                  },
                },
                call.callId,
              ];
            case 'Email/query':
              return [
                'Email/query',
                {'ids': List.of(onServer)},
                call.callId,
              ];
          }
          return null;
        },
      );
      repo = DraftRepositoryImpl(db, _JmapAccounts(), httpClient: server);
      id = await saveNewDraft(repo);
      return (repo, id);
    }

    test('an edit during the JMAP push is pushed by the next sync', () async {
      final db = openTestDatabase();
      final sets = <Map<String, dynamic>>[];
      final (repo, id) = await jmapRepo(db, sets, editDraft);

      await repo.syncDrafts('acc-1');

      var row = await repo.getDraft(id);
      expect(row?.jmapServerId, 'M1');
      expect(row?.dirty, isTrue);

      await repo.syncDrafts('acc-1');

      // The second push replaces the copy the first one made.
      row = await repo.getDraft(id);
      expect(sets, hasLength(2));
      expect(sets[1]['destroy'], ['M1']);
      expect(row?.jmapServerId, 'M2');
      expect(row?.dirty, isFalse);
    });

    test(
        'an account switch during the JMAP push removes the copy it made '
        'on the old account', () async {
      final db = await dbWithTwoAccounts();
      final sets = <Map<String, dynamic>>[];
      final (repo, id) = await jmapRepo(
        db,
        sets,
        (repo, id) => editDraft(repo, id, accountId: 'acc-2'),
      );

      await repo.syncDrafts('acc-1');

      // M1 is still on acc-1's server, but queued for removal: the pull
      // must not import it back.
      final row = await repo.getDraft(id);
      expect(row?.accountId, 'acc-2');
      expect(row?.jmapServerId, isNull);
      expect(await db.select(db.drafts).get(), hasLength(1));
      final tombstone = (await db.select(db.draftTombstones).get()).single;
      expect(tombstone.accountId, 'acc-1');
      expect(tombstone.serverId, 'M1');

      await repo.syncDrafts('acc-1');

      expect(sets.last['destroy'], ['M1']);
      expect(await db.select(db.draftTombstones).get(), isEmpty);
    });

    test('IMAP sync uses the server\'s drafts mailbox, not its own "Drafts"',
        () async {
      final db = openTestDatabase();
      final client = _DraftsSpyImapClient()..listed = [_gmailDrafts];
      final repo = imapRepo(db, client);
      await saveNewDraft(repo);

      await repo.syncDrafts('acc-1');

      expect(client.created, isEmpty);
      expect(client.selected, ['[Gmail]/Drafts']);
      expect(client.appendedTo, ['[Gmail]/Drafts']);
    });

    test(
        'a switch of drafts mailbox re-uploads drafts instead of expunging '
        'their old UIDs there', () async {
      final db = openTestDatabase();
      // Synced by an older build into its own "Drafts" folder as UID 7, and a
      // deleted draft that was UID 9 there.
      await db.into(db.drafts).insert(
            DraftsCompanion.insert(
              accountId: const Value('acc-1'),
              toText: const Value('alice@example.com'),
              subjectText: const Value('Old draft'),
              updatedAt: DateTime(2026),
              imapServerId: const Value('7'),
              dirty: const Value(false),
            ),
          );
      await db.into(db.draftTombstones).insert(
            DraftTombstonesCompanion.insert(
              accountId: 'acc-1',
              serverId: '9',
              createdAt: DateTime(2026),
            ),
          );
      final client = _DraftsSpyImapClient()..listed = [_gmailDrafts];
      final repo = imapRepo(db, client);

      await repo.syncDrafts('acc-1');

      // UIDs 7 and 9 belong to the old folder: nothing is expunged in the
      // new one, and the draft is uploaded there as a new message.
      expect(client.expunged, isEmpty);
      expect(client.appendedTo, ['[Gmail]/Drafts']);
      expect(await db.select(db.draftTombstones).get(), isEmpty);
    });

    test('a second sync stays with the same mailbox', () async {
      final db = openTestDatabase();
      final client = _DraftsSpyImapClient()..listed = [_gmailDrafts];
      final repo = imapRepo(db, client);
      await saveNewDraft(repo);

      await repo.syncDrafts('acc-1');
      await repo.syncDrafts('acc-1');

      // The draft went up once, and the mailbox in use is remembered, so the
      // next sync sees no switch to undo.
      expect(client.created, isEmpty);
      expect(client.appendedTo, ['[Gmail]/Drafts']);
      final state = await (db.select(db.syncStates)
            ..where((t) => t.resourceType.equals('IMAP:DraftsMailbox')))
          .getSingle();
      expect(state.state, '[Gmail]/Drafts');
    });

    test('a non-ASCII drafts mailbox is addressed in modified UTF-7', () async {
      final db = openTestDatabase();
      final client = _DraftsSpyImapClient()
        ..listed = [
          // A user folder named "Drafts" is not the drafts mailbox: only the
          // server's \Drafts flag counts.
          imap.Mailbox(
            encodedName: 'Drafts',
            encodedPath: 'Projects/Drafts',
            pathSeparator: '/',
            flags: [],
          ),
          imap.Mailbox(
            encodedName: 'Entw&APw-rfe',
            encodedPath: 'Entw&APw-rfe',
            pathSeparator: '/',
            flags: [imap.MailboxFlag.drafts],
          ),
        ];
      final repo = imapRepo(db, client);
      await saveNewDraft(repo);

      await repo.syncDrafts('acc-1');

      expect(client.selected, ['Entw&APw-rfe']);
      expect(client.appendedTo, ['Entw&APw-rfe']);
    });
  });
}
