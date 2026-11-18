import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';

import 'account_repository_impl_test.dart' show MapSecureStorage;
import 'db_test_helper.dart';
import 'helpers/stateful_fake_imap.dart';

// ── Contract ──────────────────────────────────────────────────────────────────

/// Verifies the [MailboxRepository] interface contract.
///
/// Tests cover the locally-observable part of the interface (observe /
/// find), and the folder listing against a server that holds [serverFolders]
/// ([removeFolderOnServer] drops one).
abstract class MailboxRepositoryContract {
  static const _account = Account(
    id: 'm-acc',
    displayName: 'Contract',
    email: 'm@example.com',
    imapHost: 'imap.example.com',
    smtpHost: 'smtp.example.com',
  );

  /// Return a fresh [MailboxRepository] with [_account] already persisted.
  Future<MailboxRepository> makeRepo();

  /// Insert a mailbox row into the backing store so tests can verify
  /// observeMailboxes without triggering a network sync.
  Future<void> insertMailbox(
    MailboxRepository repo, {
    required String id,
    required String path,
    String? role,
    int unread = 0,
    int total = 0,
  });

  /// The folders the server has when a repository is made.
  static const serverFolders = ['INBOX', 'Old'];

  /// Another client deletes folder [path] on the server.
  void removeFolderOnServer(String path);

  void run() {
    test('observeMailboxes starts empty', () async {
      final repo = await makeRepo();
      expect(await repo.observeMailboxes(_account.id).first, isEmpty);
    });

    test('observeMailboxes emits inserted rows ordered by path', () async {
      final repo = await makeRepo();
      await insertMailbox(repo, id: 'z', path: 'Z');
      await insertMailbox(repo, id: 'a', path: 'A');
      final boxes = await repo.observeMailboxes(_account.id).first;
      expect(boxes.map((b) => b.path), ['A', 'Z']);
    });

    test('observeMailboxes only returns rows for the given account', () async {
      final repo = await makeRepo();
      await insertMailbox(repo, id: 'mb1', path: 'INBOX');
      expect(await repo.observeMailboxes('other-acc').first, isEmpty);
    });

    test('findMailboxByRole returns null when no match', () async {
      final repo = await makeRepo();
      expect(await repo.findMailboxByRole(_account.id, 'archive'), isNull);
    });

    test('findMailboxByRole returns the matching mailbox', () async {
      final repo = await makeRepo();
      await insertMailbox(repo, id: 'arch', path: 'Archive', role: 'archive');
      final box = await repo.findMailboxByRole(_account.id, 'archive');
      expect(box, isNotNull);
      expect(box!.role, 'archive');
    });

    test('clearForResync keeps the mailboxes: the next listing sweeps them',
        () async {
      // Mark-and-sweep (#1236): a force resync deletes nothing up front, so
      // a listing that fails leaves the folder list as it was.
      final repo = await makeRepo();
      await insertMailbox(repo, id: 'mb', path: 'INBOX');
      await insertMailbox(repo, id: 'old', path: 'Old');
      await repo.clearForResync(_account.id);
      var boxes = await repo.observeMailboxes(_account.id).first;
      expect(boxes.map((m) => m.path), ['INBOX', 'Old']);

      removeFolderOnServer('Old');
      await repo.syncMailboxes(_account.id);

      boxes = await repo.observeMailboxes(_account.id).first;
      expect(boxes.map((m) => m.path), ['INBOX'], reason: 'Old swept');
      expect(boxes.single.id, 'mb', reason: 'kept, not recreated');
    });
  }
}

// ── Impl under test ───────────────────────────────────────────────────────────

class _MailboxRepositoryImplContract extends MailboxRepositoryContract {
  static const _account = MailboxRepositoryContract._account;

  late AppDatabase _db;
  late AccountRepositoryImpl _accountRepo;
  late StatefulFakeImapServer _server;

  @override
  void removeFolderOnServer(String path) => _server.deleteFolder(path);

  @override
  Future<MailboxRepository> makeRepo() async {
    _db = openTestDatabase();
    _accountRepo = AccountRepositoryImpl(_db, MapSecureStorage());
    await _accountRepo.addAccount(_account, 'pw');
    _server = StatefulFakeImapServer(
      uidValidityByFolder: {
        for (final (i, path) in MailboxRepositoryContract.serverFolders.indexed)
          path: i + 1,
      },
    );
    return MailboxRepositoryImpl(
      _db,
      _accountRepo,
      imapConnect: (_, __, ___) async => _server.connect(),
    );
  }

  @override
  Future<void> insertMailbox(
    MailboxRepository repo, {
    required String id,
    required String path,
    String? role,
    int unread = 0,
    int total = 0,
  }) async {
    await _db.into(_db.mailboxes).insert(
          MailboxesCompanion.insert(
            id: id,
            accountId: _account.id,
            path: path,
            name: path.split('/').last,
            unreadCount: Value(unread),
            totalCount: Value(total),
            role: Value(role),
          ),
        );
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  group('MailboxRepositoryImpl satisfies MailboxRepository contract', () {
    _MailboxRepositoryImplContract().run();
  });
}
