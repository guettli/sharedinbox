import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/sync/message_debug_service.dart';
import 'package:sharedinbox/core/sync/message_probe.dart';
import 'package:sharedinbox/data/db/database.dart';

import 'db_test_helper.dart';

void main() {
  setUpAll(configureSqliteForTests);

  group('loadMessageDebugSnapshot', () {
    late AppDatabase db;

    setUp(() async {
      db = openTestDatabase();
      await _seedAccount(db, 'acc-1');
    });

    tearDown(() => db.close());

    test('projects every column of an existing Emails row', () async {
      await _seedEmail(
        db,
        id: 'acc-1:42',
        accountId: 'acc-1',
        uid: 42,
        subject: 'Hello',
        messageId: '<m1@example.com>',
        inReplyTo: '<parent@example.com>',
        references: '<a@x> <b@x>',
        preview: 'A preview',
        isSeen: true,
        isFlagged: true,
        hasAttachment: true,
        listUnsubscribeHeader: '<https://x/unsub>',
      );

      final snapshot = await loadMessageDebugSnapshot(
        db,
        const DebugMessageRef(
          accountId: 'acc-1',
          mailboxPath: 'INBOX',
          emailId: 'acc-1:42',
        ),
      );

      final email = snapshot.email!;
      expect(email.id, 'acc-1:42');
      expect(email.accountId, 'acc-1');
      expect(email.mailboxPath, 'INBOX');
      expect(email.uid, 42);
      expect(email.subject, 'Hello');
      expect(email.messageId, '<m1@example.com>');
      expect(email.inReplyTo, '<parent@example.com>');
      expect(email.references, '<a@x> <b@x>');
      expect(email.preview, 'A preview');
      expect(email.isSeen, isTrue);
      expect(email.isFlagged, isTrue);
      expect(email.hasAttachment, isTrue);
      expect(email.listUnsubscribeHeader, '<https://x/unsub>');
    });

    test('returns email == null when the message id has no local row',
        () async {
      final snapshot = await loadMessageDebugSnapshot(
        db,
        const DebugMessageRef(
          accountId: 'acc-1',
          mailboxPath: 'INBOX',
          emailId: 'acc-1:missing',
        ),
      );

      expect(snapshot.email, isNull);
      expect(snapshot.body, isNull);
      expect(snapshot.pending, isEmpty);
      expect(snapshot.syncStates, isEmpty);
      expect(snapshot.lastSyncLog, isNull);
      expect(snapshot.attachments, isEmpty);
    });

    test('reports body length in bytes when a body row is cached', () async {
      await _seedEmail(db, id: 'acc-1:1', accountId: 'acc-1');
      await db.into(db.emailBodies).insert(
            EmailBodiesCompanion.insert(
              emailId: 'acc-1:1',
              textBody: const Value('hello'),
              htmlBody: const Value('<p>hello</p>'),
              cachedAt: Value(DateTime.utc(2026, 6, 1, 12)),
            ),
          );

      final snapshot = await loadMessageDebugSnapshot(
        db,
        const DebugMessageRef(
          accountId: 'acc-1',
          mailboxPath: 'INBOX',
          emailId: 'acc-1:1',
        ),
      );

      expect(snapshot.body, isNotNull);
      // Drift returns DateTime in local time — compare as an instant.
      expect(
        snapshot.body!.cachedAt!.toUtc(),
        DateTime.utc(2026, 6, 1, 12),
      );
      expect(snapshot.body!.textBodyLength, 'hello'.length);
      expect(snapshot.body!.htmlBodyLength, '<p>hello</p>'.length);
    });

    test('decodes attachments from a JSON-encoded EmailBodies row', () async {
      await _seedEmail(db, id: 'acc-1:2', accountId: 'acc-1');
      await db.into(db.emailBodies).insert(
            EmailBodiesCompanion.insert(
              emailId: 'acc-1:2',
              attachmentsJson: const Value(
                '[{"filename":"a.pdf","contentType":"application/pdf",'
                '"size":123,"fetchPartId":"1.2"}]',
              ),
            ),
          );

      final snapshot = await loadMessageDebugSnapshot(
        db,
        const DebugMessageRef(
          accountId: 'acc-1',
          mailboxPath: 'INBOX',
          emailId: 'acc-1:2',
        ),
      );

      expect(snapshot.attachments, hasLength(1));
      final a = snapshot.attachments.single;
      expect(a.filename, 'a.pdf');
      expect(a.contentType, 'application/pdf');
      expect(a.size, 123);
      expect(a.fetchPartId, '1.2');
    });

    test('returns empty attachments list for malformed attachmentsJson',
        () async {
      await _seedEmail(db, id: 'acc-1:3', accountId: 'acc-1');
      await db.into(db.emailBodies).insert(
            EmailBodiesCompanion.insert(
              emailId: 'acc-1:3',
              attachmentsJson: const Value('not valid json'),
            ),
          );

      final snapshot = await loadMessageDebugSnapshot(
        db,
        const DebugMessageRef(
          accountId: 'acc-1',
          mailboxPath: 'INBOX',
          emailId: 'acc-1:3',
        ),
      );

      expect(snapshot.body, isNotNull);
      expect(snapshot.attachments, isEmpty);
    });

    test('collects pending changes for the message ordered by createdAt',
        () async {
      await _seedEmail(db, id: 'acc-1:4', accountId: 'acc-1');
      final now = DateTime.utc(2026, 6, 1, 12);
      // Insert out of order to prove the query orders by createdAt asc.
      await db.into(db.pendingChanges).insert(
            PendingChangesCompanion.insert(
              accountId: 'acc-1',
              resourceType: 'Email',
              resourceId: 'acc-1:4',
              changeType: 'flag_flagged',
              payload: '{"flagged":true}',
              createdAt: now.add(const Duration(minutes: 5)),
              attempts: const Value(2),
              lastError: const Value('boom'),
            ),
          );
      await db.into(db.pendingChanges).insert(
            PendingChangesCompanion.insert(
              accountId: 'acc-1',
              resourceType: 'Email',
              resourceId: 'acc-1:4',
              changeType: 'flag_seen',
              payload: '{"seen":true}',
              createdAt: now,
            ),
          );
      // Unrelated message on the same account — must not be included.
      await db.into(db.pendingChanges).insert(
            PendingChangesCompanion.insert(
              accountId: 'acc-1',
              resourceType: 'Email',
              resourceId: 'acc-1:99',
              changeType: 'flag_seen',
              payload: '{"seen":true}',
              createdAt: now,
            ),
          );

      final snapshot = await loadMessageDebugSnapshot(
        db,
        const DebugMessageRef(
          accountId: 'acc-1',
          mailboxPath: 'INBOX',
          emailId: 'acc-1:4',
        ),
      );

      expect(snapshot.pending, hasLength(2));
      expect(snapshot.pending.first.changeType, 'flag_seen');
      expect(snapshot.pending.last.changeType, 'flag_flagged');
      expect(snapshot.pending.last.attempts, 2);
      expect(snapshot.pending.last.lastError, 'boom');
    });

    test('returns all SyncStates rows for the account', () async {
      await _seedEmail(db, id: 'acc-1:5', accountId: 'acc-1');
      await db.into(db.syncStates).insert(
            SyncStatesCompanion.insert(
              accountId: 'acc-1',
              resourceType: 'mailboxes',
              state: 'state-mbox',
              syncedAt: DateTime.utc(2026, 6, 1, 10),
            ),
          );
      await db.into(db.syncStates).insert(
            SyncStatesCompanion.insert(
              accountId: 'acc-1',
              resourceType: 'emails',
              state: 'state-emails',
              syncedAt: DateTime.utc(2026, 6, 1, 11),
            ),
          );
      // Different account — must be filtered out.
      await _seedAccount(db, 'acc-2');
      await db.into(db.syncStates).insert(
            SyncStatesCompanion.insert(
              accountId: 'acc-2',
              resourceType: 'emails',
              state: 'other',
              syncedAt: DateTime.utc(2026, 6, 1, 11),
            ),
          );

      final snapshot = await loadMessageDebugSnapshot(
        db,
        const DebugMessageRef(
          accountId: 'acc-1',
          mailboxPath: 'INBOX',
          emailId: 'acc-1:5',
        ),
      );

      final types = snapshot.syncStates.map((s) => s.resourceType).toSet();
      expect(types, {'mailboxes', 'emails'});
    });

    test('returns the most recent SyncLogs row for the account', () async {
      await _seedEmail(db, id: 'acc-1:6', accountId: 'acc-1');
      await db.into(db.syncLogs).insert(
            SyncLogsCompanion.insert(
              accountId: 'acc-1',
              result: 'ok',
              startedAt: DateTime.utc(2026, 6, 1, 10),
              finishedAt: DateTime.utc(2026, 6, 1, 10, 0, 5),
            ),
          );
      await db.into(db.syncLogs).insert(
            SyncLogsCompanion.insert(
              accountId: 'acc-1',
              result: 'error',
              errorMessage: const Value('timeout'),
              startedAt: DateTime.utc(2026, 6, 1, 12),
              finishedAt: DateTime.utc(2026, 6, 1, 12, 0, 30),
            ),
          );

      final snapshot = await loadMessageDebugSnapshot(
        db,
        const DebugMessageRef(
          accountId: 'acc-1',
          mailboxPath: 'INBOX',
          emailId: 'acc-1:6',
        ),
      );

      expect(snapshot.lastSyncLog, isNotNull);
      expect(snapshot.lastSyncLog!.result, 'error');
      expect(snapshot.lastSyncLog!.errorMessage, 'timeout');
      // Drift returns DateTime in local time — compare as an instant.
      expect(
        snapshot.lastSyncLog!.finishedAt.toUtc(),
        DateTime.utc(2026, 6, 1, 12, 0, 30),
      );
    });
  });

  group('buildMessageDebugMarkdown', () {
    test('reports a missing local row', () {
      final md = buildMessageDebugMarkdown(_emptySnapshot());
      expect(md, contains('No local row found for this message id.'));
    });

    test('renders local state and marks an uncached body', () {
      final md = buildMessageDebugMarkdown(_snapshot());

      expect(md, contains('# Mail debug report'));
      expect(md, contains('## Local state'));
      expect(md, contains('| subject | Hello |'));
      expect(md, contains('| messageId | <m1@example.com> |'));
      expect(md, contains('## Body'));
      expect(md, contains('| body | (not cached) |'));
      // No remote section unless a probe is supplied.
      expect(md, isNot(contains('## Remote state')));
    });

    test('reports cached body byte lengths', () {
      final md = buildMessageDebugMarkdown(
        _snapshot(
          body: MessageDebugBody(
            cachedAt: DateTime.utc(2026, 6, 1, 12),
            textBodyLength: 5,
            htmlBodyLength: 12,
          ),
        ),
      );

      expect(md, contains('| textBytes | 5 |'));
      expect(md, contains('| htmlBytes | 12 |'));
    });

    test('lists pending mutations', () {
      final md = buildMessageDebugMarkdown(
        _snapshot(
          pending: [
            MessageDebugPending(
              changeType: 'flag_seen',
              attempts: 2,
              createdAt: DateTime.utc(2026, 6, 1, 12),
              lastError: 'boom',
              payload: '{"seen":true}',
            ),
          ],
        ),
      );

      expect(md, contains('## Pending changes (1)'));
      expect(md, contains('| changeType | flag_seen |'));
      expect(md, contains('| lastError | boom |'));
    });

    test('flags a local-vs-remote mismatch when a probe is supplied', () {
      final md = buildMessageDebugMarkdown(
        _snapshot(),
        probe: const ProbeResult.snapshot(
          RemoteMessageSnapshot(
            mailboxPath: 'INBOX',
            subject: 'A different subject',
            messageId: '<m1@example.com>',
            isSeen: false,
            isFlagged: false,
            hasAttachment: false,
            uid: 42,
            headers: {'x-debug': 'yes'},
          ),
        ),
      );

      expect(md, contains('## Remote state'));
      expect(md, contains('### Local vs remote'));
      expect(md, contains('Mismatch:'));
      expect(md, contains('subject'));
      expect(md, contains('### Headers'));
      expect(md, contains('| x-debug | yes |'));
    });

    test('reports a matching probe result', () {
      final md = buildMessageDebugMarkdown(
        // Empty from/to and no sentAt so every compared field lines up with
        // the remote snapshot below.
        _snapshot(email: _email(fromJson: '', toAddresses: '')),
        probe: const ProbeResult.snapshot(
          RemoteMessageSnapshot(
            mailboxPath: 'INBOX',
            subject: 'Hello',
            messageId: '<m1@example.com>',
            isSeen: false,
            isFlagged: false,
            hasAttachment: false,
            uid: 42,
          ),
        ),
      );

      expect(
        md,
        contains('Match: local and remote agree on every checked field.'),
      );
    });

    test('surfaces a probe error', () {
      final md = buildMessageDebugMarkdown(
        _snapshot(),
        probe: const ProbeResult.error('Offline: no route to host'),
      );
      expect(md, contains('Remote fetch failed: Offline: no route to host'));
    });

    test('escapes pipes and collapses newlines inside table cells', () {
      final md = buildMessageDebugMarkdown(
        _snapshot(
          email: _email(
            subject: 'a | b',
            preview: 'line one\nline two',
          ),
        ),
      );

      expect(md, contains(r'| subject | a \| b |'));
      expect(md, contains('| preview | line one line two |'));
    });
  });

  group('decodeMessageDebugAddresses', () {
    test('returns const empty list for empty input', () {
      expect(decodeMessageDebugAddresses(''), isEmpty);
      expect(decodeMessageDebugAddresses('   '), isEmpty);
    });

    test('decodes a well-formed JSON list', () {
      final result = decodeMessageDebugAddresses(
        '[{"name":"Alice","email":"a@example.com"},'
        '{"email":"b@example.com"}]',
      );
      expect(result, hasLength(2));
      expect(result[0].name, 'Alice');
      expect(result[0].email, 'a@example.com');
      expect(result[1].name, isNull);
      expect(result[1].email, 'b@example.com');
    });

    test('returns empty list when the top-level JSON value is not a list', () {
      expect(decodeMessageDebugAddresses('{"name":"x"}'), isEmpty);
    });

    test('returns empty list when the JSON cannot be parsed', () {
      expect(decodeMessageDebugAddresses('not-json'), isEmpty);
    });
  });
}

