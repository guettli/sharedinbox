import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart' as model;
import 'package:sharedinbox/core/sync/account_comparison.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;

import 'db_test_helper.dart';

void main() {
  setUpAll(configureSqliteForTests);

  group('AccountComparison.isComparablePair', () {
    const imap = model.Account(
      id: 'i',
      displayName: 'Alice (IMAP)',
      email: 'alice@example.com',
      imapHost: 'mail.example.com',
      imapPort: 143,
      smtpHost: 'smtp.example.com',
    );
    const jmap = model.Account(
      id: 'j',
      displayName: 'Alice (JMAP)',
      email: 'alice@example.com',
      type: model.AccountType.jmap,
      jmapUrl: 'https://mail.example.com/.well-known/jmap',
    );

    test('matches IMAP+JMAP with same host and email', () {
      expect(AccountComparison.isComparablePair(imap, jmap), isTrue);
      expect(AccountComparison.isComparablePair(jmap, imap), isTrue);
    });

    test('rejects pairs with the same protocol', () {
      expect(AccountComparison.isComparablePair(imap, imap), isFalse);
    });

    test('rejects pairs targeting different hosts', () {
      const other = model.Account(
        id: 'k',
        displayName: 'Other',
        email: 'alice@example.com',
        type: model.AccountType.jmap,
        jmapUrl: 'https://mail.other.com/.well-known/jmap',
      );
      expect(AccountComparison.isComparablePair(imap, other), isFalse);
    });

    test('rejects pairs with different effective usernames', () {
      const bob = model.Account(
        id: 'k',
        displayName: 'Bob',
        email: 'bob@example.com',
        type: model.AccountType.jmap,
        jmapUrl: 'https://mail.example.com/.well-known/jmap',
      );
      expect(AccountComparison.isComparablePair(imap, bob), isFalse);
    });

    test('uses explicit username when set', () {
      const imapAuth = model.Account(
        id: 'i2',
        displayName: 'Alice (IMAP)',
        email: 'alice@example.com',
        username: 'shared',
        imapHost: 'mail.example.com',
      );
      const jmapAuth = model.Account(
        id: 'j2',
        displayName: 'Alice (JMAP)',
        email: 'someone-else@example.com',
        username: 'shared',
        type: model.AccountType.jmap,
        jmapUrl: 'https://mail.example.com/.well-known/jmap',
      );
      expect(AccountComparison.isComparablePair(imapAuth, jmapAuth), isTrue);
    });
  });

  group('AccountComparison.compare', () {
    late AppDatabase db;
    late AccountComparison service;

    setUp(() async {
      db = openTestDatabase();
      service = AccountComparison(db);
      await _seedAccount(db, 'imap-1', model.AccountType.imap);
      await _seedAccount(db, 'jmap-1', model.AccountType.jmap);
    });

    tearDown(() => db.close());

    test('identical seeded rows produce zero diff', () async {
      await _seedMailbox(db, 'imap-1', path: 'INBOX', role: 'inbox');
      await _seedMailbox(db, 'jmap-1', path: 'a', role: 'inbox');
      await _seedEmail(
        db,
        accountId: 'imap-1',
        id: 'imap-1:1',
        mailboxPath: 'INBOX',
        uid: 1,
        messageId: '<msg-001@example.com>',
        subject: 'Hello',
        sentAt: DateTime.utc(2026, 1, 1, 12),
      );
      await _seedEmail(
        db,
        accountId: 'jmap-1',
        id: 'jmap-1:X',
        mailboxPath: 'a',
        uid: 0,
        messageId: '<msg-001@example.com>',
        subject: 'Hello',
        sentAt: DateTime.utc(2026, 1, 1, 12),
      );

      final result = await service.compare('imap-1', 'jmap-1');
      expect(result.isIdentical, isTrue);
      expect(result.diffCount, 0);
    });

    test('detects an email missing on side B', () async {
      await _seedMailbox(db, 'imap-1', path: 'INBOX', role: 'inbox');
      await _seedMailbox(db, 'jmap-1', path: 'a', role: 'inbox');
      await _seedEmail(
        db,
        accountId: 'imap-1',
        id: 'imap-1:1',
        mailboxPath: 'INBOX',
        uid: 1,
        messageId: '<only-in-a@example.com>',
        subject: 'Solo',
        sentAt: DateTime.utc(2026, 1, 1, 12),
      );

      final result = await service.compare('imap-1', 'jmap-1');
      expect(result.isIdentical, isFalse);
      expect(result.emails, hasLength(1));
      expect(result.emails.single.kind, EmailDiffKind.missingInB);
      expect(result.emails.single.messageId, '<only-in-a@example.com>');
    });

    test('detects field mismatches on matched emails', () async {
      await _seedMailbox(db, 'imap-1', path: 'INBOX', role: 'inbox');
      await _seedMailbox(db, 'jmap-1', path: 'a', role: 'inbox');
      const messageId = '<m1@example.com>';
      await _seedEmail(
        db,
        accountId: 'imap-1',
        id: 'imap-1:1',
        mailboxPath: 'INBOX',
        uid: 1,
        messageId: messageId,
        subject: 'Hello',
      );
      await _seedEmail(
        db,
        accountId: 'jmap-1',
        id: 'jmap-1:X',
        mailboxPath: 'a',
        uid: 0,
        messageId: messageId,
        subject: 'Hello',
        isSeen: true,
      );

      final result = await service.compare('imap-1', 'jmap-1');
      expect(result.isIdentical, isFalse);
      expect(result.emails, hasLength(1));
      final diff = result.emails.single;
      expect(diff.kind, EmailDiffKind.fieldMismatch);
      expect(diff.fields, contains(EmailFieldMismatch.seen));
    });

    test('detects a mailbox present on only one side', () async {
      await _seedMailbox(db, 'imap-1', path: 'INBOX', role: 'inbox');
      await _seedMailbox(db, 'imap-1', path: 'Archive', role: 'archive');
      await _seedMailbox(db, 'jmap-1', path: 'a', role: 'inbox');

      final result = await service.compare('imap-1', 'jmap-1');
      expect(result.isIdentical, isFalse);
      expect(result.mailboxes, hasLength(1));
      expect(result.mailboxes.single.kind, MailboxDiffKind.missingInB);
      expect(result.mailboxes.single.key, 'role:archive');
    });

    test('reports emails without Message-ID as unmatchable', () async {
      await _seedMailbox(db, 'imap-1', path: 'INBOX', role: 'inbox');
      await _seedMailbox(db, 'jmap-1', path: 'a', role: 'inbox');
      await _seedEmail(
        db,
        accountId: 'imap-1',
        id: 'imap-1:1',
        mailboxPath: 'INBOX',
        uid: 1,
        messageId: null,
        subject: 'No id',
      );

      final result = await service.compare('imap-1', 'jmap-1');
      expect(result.unmatchable, hasLength(1));
      expect(result.unmatchable.single.side, ComparisonSide.a);
      // Unmatchable emails don't count as diffs — they're surfaced separately
      // so the user can see them, but identical state should still be possible
      // when the other side also has no matching Message-ID.
      expect(result.emails, isEmpty);
    });
  });
}

