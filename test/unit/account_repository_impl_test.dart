import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/storage/secure_storage.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';

import 'db_test_helper.dart';

// ── Fake ──────────────────────────────────────────────────────────────────────

class MapSecureStorage implements SecureStorage {
  final _map = <String, String>{};

  @override
  Future<void> write({required String key, required String? value}) async {
    if (value == null) {
      _map.remove(key);
    } else {
      _map[key] = value;
    }
  }

  @override
  Future<String?> read({required String key}) async => _map[key];

  @override
  Future<void> delete({required String key}) async => _map.remove(key);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

const _account = Account(
  id: 'acc-1',
  displayName: 'Alice',
  email: 'alice@example.com',
  imapHost: 'imap.example.com',
  smtpHost: 'smtp.example.com',
);

AccountRepositoryImpl _makeRepo() =>
    AccountRepositoryImpl(openTestDatabase(), MapSecureStorage());

/// Seeds an inbox mailbox, one mail with a body, its thread and an undo-log
/// entry for [accountId], straight into [db]. Needs the account row unless
/// run inside [withoutForeignKeys].
Future<void> _seedMailOf(AppDatabase db, String accountId) async {
  await seedInboxMailbox(db, accountId);
  await db.into(db.emails).insert(
        EmailsCompanion.insert(
          id: '$accountId:INBOX:1',
          accountId: accountId,
          mailboxPath: 'INBOX',
          uid: 1,
          receivedAt: DateTime(2024, 6),
        ),
      );
  await db.into(db.emailBodies).insert(
        EmailBodiesCompanion.insert(
          emailId: '$accountId:INBOX:1',
          textBody: const Value('hello'),
        ),
      );
  await db.into(db.threads).insert(
        ThreadsCompanion.insert(
          id: '$accountId:t1',
          accountId: accountId,
          mailboxPath: 'INBOX',
          latestDate: DateTime(2024, 6),
          latestEmailId: '$accountId:INBOX:1',
        ),
      );
  await db.into(db.undoActions).insert(
        UndoActionsCompanion.insert(
          id: '$accountId:u1',
          accountId: accountId,
          dataJson: '{}',
          createdAt: DateTime(2024, 6),
        ),
      );
  final syncLogId = await db.into(db.syncLogs).insert(
        SyncLogsCompanion.insert(
          accountId: accountId,
          result: 'ok',
          startedAt: DateTime(2024, 6),
          finishedAt: DateTime(2024, 6),
        ),
      );
  await db.into(db.syncLogMailboxes).insert(
        SyncLogMailboxesCompanion.insert(
          syncLogId: syncLogId,
          mailboxPath: 'INBOX',
        ),
      );
  await db.into(db.appLogs).insert(
        AppLogsCompanion.insert(
          createdAt: DateTime(2024, 6),
          level: 'info',
          event: 'test',
          message: accountId,
          accountId: Value(accountId),
          emailId: Value('$accountId:INBOX:1'),
          syncLogId: Value(syncLogId),
        ),
      );
  await db.into(db.drafts).insert(
        DraftsCompanion.insert(
          accountId: Value(accountId),
          subjectText: Value('draft of $accountId'),
          updatedAt: DateTime(2024, 6),
          imapServerId: const Value('7'),
        ),
      );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUpAll(configureSqliteForTests);

  group('AccountRepositoryImpl', () {
    test('observeAccounts emits empty list initially', () async {
      final repo = _makeRepo();
      final accounts = await repo.observeAccounts().first;
      expect(accounts, isEmpty);
    });

    test('addAccount then observeAccounts emits the account', () async {
      final repo = _makeRepo();
      await repo.addAccount(_account, 'secret');
      final accounts = await repo.observeAccounts().first;
      expect(accounts, hasLength(1));
      expect(accounts.first.id, 'acc-1');
      expect(accounts.first.email, 'alice@example.com');
    });

    test('removeAccount deletes the account\'s mail and keeps others',
        () async {
      // Builds before schema v62 ran with foreign keys off, so the schema's
      // cascades never fired: the mail stayed in the combined inbox.
      final db = openTestDatabase();
      final repo = AccountRepositoryImpl(db, MapSecureStorage());
      await repo.addAccount(_account, 'pw');
      await repo.addAccount(
        const Account(id: 'acc-2', displayName: 'Bob', email: 'b@x.org'),
        'pw',
      );
      await _seedMailOf(db, 'acc-1');
      await _seedMailOf(db, 'acc-2');
      // Left behind by an account deleted before this fix.
      await withoutForeignKeys(db, () => _seedMailOf(db, 'deleted-earlier'));
      final threads = db.select(db.threads).watch();
      expect((await threads.first).map((t) => t.accountId).toSet(), {
        'acc-1',
        'acc-2',
        'deleted-earlier',
      });

      await repo.removeAccount('acc-1');

      expect((await threads.first).map((t) => t.accountId), ['acc-2']);
      expect(
        (await db.select(db.emails).get()).map((e) => e.accountId),
        ['acc-2'],
      );
      expect(
        (await db.select(db.emailBodies).get()).map((b) => b.emailId),
        ['acc-2:INBOX:1'],
      );
      expect(
        (await db.select(db.mailboxes).get()).map((m) => m.accountId),
        ['acc-2'],
      );
      expect(
        (await db.select(db.undoActions).get()).map((u) => u.accountId),
        ['acc-2'],
      );
      expect(await repo.getAccount('acc-2'), isNotNull);
      expect(
        (await db.select(db.syncLogs).get()).map((l) => l.accountId),
        ['acc-2'],
      );
      expect(await db.select(db.syncLogMailboxes).get(), hasLength(1));
      final logs = {
        for (final l in await db.select(db.appLogs).get()) l.message: l,
      };
      expect(logs['acc-2']!.accountId, 'acc-2');
      for (final gone in ['acc-1', 'deleted-earlier']) {
        expect(logs[gone]!.accountId, isNull);
        expect(logs[gone]!.emailId, isNull);
        expect(logs[gone]!.syncLogId, isNull);
      }
      // Drafts keep their text but leave the gone account and its server.
      final drafts = {
        for (final d in await db.select(db.drafts).get()) d.subjectText: d,
      };
      expect(drafts['draft of acc-2']!.accountId, 'acc-2');
      expect(drafts['draft of acc-1']!.accountId, isNull);
      expect(drafts['draft of acc-1']!.imapServerId, isNull);
      await db.close();
    });

    test(
        'removeAccount deletes its downloaded attachments and resync '
        'leftovers', () async {
      final db = openTestDatabase();
      final cache = await Directory.systemTemp.createTemp('si-cache');
      addTearDown(() => cache.delete(recursive: true));
      final repo = AccountRepositoryImpl(
        db,
        MapSecureStorage(),
        getCacheDir: () async => cache,
      );
      await repo.addAccount(_account, 'pw');
      await repo.addAccount(
        const Account(id: 'acc-2', displayName: 'Bob', email: 'b@x.org'),
        'pw',
      );
      final attachments = p.join(cache.path, 'sharedinbox', 'attachments');
      final mine = Directory(p.join(attachments, 'acc-1_INBOX_1'));
      final theirs = Directory(p.join(attachments, 'acc-2_INBOX_1'));
      for (final d in [mine, theirs]) {
        await d.create(recursive: true);
        await File(p.join(d.path, 'a.pdf')).writeAsString('x');
      }
      // A body whose email row a resync already deleted.
      await withoutForeignKeys(
        db,
        () => db.into(db.emailBodies).insert(
              EmailBodiesCompanion.insert(emailId: 'acc-1:INBOX:9'),
            ),
      );

      await repo.removeAccount('acc-1');

      expect(await mine.exists(), isFalse);
      expect(await theirs.exists(), isTrue);
      expect(await db.select(db.emailBodies).get(), isEmpty);
      await db.close();
    });

    test('getAccount returns null for unknown id', () async {
      final repo = _makeRepo();
      expect(await repo.getAccount('unknown'), isNull);
    });

    test('getAccount returns the account after addAccount', () async {
      final repo = _makeRepo();
      await repo.addAccount(_account, 'secret');
      final result = await repo.getAccount('acc-1');
      expect(result, isNotNull);
      expect(result!.displayName, 'Alice');
    });

    test('getPassword returns stored password', () async {
      final repo = _makeRepo();
      await repo.addAccount(_account, 'mypassword');
      expect(await repo.getPassword('acc-1'), 'mypassword');
    });

    test('getPassword throws StateError when no password stored', () async {
      final repo = _makeRepo();
      expect(() => repo.getPassword('missing'), throwsA(isA<StateError>()));
    });

    test('removeAccount deletes account and password', () async {
      final repo = _makeRepo();
      await repo.addAccount(_account, 'secret');
      await repo.removeAccount('acc-1');

      expect(await repo.getAccount('acc-1'), isNull);
      expect(() => repo.getPassword('acc-1'), throwsA(isA<StateError>()));
    });

    test('addAccount is idempotent (upsert)', () async {
      final repo = _makeRepo();
      await repo.addAccount(_account, 'v1');
      const updated = Account(
        id: 'acc-1',
        displayName: 'Alice Updated',
        email: 'alice@example.com',
        imapHost: 'imap.example.com',
        smtpHost: 'smtp.example.com',
      );
      await repo.addAccount(updated, 'v2');
      final accounts = await repo.observeAccounts().first;
      expect(accounts, hasLength(1));
      expect(accounts.first.displayName, 'Alice Updated');
      expect(await repo.getPassword('acc-1'), 'v2');
    });

    test('observeAccounts reflects removal', () async {
      final repo = _makeRepo();
      await repo.addAccount(_account, 'secret');
      await repo.removeAccount('acc-1');
      final accounts = await repo.observeAccounts().first;
      expect(accounts, isEmpty);
    });

    test('signature defaults to empty and round-trips', () async {
      final repo = _makeRepo();
      await repo.addAccount(_account, 'secret');
      expect((await repo.getAccount('acc-1'))!.signature, '');

      await repo.addAccount(
        _account.copyWith(signature: 'Cheers,\nAlice'),
        'secret',
      );
      expect((await repo.getAccount('acc-1'))!.signature, 'Cheers,\nAlice');
    });

    test('updateAccount persists the signature', () async {
      final repo = _makeRepo();
      await repo.addAccount(_account, 'secret');
      await repo.updateAccount(
        _account.copyWith(signature: 'Regards,\nAlice'),
      );
      expect((await repo.getAccount('acc-1'))!.signature, 'Regards,\nAlice');
    });
  });
}
