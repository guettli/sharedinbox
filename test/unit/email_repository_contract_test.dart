import 'package:drift/drift.dart' show Value;
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';

import 'account_repository_impl_test.dart' show MapSecureStorage;
import 'db_test_helper.dart';

// ── Contract ──────────────────────────────────────────────────────────────────

/// Verifies the observable / local-state portion of the [EmailRepository]
/// interface contract.
///
/// Network-dependent methods (syncEmails, sendEmail, etc.) are intentionally
/// excluded — they are covered by the concrete impl tests.
abstract class EmailRepositoryContract {
  static const _account = Account(
    id: 'er-acc',
    displayName: 'Contract',
    email: 'er@example.com',
    imapHost: 'imap.example.com',
    smtpHost: 'smtp.example.com',
  );

  /// Return a fresh [EmailRepository] with [_account] already persisted.
  Future<EmailRepository> makeRepo();

  /// Insert a raw email row so tests can assert on observable state without
  /// triggering a network sync.
  Future<void> insertEmail(
    EmailRepository repo, {
    required String id,
    required String mailboxPath,
    bool isSeen = true,
    bool isFlagged = false,
    DateTime? receivedAt,
  });

  void run() {
    test('observeEmails starts empty', () async {
      final repo = await makeRepo();
      expect(
        await repo.observeEmails(_account.id, 'INBOX').first,
        isEmpty,
      );
    });

    test('observeEmails emits inserted email', () async {
      final repo = await makeRepo();
      await insertEmail(repo, id: 'er-acc:1', mailboxPath: 'INBOX');
      final emails = await repo.observeEmails(_account.id, 'INBOX').first;
      expect(emails, hasLength(1));
      expect(emails.first.id, 'er-acc:1');
    });

    test('observeEmails only returns emails for the given mailbox', () async {
      final repo = await makeRepo();
      await insertEmail(repo, id: 'er-acc:1', mailboxPath: 'INBOX');
      expect(
        await repo.observeEmails(_account.id, 'Sent').first,
        isEmpty,
      );
    });

    test('observeEmails orders by receivedAt descending', () async {
      final repo = await makeRepo();
      final older = DateTime(2024);
      final newer = DateTime(2024, 6);
      await insertEmail(
        repo,
        id: 'er-acc:1',
        mailboxPath: 'INBOX',
        receivedAt: older,
      );
      await insertEmail(
        repo,
        id: 'er-acc:2',
        mailboxPath: 'INBOX',
        receivedAt: newer,
      );
      final emails = await repo.observeEmails(_account.id, 'INBOX').first;
      expect(emails.first.id, 'er-acc:2');
      expect(emails.last.id, 'er-acc:1');
    });

    test('getEmail returns null for unknown id', () async {
      final repo = await makeRepo();
      expect(await repo.getEmail('no-such'), isNull);
    });

    test('getEmail returns inserted email', () async {
      final repo = await makeRepo();
      await insertEmail(repo, id: 'er-acc:7', mailboxPath: 'INBOX');
      final email = await repo.getEmail('er-acc:7');
      expect(email, isNotNull);
      expect(email!.accountId, _account.id);
    });

    test('setFlag seen updates isSeen', () async {
      final repo = await makeRepo();
      await insertEmail(
        repo,
        id: 'er-acc:10',
        mailboxPath: 'INBOX',
        isSeen: false,
      );
      await repo.setFlag('er-acc:10', seen: true);
      final email = await repo.getEmail('er-acc:10');
      expect(email!.isSeen, isTrue);
    });

    test('setFlag flagged updates isFlagged', () async {
      final repo = await makeRepo();
      await insertEmail(
        repo,
        id: 'er-acc:11',
        mailboxPath: 'INBOX',
      );
      await repo.setFlag('er-acc:11', flagged: true);
      final email = await repo.getEmail('er-acc:11');
      expect(email!.isFlagged, isTrue);
    });

    test('observeThreads starts empty', () async {
      final repo = await makeRepo();
      expect(
        await repo.observeThreads(_account.id, 'INBOX').first,
        isEmpty,
      );
    });
  }
}

// ── Impl under test ───────────────────────────────────────────────────────────

class _EmailRepositoryImplContract extends EmailRepositoryContract {
  static const _account = EmailRepositoryContract._account;

  late AppDatabase _db;
  late AccountRepositoryImpl _accountRepo;

  @override
  Future<EmailRepository> makeRepo() async {
    _db = openTestDatabase();
    _accountRepo = AccountRepositoryImpl(_db, MapSecureStorage());
    await _accountRepo.addAccount(_account, 'pw');
    return EmailRepositoryImpl(
      _db,
      _accountRepo,
      imapConnect: (_, __, ___) => Future<imap.ImapClient>.error(
        UnsupportedError('no IMAP in unit tests'),
      ),
      smtpConnect: (_, __, ___) => Future<imap.SmtpClient>.error(
        UnsupportedError('no SMTP in unit tests'),
      ),
    );
  }

  @override
  Future<void> insertEmail(
    EmailRepository repo, {
    required String id,
    required String mailboxPath,
    bool isSeen = true,
    bool isFlagged = false,
    DateTime? receivedAt,
  }) async {
    await _db.into(_db.emails).insert(
          EmailsCompanion.insert(
            id: id,
            accountId: _account.id,
            mailboxPath: mailboxPath,
            uid: int.parse(id.split(':').last),
            receivedAt: receivedAt ?? DateTime.now(),
            isSeen: Value(isSeen),
            isFlagged: Value(isFlagged),
          ),
        );
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  group('EmailRepositoryImpl satisfies EmailRepository contract', () {
    _EmailRepositoryImplContract().run();
  });
}