Future<void> _seedAccount(
  AppDatabase db,
  String id,
  model.AccountType type,
) async {
  await db.into(db.accounts).insert(
        AccountsCompanion.insert(
          id: id,
          displayName: id,
          email: 'alice@example.com',
          imapHost: type == model.AccountType.imap ? 'mail.example.com' : '',
          imapPort: 143,
          imapSsl: false,
          smtpHost: '',
          smtpPort: 25,
          smtpSsl: false,
          accountType: Value(type.name),
          jmapUrl: type == model.AccountType.jmap
              ? const Value('https://mail.example.com/.well-known/jmap')
              : const Value.absent(),
        ),
      );
}

Future<void> _seedMailbox(
  AppDatabase db,
  String accountId, {
  required String path,
  String? role,
  int unread = 0,
  int total = 0,
}) async {
  await db.into(db.mailboxes).insert(
        MailboxesCompanion.insert(
          id: '$accountId:$path',
          accountId: accountId,
          path: path,
          name: path,
          unreadCount: Value(unread),
          totalCount: Value(total),
          role: Value(role),
        ),
      );
}

Future<void> _seedEmail(
  AppDatabase db, {
  required String accountId,
  required String id,
  required String mailboxPath,
  required int uid,
  required String? messageId,
  String? subject,
  DateTime? sentAt,
  bool isSeen = false,
  bool isFlagged = false,
}) async {
  await db.into(db.emails).insert(
        EmailsCompanion.insert(
          id: id,
          accountId: accountId,
          mailboxPath: mailboxPath,
          uid: uid,
          subject: Value(subject),
          sentAt: Value(sentAt),
          receivedAt: sentAt ?? DateTime.utc(2026),
          isSeen: Value(isSeen),
          isFlagged: Value(isFlagged),
          messageId: Value(messageId),
        ),
      );
}