MessageDebugEmail _email({
  String subject = 'Hello',
  String? preview = 'A preview',
  DateTime? sentAt,
  String fromJson = '[{"email":"a@example.com"}]',
  String toAddresses = '[{"email":"b@example.com"}]',
}) {
  return MessageDebugEmail(
    id: 'acc-1:42',
    accountId: 'acc-1',
    mailboxPath: 'INBOX',
    uid: 42,
    subject: subject,
    sentAt: sentAt,
    receivedAt: DateTime.utc(2026, 1, 1, 12),
    fromJson: fromJson,
    toAddresses: toAddresses,
    ccJson: '',
    preview: preview,
    isSeen: false,
    isFlagged: false,
    hasAttachment: false,
    threadId: null,
    messageId: '<m1@example.com>',
    inReplyTo: null,
    references: null,
    snoozedUntil: null,
    snoozedFromMailboxPath: null,
    listUnsubscribeHeader: null,
  );
}

/// Builds a snapshot whose email defaults to [_email]. Pass `email: null` (via
/// the [_emptySnapshot] helper below) to exercise the missing-row path.
MessageDebugSnapshot _snapshot({
  MessageDebugEmail? email,
  MessageDebugBody? body,
  List<MessageDebugPending> pending = const [],
  List<EmailAttachment> attachments = const [],
}) {
  return MessageDebugSnapshot(
    email: email ?? _email(),
    body: body,
    pending: pending,
    syncStates: const [],
    lastSyncLog: null,
    attachments: attachments,
  );
}

