import 'package:drift/drift.dart' show Value;
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/draft_repository_impl.dart';

import 'db_test_helper.dart';
import 'fake_imap.dart';

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
class _DraftsSpyImapClient extends SelectingFakeImapClient {
  final created = <String>[];
  final selected = <String>[];
  final appendedTo = <String?>[];

  @override
  Future<imap.Mailbox> createMailbox(String path) async {
    created.add(path);
    return imap.Mailbox(
      encodedName: path,
      encodedPath: path,
      pathSeparator: '/',
      flags: [],
    );
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
    return imap.GenericImapResult();
  }

  final expunged = <imap.MessageSequence>[];
  List<imap.Mailbox> listed = [];

  @override
  Future<List<imap.Mailbox>> listMailboxes({
    String path = '""',
    bool recursive = false,
    List<String>? mailboxPatterns,
    List<String>? selectionOptions,
    List<imap.ReturnOption>? returnOptions,
  }) async =>
      listed;

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
    return imap.Mailbox(
      encodedName: 'x',
      encodedPath: 'x',
      pathSeparator: '/',
      flags: [],
    );
  }

  @override
  Future<imap.SearchImapResult> uidSearchMessages({
    String searchCriteria = 'UNSEEN',
    List<imap.ReturnOption>? returnOptions,
    Duration? responseTimeout,
  }) async =>
      imap.SearchImapResult();
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

    test('deleteDraft writes a tombstone when the row had a server id',
        () async {
      final db = openTestDatabase();
      await db.into(db.accounts).insert(
            AccountsCompanion.insert(
              id: 'acc-1',
              displayName: 'A',
              email: 'a@example.com',
              imapHost: '',
              imapPort: 993,
              imapSsl: true,
              smtpHost: '',
              smtpPort: 465,
              smtpSsl: true,
            ),
          );
      final repo = DraftRepositoryImpl(db, _StubAccounts());
      final draft = await repo.saveDraft(
        accountId: 'acc-1',
        toText: 'a@example.com',
        ccText: '',
        subjectText: 'Synced',
        bodyText: '',
      );
      await (db.update(db.drafts)..where((t) => t.id.equals(draft.id))).write(
        const DraftsCompanion(
          dirty: Value(false),
          imapServerId: Value('17'),
        ),
      );

      await repo.deleteDraft(draft.id);

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

    test('IMAP sync uses the server\'s drafts mailbox, not its own "Drafts"',
        () async {
      final db = openTestDatabase();
      final client = _DraftsSpyImapClient()..listed = [_gmailDrafts];
      final repo = DraftRepositoryImpl(
        db,
        _ImapAccounts(),
        imapConnect: (_, __, ___) async => client,
      );
      await repo.saveDraft(
        accountId: 'acc-1',
        toText: 'alice@example.com',
        ccText: '',
        subjectText: 'Hi',
        bodyText: 'Draft',
      );

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
      final repo = DraftRepositoryImpl(
        db,
        _ImapAccounts(),
        imapConnect: (_, __, ___) async => client,
      );

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
      final repo = DraftRepositoryImpl(
        db,
        _ImapAccounts(),
        imapConnect: (_, __, ___) async => client,
      );
      await repo.saveDraft(
        accountId: 'acc-1',
        toText: 'alice@example.com',
        ccText: '',
        subjectText: 'Hi',
        bodyText: 'Draft',
      );

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
      final repo = DraftRepositoryImpl(
        db,
        _ImapAccounts(),
        imapConnect: (_, __, ___) async => client,
      );
      await repo.saveDraft(
        accountId: 'acc-1',
        toText: 'alice@example.com',
        ccText: '',
        subjectText: 'Hi',
        bodyText: 'Draft',
      );

      await repo.syncDrafts('acc-1');

      expect(client.selected, ['Entw&APw-rfe']);
      expect(client.appendedTo, ['Entw&APw-rfe']);
    });
  });
}
