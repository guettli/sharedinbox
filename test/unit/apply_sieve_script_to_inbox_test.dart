import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/sieve/sieve_parser.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';

import 'db_test_helper.dart';
import 'helpers/sieve_test_helper.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

const _account = Account(
  id: 'sieve-preview-acc',
  displayName: 'Sieve Preview Test',
  email: 'sieve@example.com',
  imapHost: 'imap.example.com',
  smtpHost: 'smtp.example.com',
);

Future<(AppDatabase, EmailRepositoryImpl)> _makeSetup() =>
    makeSieveTestSetup(_account);

Future<String> _insertInboxEmail(
  AppDatabase db, {
  required String id,
  required String? messageId,
  String subject = 'Test',
  String from = 'sender@example.com',
}) =>
    insertSieveTestEmail(
      db,
      accountId: _account.id,
      id: id,
      messageId: messageId,
      subject: subject,
      from: from,
    );

Future<void> _markApplied(AppDatabase db, String messageId) async {
  await db.into(db.localSieveApplied).insert(
        LocalSieveAppliedCompanion.insert(
          accountId: _account.id,
          messageId: messageId,
          appliedAt: DateTime.now(),
        ),
      );
}

const _spamKeepScript = '''
if header :contains "subject" ["SPAM"] {
  keep;
}
''';

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUpAll(configureSqliteForTests);

  group('previewSieveRuleMatches', () {
    test('returns 0 when no inbox message matches', () async {
      final (db, repo) = await _makeSetup();
      await _insertInboxEmail(
        db,
        id: 'sieve-preview-acc:1',
        messageId: '<msg1@test>',
        subject: 'Hello world',
      );
      expect(
        await repo.previewSieveRuleMatches(_account.id, spamFileintoScript),
        0,
      );
      // Preview persists nothing.
      expect(await db.select(db.pendingChanges).get(), isEmpty);
      expect(await db.select(db.localSieveApplied).get(), isEmpty);
    });

    test('counts a keep-only match (no visible effect)', () async {
      final (db, repo) = await _makeSetup();
      await _insertInboxEmail(
        db,
        id: 'sieve-preview-acc:1',
        messageId: '<msg1@test>',
        subject: 'THIS IS SPAM',
      );
      expect(
        await repo.previewSieveRuleMatches(_account.id, _spamKeepScript),
        1,
      );
      expect(await db.select(db.pendingChanges).get(), isEmpty);
    });

    test('ignores LocalSieveApplied — matches are still counted', () async {
      final (db, repo) = await _makeSetup();
      await _insertInboxEmail(
        db,
        id: 'sieve-preview-acc:1',
        messageId: '<msg1@test>',
        subject: 'SPAM one',
      );
      await _markApplied(db, '<msg1@test>');
      expect(
        await repo.previewSieveRuleMatches(_account.id, spamFileintoScript),
        1,
      );
    });

    test('counts multiple matching messages independently', () async {
      final (db, repo) = await _makeSetup();
      await _insertInboxEmail(
        db,
        id: 'sieve-preview-acc:1',
        messageId: '<msg1@test>',
        subject: 'SPAM one',
      );
      await _insertInboxEmail(
        db,
        id: 'sieve-preview-acc:2',
        messageId: '<msg2@test>',
        subject: 'Hello',
      );
      await _insertInboxEmail(
        db,
        id: 'sieve-preview-acc:3',
        messageId: '<msg3@test>',
        subject: 'More SPAM',
      );
      expect(
        await repo.previewSieveRuleMatches(_account.id, spamFileintoScript),
        2,
      );
    });

    test('counts mail without a Message-ID header', () async {
      final (db, repo) = await _makeSetup();
      await _insertInboxEmail(
        db,
        id: 'sieve-preview-acc:1',
        messageId: null,
        subject: 'SPAM without id',
      );
      expect(
        await repo.previewSieveRuleMatches(_account.id, spamFileintoScript),
        1,
      );
    });

    test('throws SieveParseException on malformed script', () async {
      final (_, repo) = await _makeSetup();
      expect(
        () => repo.previewSieveRuleMatches(
          _account.id,
          // Non-string token inside the key list — parser rejects with
          // a SieveParseException at the "expected string" step.
          'if header :contains "subject" [notAString_needs_padding_here_xx];',
        ),
        throwsA(isA<SieveParseException>()),
      );
    });
  });

  group('applySieveScriptToInbox', () {
    test('moves mail without a Message-ID header too', () async {
      final (db, repo) = await _makeSetup();
      await _insertInboxEmail(
        db,
        id: 'sieve-preview-acc:1',
        messageId: null,
        subject: 'SPAM without id',
      );
      expect(
        await repo.applySieveScriptToInbox(_account.id, spamFileintoScript),
        1,
      );
      expect(await db.select(db.pendingChanges).get(), hasLength(1));
      // Nothing to remember it by: LocalSieveApplied is keyed on Message-ID.
      expect(await db.select(db.localSieveApplied).get(), isEmpty);
    });

    test('enqueues a move for a fileinto match', () async {
      final (db, repo) = await _makeSetup();
      await _insertInboxEmail(
        db,
        id: 'sieve-preview-acc:1',
        messageId: '<msg1@test>',
        subject: 'SPAM one',
      );

      final count = await repo.applySieveScriptToInbox(
        _account.id,
        spamFileintoScript,
      );
      expect(count, 1);

      final payload = await expectSinglePendingChange(db, 'move');
      expect(payload['dest'], 'Archive');
    });

    test('enqueues a delete for a discard match', () async {
      final (db, repo) = await _makeSetup();
      await _insertInboxEmail(
        db,
        id: 'sieve-preview-acc:1',
        messageId: '<msg1@test>',
        from: 'spam@evil.com',
      );

      final count = await repo.applySieveScriptToInbox(
        _account.id,
        spamDiscardScript,
      );
      expect(count, 1);

      await expectSinglePendingChange(db, 'delete');
    });

    test('counts keep-only matches but does not enqueue a change', () async {
      final (db, repo) = await _makeSetup();
      await _insertInboxEmail(
        db,
        id: 'sieve-preview-acc:1',
        messageId: '<msg1@test>',
        subject: 'THIS IS SPAM',
      );

      final count = await repo.applySieveScriptToInbox(
        _account.id,
        _spamKeepScript,
      );
      expect(count, 1);
      expect(await db.select(db.pendingChanges).get(), isEmpty);

      // Still recorded as applied so subsequent sync-time applySieveRules
      // does not double-process it.
      final applied = await db.select(db.localSieveApplied).get();
      expect(applied, hasLength(1));
      expect(applied.first.messageId, '<msg1@test>');
    });

    test('ignores LocalSieveApplied — previously seen row is still processed',
        () async {
      final (db, repo) = await _makeSetup();
      await _insertInboxEmail(
        db,
        id: 'sieve-preview-acc:1',
        messageId: '<msg1@test>',
        subject: 'SPAM one',
      );
      await _markApplied(db, '<msg1@test>');

      final count = await repo.applySieveScriptToInbox(
        _account.id,
        spamFileintoScript,
      );
      expect(count, 1);
      await expectSinglePendingChange(db, 'move');
    });

    test('works even when no script is stored for the account', () async {
      // Guarantees the caller does not need to persist/activate a script row
      // before invoking the apply-to-inbox action.
      final (db, repo) = await _makeSetup();
      await _insertInboxEmail(
        db,
        id: 'sieve-preview-acc:1',
        messageId: '<msg1@test>',
        subject: 'SPAM one',
      );
      final storedScripts = await db.select(db.localSieveScripts).get();
      expect(storedScripts, isEmpty);

      final count = await repo.applySieveScriptToInbox(
        _account.id,
        spamFileintoScript,
      );
      expect(count, 1);
    });

    test('throws SieveParseException on malformed script', () async {
      final (_, repo) = await _makeSetup();
      expect(
        () => repo.applySieveScriptToInbox(
          _account.id,
          // Non-string token inside the key list — parser rejects with
          // a SieveParseException at the "expected string" step.
          'if header :contains "subject" [notAString_needs_padding_here_yy];',
        ),
        throwsA(isA<SieveParseException>()),
      );
    });
  });
}
