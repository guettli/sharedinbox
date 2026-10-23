import 'dart:convert';

import 'package:drift/drift.dart' show OrderingTerm, Value;
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

  // Flag actions used to all collapse into "mark as read": a "Star message"
  // filter left the mail read and unstarred.
  group('applySieveRules flag actions', () {
    /// Runs a filter with [actions] on subject "lunch" over one matching
    /// INBOX mail and returns the database and that mail's row afterwards.
    Future<(AppDatabase, Email)> runLunchFilter(String actions) async {
      final (db, repo) = await _makeSetup('''
require ["fileinto", "imap4flags"];
if header :contains "subject" "lunch" {
$actions
}
''');
      await _insertInboxEmail(
        db,
        id: 'sieve-acc:1',
        messageId: '<msg1@test>',
        subject: 'Lunch on Friday',
      );
      expect(await repo.applySieveRules(_account.id), 1);
      final row = await (db.select(db.emails)
            ..where((t) => t.id.equals('sieve-acc:1')))
          .getSingle();
      return (db, row);
    }

    test('star action stars the message and leaves it unread', () async {
      final (db, row) = await runLunchFilter(r'setflag "\\Flagged";');

      expect(row.isFlagged, isTrue);
      expect(row.isSeen, isFalse);
      expect(row.mailboxPath, 'INBOX');
      final payload = await expectSinglePendingChange(db, 'flag_flagged');
      expect(payload['flagged'], isTrue);
      expect(payload['uid'], 1);
      expect(payload['mailboxPath'], 'INBOX');
    });

    test('mark-as-read action marks the message read', () async {
      final (db, row) = await runLunchFilter(r'setflag "\\Seen";');

      expect(row.isSeen, isTrue);
      expect(row.isFlagged, isFalse);
      final payload = await expectSinglePendingChange(db, 'flag_seen');
      expect(payload['seen'], isTrue);
    });

    test('fileinto + star stars, then moves, in that order', () async {
      final (db, row) = await runLunchFilter(
        r'setflag "\\Flagged"; fileinto "Archive";',
      );

      expect(row.isFlagged, isTrue);
      expect(row.isSeen, isFalse);
      expect(row.mailboxPath, 'Archive');

      final pending = await (db.select(db.pendingChanges)
            ..orderBy([(t) => OrderingTerm.asc(t.id)]))
          .get();
      expect(pending.map((p) => p.changeType), ['flag_flagged', 'move']);
      // The flag change addresses the source UID, so it must be flushed
      // before the move re-keys the message.
      final flagPayload =
          jsonDecode(pending.first.payload) as Map<String, dynamic>;
      expect(flagPayload['mailboxPath'], 'INBOX');
      final movePayload =
          jsonDecode(pending.last.payload) as Map<String, dynamic>;
      expect(movePayload['dest'], 'Archive');
    });

    test('custom keyword is queued as add_keywords, not mark-read', () async {
      final (db, row) = await runLunchFilter(
        r'addflag ["Work", "\\Answered"];',
      );

      expect(row.isSeen, isFalse);
      expect(row.isFlagged, isFalse);
      final payload = await expectSinglePendingChange(db, 'add_keywords');
      expect(payload['keywords'], unorderedEquals([r'\Answered', 'Work']));
      expect(payload['uid'], 1);
      expect(payload['mailboxPath'], 'INBOX');
    });
  });
}
