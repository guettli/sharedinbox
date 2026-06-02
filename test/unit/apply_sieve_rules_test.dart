import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';

import 'account_repository_impl_test.dart' show MapSecureStorage;
import 'db_test_helper.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

const _account = Account(
  id: 'sieve-acc',
  displayName: 'Sieve Test',
  email: 'sieve@example.com',
  imapHost: 'imap.example.com',
  smtpHost: 'smtp.example.com',
);

Future<(AppDatabase, EmailRepositoryImpl)> _makeSetup() async {
  final db = openTestDatabase();
  final storage = MapSecureStorage();
  final accounts = AccountRepositoryImpl(db, storage);
  await accounts.addAccount(_account, 'password');

  final repo = EmailRepositoryImpl(db, accounts);
  return (db, repo);
}

/// Inserts a minimal email row in the INBOX. Returns the row id.
Future<String> _insertInboxEmail(
  AppDatabase db, {
  required String id,
  required String messageId,
  String subject = 'Test',
  String from = 'sender@example.com',
  String mailboxPath = 'INBOX',
}) async {
  await db
      .into(db.emails)
      .insert(
        EmailsCompanion.insert(
          id: id,
          accountId: _account.id,
          mailboxPath: mailboxPath,
          uid: int.parse(id.split(':').last),
          subject: Value(subject),
          receivedAt: DateTime.now(),
          fromJson: Value(
            jsonEncode([
              {'name': '', 'email': from},
            ]),
          ),
          messageId: Value(messageId),
        ),
      );
  // Insert a thread row so _updateThread does not throw.
  await db
      .into(db.threads)
      .insertOnConflictUpdate(
        ThreadsCompanion.insert(
          id: id,
          accountId: _account.id,
          mailboxPath: mailboxPath,
          latestDate: DateTime.now(),
          latestEmailId: id,
        ),
      );
  return id;
}

