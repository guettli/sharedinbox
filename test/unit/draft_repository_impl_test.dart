import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/draft_repository_impl.dart';

import 'db_test_helper.dart';

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

    test('findDraft returns null when no draft exists', () async {
      final repo = DraftRepositoryImpl(openTestDatabase(), _StubAccounts());
      expect(await repo.findDraft(), isNull);
    });

    test(
      'findDraft returns most recent draft for matching replyToEmailId',
      () async {
        final repo = DraftRepositoryImpl(openTestDatabase(), _StubAccounts());
        await repo.saveDraft(
          replyToEmailId: 'email-1',
          toText: 'a@example.com',
          ccText: '',
          subjectText: 'Older',
          bodyText: '',
        );
        final newer = await repo.saveDraft(
          replyToEmailId: 'email-1',
          toText: 'a@example.com',
          ccText: '',
          subjectText: 'Newer',
          bodyText: 'body',
        );
        final found = await repo.findDraft(replyToEmailId: 'email-1');
        expect(found?.id, newer.id);
        expect(found?.subjectText, 'Newer');
      },
    );

    test(
      'findDraft with null replyToEmailId finds new-message drafts',
      () async {
        final repo = DraftRepositoryImpl(openTestDatabase(), _StubAccounts());
        // This draft is a reply and should NOT be returned.
        await repo.saveDraft(
          replyToEmailId: 'email-1',
          toText: 'x@example.com',
          ccText: '',
          subjectText: 'Reply draft',
          bodyText: '',
        );
        final newMsg = await repo.saveDraft(
          toText: 'y@example.com',
          ccText: '',
          subjectText: 'New draft',
          bodyText: '',
        );
        final found = await repo.findDraft();
        expect(found?.id, newMsg.id);
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
  });
}
