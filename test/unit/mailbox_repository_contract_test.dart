import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';

import 'account_repository_impl_test.dart' show MapSecureStorage;
import 'db_test_helper.dart';

// ── Contract ──────────────────────────────────────────────────────────────────

/// Verifies the [MailboxRepository] interface contract.
///
/// Tests cover only the locally-observable part of the interface
/// (observe / find) since sync methods require live IMAP/JMAP servers.
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

    test('clearForResync removes all mailboxes for the account', () async {
      final repo = await makeRepo();
      await insertMailbox(repo, id: 'mb', path: 'INBOX');
      await repo.clearForResync(_account.id);
      expect(await repo.observeMailboxes(_account.id).first, isEmpty);
    });
  }
}

// ── Impl under test ───────────────────────────────────────────────────────────

class _MailboxRepositoryImplContract extends MailboxRepositoryContract {
  static const _account = MailboxRepositoryContract._account;

  late AppDatabase _db;
  late AccountRepositoryImpl _accountRepo;

  @override
  Future<MailboxRepository> makeRepo() async {
    _db = openTestDatabase();
    _accountRepo = AccountRepositoryImpl(_db, MapSecureStorage());
    await _accountRepo.addAccount(_account, 'pw');
    return MailboxRepositoryImpl(
      _db,
      _accountRepo,
      imapConnect: (_, __, ___) =>
          Future.error(UnsupportedError('no IMAP in unit tests')),
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
    await _db
        .into(_db.mailboxes)
        .insert(
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