/// Creates an active Sieve script for the test account.
Future<void> _insertSieveScript(AppDatabase db, String content) async {
  await db
      .into(db.localSieveScripts)
      .insert(
        LocalSieveScriptsCompanion.insert(
          accountId: _account.id,
          name: 'test-script',
          content: Value(content),
          isActive: const Value(true),
        ),
      );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUpAll(configureSqliteForTests);

  group('applySieveRules', () {
    test('returns 0 when no active script exists', () async {
      final (_, repo) = await _makeSetup();
      expect(await repo.applySieveRules(_account.id), 0);
    });

    test('returns 0 when script has no matching rules', () async {
      final (db, repo) = await _makeSetup();
      await _insertSieveScript(db, '''
require ["fileinto"];
if header :contains "subject" ["NEVER_MATCHES_XYZ"] {
  fileinto "Archive";
}
''');
      await _insertInboxEmail(
        db,
        id: 'sieve-acc:1',
        messageId: '<msg1@test>',
        subject: 'Hello world',
      );
      expect(await repo.applySieveRules(_account.id), 0);
    });

    test('applies fileinto rule and queues a move pending change', () async {
      final (db, repo) = await _makeSetup();
      await _insertSieveScript(db, '''
require ["fileinto"];
if header :contains "subject" ["SPAM"] {
  fileinto "Archive";
}
''');
      await _insertInboxEmail(
        db,
        id: 'sieve-acc:1',
        messageId: '<msg1@test>',
        subject: 'THIS IS SPAM',
      );

      final count = await repo.applySieveRules(_account.id);
      expect(count, 1);

      final pending = await db.select(db.pendingChanges).get();
      expect(pending, hasLength(1));
      expect(pending.first.changeType, 'move');
      final payload = jsonDecode(pending.first.payload) as Map<String, dynamic>;
      expect(payload['dest'], 'Archive');
    });

    test('applies discard rule and queues a delete pending change', () async {
      final (db, repo) = await _makeSetup();
      await _insertSieveScript(db, '''
if header :contains "from" ["spam@evil.com"] {
  discard;
}
''');
      await _insertInboxEmail(
        db,
        id: 'sieve-acc:1',
        messageId: '<msg1@test>',
        from: 'spam@evil.com',
      );

      final count = await repo.applySieveRules(_account.id);
      expect(count, 1);

      final pending = await db.select(db.pendingChanges).get();
      expect(pending, hasLength(1));
      expect(pending.first.changeType, 'delete');
    });

    test('records email in LocalSieveApplied after processing', () async {
      final (db, repo) = await _makeSetup();
      await _insertSieveScript(db, '''
require ["fileinto"];
if header :contains "subject" ["SPAM"] {
  fileinto "Archive";
}
''');
      await _insertInboxEmail(
        db,
        id: 'sieve-acc:1',
        messageId: '<msg1@test>',
        subject: 'SPAM email',
      );

      await repo.applySieveRules(_account.id);

      final applied = await db.select(db.localSieveApplied).get();
      expect(applied, hasLength(1));
      expect(applied.first.messageId, '<msg1@test>');
      expect(applied.first.accountId, _account.id);
    });

    test('does not reprocess an email already in LocalSieveApplied', () async {
      final (db, repo) = await _makeSetup();
      await _insertSieveScript(db, '''
require ["fileinto"];
if header :contains "subject" ["SPAM"] {
  fileinto "Archive";
}
''');
      await _insertInboxEmail(
        db,
        id: 'sieve-acc:1',
        messageId: '<msg1@test>',
        subject: 'SPAM email',
      );

      // First run applies the rule.
      expect(await repo.applySieveRules(_account.id), 1);

      // Restore the email to INBOX to simulate a re-sync (e.g. second device
      // moved it back). The LocalSieveApplied record prevents reprocessing.
      await (db.update(db.emails)..where((t) => t.id.equals('sieve-acc:1')))
          .write(const EmailsCompanion(mailboxPath: Value('INBOX')));

      // Second run must not produce another pending change.
      expect(await repo.applySieveRules(_account.id), 0);
      final pending = await db.select(db.pendingChanges).get();
      // Only the original move from the first run; no duplicates.
      expect(pending, hasLength(1));
    });

    test('skips emails with no messageId', () async {
      final (db, repo) = await _makeSetup();
      await _insertSieveScript(db, '''
require ["fileinto"];
if header :contains "subject" ["SPAM"] {
  fileinto "Archive";
}
''');
      // Insert without messageId.
      await db
          .into(db.emails)
          .insert(
            EmailsCompanion.insert(
              id: 'sieve-acc:2',
              accountId: _account.id,
              mailboxPath: 'INBOX',
              uid: 2,
              subject: const Value('SPAM without id'),
              receivedAt: DateTime.now(),
            ),
          );
      await db
          .into(db.threads)
          .insertOnConflictUpdate(
            ThreadsCompanion.insert(
              id: 'sieve-acc:2',
              accountId: _account.id,
              mailboxPath: 'INBOX',
              latestDate: DateTime.now(),
              latestEmailId: 'sieve-acc:2',
            ),
          );

      expect(await repo.applySieveRules(_account.id), 0);
      expect(await db.select(db.pendingChanges).get(), isEmpty);
    });

    test('emails not in INBOX are ignored', () async {
      final (db, repo) = await _makeSetup();
      await _insertSieveScript(db, '''
require ["fileinto"];
if header :contains "subject" ["SPAM"] {
  fileinto "Archive";
}
''');
      await _insertInboxEmail(
        db,
        id: 'sieve-acc:1',
        messageId: '<msg1@test>',
        subject: 'SPAM in Sent',
        mailboxPath: 'Sent',
      );

      expect(await repo.applySieveRules(_account.id), 0);
      expect(await db.select(db.pendingChanges).get(), isEmpty);
    });

    test('processes multiple emails independently', () async {
      final (db, repo) = await _makeSetup();
      await _insertSieveScript(db, '''
require ["fileinto"];
if header :contains "subject" ["SPAM"] {
  fileinto "Archive";
}
''');
      await _insertInboxEmail(
        db,
        id: 'sieve-acc:1',
        messageId: '<msg1@test>',
        subject: 'SPAM',
      );
      await _insertInboxEmail(
        db,
        id: 'sieve-acc:2',
        messageId: '<msg2@test>',
        subject: 'Hello',
      );
      await _insertInboxEmail(
        db,
        id: 'sieve-acc:3',
        messageId: '<msg3@test>',
        subject: 'More SPAM',
      );

      final count = await repo.applySieveRules(_account.id);
      expect(count, 2);

      final applied = await db.select(db.localSieveApplied).get();
      // All three emails should be in LocalSieveApplied.
      expect(applied, hasLength(3));

      final pending = await db.select(db.pendingChanges).get();
      expect(pending, hasLength(2));
    });
  });
}
