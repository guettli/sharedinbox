import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/sync/message_debug_service.dart';
import 'package:sharedinbox/data/db/database.dart';

import 'db_test_helper.dart';

void main() {
  setUpAll(configureSqliteForTests);

  group('loadMessageDebugSnapshot', () {
    late AppDatabase db;

    setUp(() {
      db = openTestDatabase();
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> insertAccount() async {
      await db.into(db.accounts).insert(
            AccountsCompanion.insert(
              id: 'acc-1',
              displayName: 'Test',
              email: 'user@example.com',
              imapHost: 'imap.example.com',
              imapPort: 993,
              imapSsl: true,
              smtpHost: 'smtp.example.com',
              smtpPort: 465,
              smtpSsl: true,
            ),
          );
    }

    Future<void> insertEmail({String id = 'acc-1:INBOX:42'}) async {
      await db.into(db.emails).insert(
            EmailsCompanion.insert(
              id: id,
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              uid: 42,
              subject: const Value('Hello'),
              sentAt: Value(DateTime.utc(2026, 6, 15)),
              receivedAt: DateTime.utc(2026, 6, 15),
              fromJson:
                  const Value('[{"name":"Bob","email":"bob@example.com"}]'),
              toAddresses: const Value('[{"email":"alice@example.com"}]'),
              isSeen: const Value(false),
              isFlagged: const Value(true),
              messageId: const Value('abc@example.com'),
            ),
          );
    }

    test('returns a snapshot mirroring every stored column', () async {
      await insertAccount();
      await insertEmail();
      await db.into(db.emailBodies).insert(
            EmailBodiesCompanion.insert(
              emailId: 'acc-1:INBOX:42',
              textBody: const Value('hello world'),
              htmlBody: const Value('<b>hello</b>'),
              attachmentsJson: Value(
                jsonEncode([
                  {
                    'filename': 'a.pdf',
                    'contentType': 'application/pdf',
                    'size': 10,
                  },
                ]),
              ),
              cachedAt: Value(DateTime.utc(2026, 6, 2)),
            ),
          );
      await db.into(db.pendingChanges).insert(
            PendingChangesCompanion.insert(
              accountId: 'acc-1',
              resourceType: 'Email',
              resourceId: 'acc-1:INBOX:42',
              changeType: 'flag_seen',
              payload: '{"seen": true}',
              createdAt: DateTime.utc(2026, 6, 3),
              attempts: const Value(1),
              lastError: const Value('oops'),
            ),
          );

      final snapshot = await loadMessageDebugSnapshot(
        db,
        const DebugMessageRef(
          accountId: 'acc-1',
          mailboxPath: 'INBOX',
          emailId: 'acc-1:INBOX:42',
        ),
      );

      expect(snapshot.email, isNotNull);
      expect(snapshot.email!.subject, 'Hello');
      expect(snapshot.email!.uid, 42);
      expect(snapshot.email!.isFlagged, isTrue);
      expect(snapshot.body, isNotNull);
      expect(snapshot.body!.textBodyLength, 'hello world'.length);
      expect(snapshot.body!.htmlBodyLength, '<b>hello</b>'.length);
      expect(snapshot.attachments, hasLength(1));
      expect(snapshot.attachments.single.filename, 'a.pdf');
      expect(snapshot.pending, hasLength(1));
      expect(snapshot.pending.single.changeType, 'flag_seen');
      expect(snapshot.pending.single.attempts, 1);
      expect(snapshot.pending.single.lastError, 'oops');
    });

    test('missing local row → email is null but pending still loaded',
        () async {
      await insertAccount();
      await db.into(db.pendingChanges).insert(
            PendingChangesCompanion.insert(
              accountId: 'acc-1',
              resourceType: 'Email',
              resourceId: 'acc-1:INBOX:99',
              changeType: 'delete',
              payload: '{}',
              createdAt: DateTime.utc(2026, 6, 4),
            ),
          );

      final snapshot = await loadMessageDebugSnapshot(
        db,
        const DebugMessageRef(
          accountId: 'acc-1',
          mailboxPath: 'INBOX',
          emailId: 'acc-1:INBOX:99',
        ),
      );

      expect(snapshot.email, isNull);
      expect(snapshot.body, isNull);
      expect(snapshot.pending, hasLength(1));
    });

    test('surfaces the most recent SyncLogs row for the account', () async {
      await insertAccount();
      await insertEmail();
      final oldRow = SyncLogsCompanion.insert(
        accountId: 'acc-1',
        result: 'error',
        errorMessage: const Value('kaput'),
        startedAt: DateTime.utc(2026, 6, 15),
        finishedAt: DateTime.utc(2026, 6, 1, 0, 0, 5),
      );
      final newRow = SyncLogsCompanion.insert(
        accountId: 'acc-1',
        result: 'ok',
        startedAt: DateTime.utc(2026, 6, 5),
        finishedAt: DateTime.utc(2026, 6, 5, 0, 0, 5),
      );
      await db.into(db.syncLogs).insert(oldRow);
      await db.into(db.syncLogs).insert(newRow);

      final snapshot = await loadMessageDebugSnapshot(
        db,
        const DebugMessageRef(
          accountId: 'acc-1',
          mailboxPath: 'INBOX',
          emailId: 'acc-1:INBOX:42',
        ),
      );

      expect(snapshot.lastSyncLog, isNotNull);
      expect(snapshot.lastSyncLog!.result, 'ok');
      expect(snapshot.lastSyncLog!.startedAt, DateTime.utc(2026, 6, 5));
    });

    test('exposes SyncStates rows for the account', () async {
      await insertAccount();
      await insertEmail();
      await db.into(db.syncStates).insert(
            SyncStatesCompanion.insert(
              accountId: 'acc-1',
              resourceType: 'IMAP:INBOX',
              state: '{"uidValidity":1,"lastUid":42}',
              syncedAt: DateTime.utc(2026, 6, 6),
            ),
          );

      final snapshot = await loadMessageDebugSnapshot(
        db,
        const DebugMessageRef(
          accountId: 'acc-1',
          mailboxPath: 'INBOX',
          emailId: 'acc-1:INBOX:42',
        ),
      );

      expect(snapshot.syncStates, hasLength(1));
      expect(snapshot.syncStates.single.resourceType, 'IMAP:INBOX');
      expect(snapshot.syncStates.single.state, contains('lastUid'));
    });

    test('gracefully handles a body row with malformed attachments JSON',
        () async {
      await insertAccount();
      await insertEmail();
      await db.into(db.emailBodies).insert(
            EmailBodiesCompanion.insert(
              emailId: 'acc-1:INBOX:42',
              attachmentsJson: const Value('not-a-list'),
            ),
          );

      final snapshot = await loadMessageDebugSnapshot(
        db,
        const DebugMessageRef(
          accountId: 'acc-1',
          mailboxPath: 'INBOX',
          emailId: 'acc-1:INBOX:42',
        ),
      );

      expect(snapshot.body, isNotNull);
      expect(snapshot.attachments, isEmpty);
    });
  });

  group('decodeMessageDebugAddresses', () {
    test('empty string returns empty list', () {
      expect(decodeMessageDebugAddresses(''), isEmpty);
    });

    test('malformed JSON returns empty list', () {
      expect(decodeMessageDebugAddresses('not-json'), isEmpty);
    });

    test('parses the {"name": ..., "email": ...} shape used by the DB', () {
      final result = decodeMessageDebugAddresses(
        '[{"name":"Bob","email":"bob@example.com"},{"email":"noname@x"}]',
      );
      expect(result, hasLength(2));
      expect(result[0].name, 'Bob');
      expect(result[0].email, 'bob@example.com');
      expect(result[1].name, isNull);
      expect(result[1].email, 'noname@x');
    });
  });
}