MessageDebugSnapshot _emptySnapshot() => const MessageDebugSnapshot(
      email: null,
      body: null,
      pending: [],
      syncStates: [],
      lastSyncLog: null,
      attachments: [],
    );

Future<void> _seedAccount(AppDatabase db, String id) async {
  await db.into(db.accounts).insert(
        AccountsCompanion.insert(
          id: id,
          displayName: id,
          email: '$id@example.com',
          imapHost: 'mail.example.com',
          imapPort: 143,
          imapSsl: false,
          smtpHost: 'smtp.example.com',
          smtpPort: 25,
          smtpSsl: false,
        ),
      );
}

Future<void> _seedEmail(
  AppDatabase db, {
  required String id,
  required String accountId,
  String mailboxPath = 'INBOX',
  int uid = 1,
  String? subject,
  String? messageId,
  String? inReplyTo,
  String? references,
  String? preview,
  bool isSeen = false,
  bool isFlagged = false,
  bool hasAttachment = false,
  String? listUnsubscribeHeader,
}) async {
  await db.into(db.emails).insert(
        EmailsCompanion.insert(
          id: id,
          accountId: accountId,
          mailboxPath: mailboxPath,
          uid: uid,
          receivedAt: DateTime.utc(2026, 1, 1, 12),
          subject: Value(subject),
          messageId: Value(messageId),
          inReplyTo: Value(inReplyTo),
          references: Value(references),
          preview: Value(preview),
          isSeen: Value(isSeen),
          isFlagged: Value(isFlagged),
          hasAttachment: Value(hasAttachment),
          listUnsubscribeHeader: Value(listUnsubscribeHeader),
        ),
      );
}
