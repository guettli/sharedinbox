import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';

import 'db_test_helper.dart';
import 'helpers/sieve_test_helper.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

const _account = Account(
  id: 'sieve-acc',
  displayName: 'Sieve Test',
  email: 'sieve@example.com',
  imapHost: 'imap.example.com',
  smtpHost: 'smtp.example.com',
);

/// Sets up the test account and, when [script] is given, stores it as the
/// account's active Sieve script.
Future<(AppDatabase, EmailRepositoryImpl)> _makeSetup([String? script]) async {
  final (db, repo) = await makeSieveTestSetup(_account);
  if (script != null) {
    await db.into(db.localSieveScripts).insert(
          LocalSieveScriptsCompanion.insert(
            accountId: _account.id,
            name: 'test-script',
            content: Value(script),
            isActive: const Value(true),
          ),
        );
  }
  return (db, repo);
}

/// Inserts a minimal email row in the INBOX. Returns the row id.
Future<String> _insertInboxEmail(
  AppDatabase db, {
  required String id,
  required String? messageId,
  String subject = 'Test',
  String from = 'sender@example.com',
  String mailboxPath = 'INBOX',
}) =>
    insertSieveTestEmail(
      db,
      accountId: _account.id,
      id: id,
      messageId: messageId,
      subject: subject,
      from: from,
      mailboxPath: mailboxPath,
    );

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUpAll(configureSqliteForTests);

  group('applySieveRules', () {
    test('returns 0 when no active script exists', () async {
      final (_, repo) = await _makeSetup();
      expect(await repo.applySieveRules(_account.id), 0);
    });

    test('returns 0 when script has no matching rules', () async {
      final (db, repo) = await _makeSetup('''
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
      final (db, repo) = await _makeSetup(spamFileintoScript);
      await _insertInboxEmail(
        db,
        id: 'sieve-acc:1',
        messageId: '<msg1@test>',
        subject: 'THIS IS SPAM',
      );

      final count = await repo.applySieveRules(_account.id);
      expect(count, 1);

      final payload = await expectSinglePendingChange(db, 'move');
      expect(payload['dest'], 'Archive');
    });

    test('applies discard rule and queues a delete pending change', () async {
      final (db, repo) = await _makeSetup(spamDiscardScript);
      await _insertInboxEmail(
        db,
        id: 'sieve-acc:1',
        messageId: '<msg1@test>',
        from: 'spam@evil.com',
      );

      final count = await repo.applySieveRules(_account.id);
      expect(count, 1);

      await expectSinglePendingChange(db, 'delete');
    });

    test('records email in LocalSieveApplied after processing', () async {
      final (db, repo) = await _makeSetup(spamFileintoScript);
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
      final (db, repo) = await _makeSetup(spamFileintoScript);
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
      final (db, repo) = await _makeSetup(spamFileintoScript);
      await _insertInboxEmail(
        db,
        id: 'sieve-acc:2',
        messageId: null,
        subject: 'SPAM without id',
      );

      expect(await repo.applySieveRules(_account.id), 0);
      expect(await db.select(db.pendingChanges).get(), isEmpty);
    });

    test('emails not in INBOX are ignored', () async {
      final (db, repo) = await _makeSetup(spamFileintoScript);
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
      final (db, repo) = await _makeSetup(spamFileintoScript);
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
