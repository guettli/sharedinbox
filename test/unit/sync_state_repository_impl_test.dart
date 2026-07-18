import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/sync_state_repository_impl.dart';

import 'db_test_helper.dart';

void main() {
  configureSqliteForTests();

  late AppDatabase db;
  late SyncStateRepositoryImpl repo;

  const accountId = 'acc1';

  setUp(() async {
    db = openTestDatabase();
    repo = SyncStateRepositoryImpl(db);

    await db.into(db.accounts).insert(
          AccountsCompanion.insert(
            id: accountId,
            displayName: 'Test',
            email: 'test@example.com',
            imapHost: 'imap.example.com',
            imapPort: 993,
            imapSsl: true,
            smtpHost: 'smtp.example.com',
            smtpPort: 587,
            smtpSsl: true,
          ),
        );
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> insertMailbox({
    required String path,
    int totalCount = 0,
    String? role,
  }) async {
    await db.into(db.mailboxes).insert(
          MailboxesCompanion.insert(
            id: '$accountId:$path',
            accountId: accountId,
            path: path,
            name: path,
            totalCount: Value(totalCount),
            role: Value(role),
            displayPath: Value(path),
          ),
        );
  }

  Future<void> insertEmail({
    required String id,
    required String mailboxPath,
    required int uid,
    bool hasAttachment = false,
  }) async {
    await db.into(db.emails).insert(
          EmailsCompanion.insert(
            id: id,
            accountId: accountId,
            mailboxPath: mailboxPath,
            uid: uid,
            receivedAt: DateTime(2026, 1, 1),
            hasAttachment: Value(hasAttachment),
          ),
        );
  }

  Future<void> insertBody({
    required String emailId,
    String? textBody,
    String? htmlBody,
    List<Map<String, dynamic>> attachments = const [],
    int? bodySize,
  }) async {
    final defaultBodySize =
        (textBody?.length ?? 0) + (htmlBody?.length ?? 0);
    await db.into(db.emailBodies).insert(
          EmailBodiesCompanion.insert(
            emailId: emailId,
            textBody: Value(textBody),
            htmlBody: Value(htmlBody),
            attachmentsJson: Value(jsonEncode(attachments)),
            cachedAt: Value(DateTime(2026, 1, 2)),
            bodySize: Value(bodySize ?? defaultBodySize),
          ),
        );
  }

  Future<void> insertAttachmentFile({
    required String emailId,
    required String filename,
    required int size,
  }) async {
    await db.into(db.attachmentFiles).insert(
          AttachmentFilesCompanion.insert(
            emailId: emailId,
            filename: filename,
            size: size,
            downloadedAt: DateTime(2026, 1, 3),
          ),
        );
  }

  test('buckets emails into fully-offline / partial / header-only', () async {
    await insertMailbox(path: 'INBOX', totalCount: 4);

    // 1) Fully offline: body + no attachments
    await insertEmail(id: '$accountId:INBOX:1', mailboxPath: 'INBOX', uid: 1);
    await insertBody(
      emailId: '$accountId:INBOX:1',
      textBody: 'hello world',
    );

    // 2) Fully offline: body + all attachments on disk
    await insertEmail(
      id: '$accountId:INBOX:2',
      mailboxPath: 'INBOX',
      uid: 2,
      hasAttachment: true,
    );
    await insertBody(
      emailId: '$accountId:INBOX:2',
      textBody: 'x' * 100,
      attachments: [
        {'filename': 'a.pdf', 'contentType': 'application/pdf', 'size': 1024},
      ],
    );
    await insertAttachmentFile(
      emailId: '$accountId:INBOX:2',
      filename: 'a.pdf',
      size: 1024,
    );

    // 3) Partial: body + one attachment missing
    await insertEmail(
      id: '$accountId:INBOX:3',
      mailboxPath: 'INBOX',
      uid: 3,
      hasAttachment: true,
    );
    await insertBody(
      emailId: '$accountId:INBOX:3',
      textBody: 'y' * 50,
      attachments: [
        {'filename': 'first.png', 'contentType': 'image/png', 'size': 500},
        {'filename': 'second.png', 'contentType': 'image/png', 'size': 700},
      ],
    );
    await insertAttachmentFile(
      emailId: '$accountId:INBOX:3',
      filename: 'first.png',
      size: 500,
    );

    // 4) Header-only: no body row
    await insertEmail(id: '$accountId:INBOX:4', mailboxPath: 'INBOX', uid: 4);

    final states = await repo.statesForAccount(accountId);
    expect(states, hasLength(1));
    final inbox = states.single;
    expect(inbox.mailboxPath, 'INBOX');
    expect(inbox.fullyOfflineCount, 2);
    // 11 + (100 + 1024) = 1135
    expect(inbox.fullyOfflineBytes, 11 + 100 + 1024);
    expect(inbox.partialCount, 1);
    // 50 + 500 = 550
    expect(inbox.partialBytes, 50 + 500);
    expect(inbox.headerOnlyCount, 1);
    expect(inbox.serverOnlyCount, 0);
  });

  test('server-only count reflects server total minus local rows', () async {
    // Server says 10 mails but only 2 are locally imported.
    await insertMailbox(path: 'INBOX', totalCount: 10);
    await insertEmail(id: '$accountId:INBOX:1', mailboxPath: 'INBOX', uid: 1);
    await insertEmail(id: '$accountId:INBOX:2', mailboxPath: 'INBOX', uid: 2);

    final states = await repo.statesForAccount(accountId);
    expect(states.single.serverOnlyCount, 8);
    expect(states.single.headerOnlyCount, 2);
  });

  test('server-only clamps to zero if local exceeds server count', () async {
    // Server count is stale — locally we have more rows than the server reports.
    await insertMailbox(path: 'INBOX', totalCount: 1);
    await insertEmail(id: '$accountId:INBOX:1', mailboxPath: 'INBOX', uid: 1);
    await insertEmail(id: '$accountId:INBOX:2', mailboxPath: 'INBOX', uid: 2);

    final states = await repo.statesForAccount(accountId);
    expect(states.single.serverOnlyCount, 0);
  });

  test('empty mailboxes report zero counts', () async {
    await insertMailbox(path: 'INBOX', totalCount: 0);
    await insertMailbox(path: 'Trash', totalCount: 0);

    final states = await repo.statesForAccount(accountId);
    expect(states, hasLength(2));
    expect(states.every((s) => s.totalCount == 0), isTrue);
  });

  test('sorts mailboxes with inbox first', () async {
    await insertMailbox(path: 'Zeta', totalCount: 0);
    await insertMailbox(path: 'INBOX', totalCount: 0, role: 'inbox');
    await insertMailbox(path: 'Alpha', totalCount: 0);

    final states = await repo.statesForAccount(accountId);
    expect(
      states.map((s) => s.mailboxPath).toList(),
      ['INBOX', 'Alpha', 'Zeta'],
    );
  });
}
