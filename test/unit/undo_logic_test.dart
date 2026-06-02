import 'dart:convert';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';
import 'package:sharedinbox/data/repositories/undo_repository_impl.dart';
import 'package:sharedinbox/di.dart';

import 'account_repository_impl_test.dart' show MapSecureStorage;
import 'db_test_helper.dart';

void main() {
  late AppDatabase db;
  late EmailRepositoryImpl repo;
  late AccountRepositoryImpl accounts;
  late ProviderContainer container;

  setUpAll(() {
    configureSqliteForTests();
  });

  setUp(() async {
    db = openTestDatabase();
    accounts = AccountRepositoryImpl(db, MapSecureStorage());
    repo = EmailRepositoryImpl(db, accounts);

    container = ProviderContainer(
      overrides: [
        dbProvider.overrideWithValue(db),
        accountRepositoryProvider.overrideWithValue(accounts),
        emailRepositoryProvider.overrideWithValue(repo),
        undoRepositoryProvider.overrideWithValue(UndoRepositoryImpl(db)),
      ],
    );

    // Setup IMAP account
    const account = Account(
      id: 'acc1',
      displayName: 'Alice',
      email: 'alice@example.com',
      imapHost: 'imap.example.com',
      smtpHost: 'smtp.example.com',
    );
    await accounts.addAccount(account, 'password');

    // Setup Inbox and Trash mailboxes
    await db.into(db.mailboxes).insert(
          MailboxesCompanion.insert(
            id: 'acc1:INBOX',
            accountId: 'acc1',
            path: 'INBOX',
            name: 'Inbox',
          ),
        );
    await db.into(db.mailboxes).insert(
          MailboxesCompanion.insert(
            id: 'acc1:Trash',
            accountId: 'acc1',
            path: 'Trash',
            name: 'Trash',
            role: const Value('trash'),
          ),
        );

    // Setup an email in Inbox
    await db.into(db.emails).insert(
          EmailsCompanion.insert(
            id: 'acc1:101',
            accountId: 'acc1',
            mailboxPath: 'INBOX',
            uid: 101,
            subject: const Value('Test Email'),
            receivedAt: DateTime.now(),
          ),
        );
  });

  tearDown(() async {
    await db.close();
    container.dispose();
  });

  test('Undo deletion fails for IMAP (Reproduction)', () async {
    const emailId = 'acc1:101';

    // 0. Fetch BEFORE deleting
    final original = await repo.getEmail(emailId);

    // 1. Delete the email
    await repo.deleteEmail(emailId);

    // Verify it moved from INBOX (locally deleted for IMAP move)
    final inInbox = await (db.select(db.emails)
          ..where((t) => t.id.equals(emailId))
          ..where((t) => t.mailboxPath.equals('INBOX')))
        .get();
    expect(inInbox, isEmpty, reason: 'Email should be gone from Inbox');

    // 2. Push undo action and undo
    final action = UndoAction(
      id: 'undo1',
      accountId: 'acc1',
      type: UndoType.delete,
      emailIds: [emailId],
      sourceMailboxPath: 'INBOX',
      originalEmails: [original!],
    );
    await container.read(undoServiceProvider.notifier).pushAction(action);
    await container.read(undoServiceProvider.notifier).undo();

    // 3. Verify it is back in Inbox
    final restored = await (db.select(db.emails)
          ..where((t) => t.id.equals(emailId))
          ..where((t) => t.mailboxPath.equals('INBOX')))
        .get();

    expect(
      restored,
      isNotEmpty,
      reason: 'Email should be restored to Inbox after undo',
    );
  });

  test('Undo deletion works for JMAP', () async {
    const emailId = 'jmap1:e101';

    // Setup JMAP account
    const jmapAccount = Account(
      id: 'jmap1',
      displayName: 'Alice JMAP',
      email: 'alice@example.com',
      type: AccountType.jmap,
      jmapUrl: 'https://jmap.example.com/',
      imapHost: 'imap.example.com',
      smtpHost: 'smtp.example.com',
    );
    await accounts.addAccount(jmapAccount, 'password');

    // Setup Inbox and Trash mailboxes for JMAP
    await db.into(db.mailboxes).insert(
          MailboxesCompanion.insert(
            id: 'jmap1:INBOX',
            accountId: 'jmap1',
            path: 'INBOX',
            name: 'Inbox',
            role: const Value('inbox'),
          ),
        );
    await db.into(db.mailboxes).insert(
          MailboxesCompanion.insert(
            id: 'jmap1:Trash',
            accountId: 'jmap1',
            path: 'Trash',
            name: 'Trash',
            role: const Value('trash'),
          ),
        );

    // Setup an email in JMAP Inbox
    await db.into(db.emails).insert(
          EmailsCompanion.insert(
            id: emailId,
            accountId: 'jmap1',
            mailboxPath: 'INBOX',
            uid: 0, // not used for JMAP ID
            subject: const Value('JMAP Test Email'),
            receivedAt: DateTime.now(),
          ),
        );

    // 1. Delete the email
    await repo.deleteEmail(emailId);

    // Verify it moved to Trash locally (JMAP moveEmail updates mailboxPath)
    final inTrash = await (db.select(db.emails)
          ..where((t) => t.id.equals(emailId))
          ..where((t) => t.mailboxPath.equals('Trash')))
        .get();
    expect(inTrash, isNotEmpty, reason: 'Email should be in Trash');

    // 2. Push undo action and undo
    final action = UndoAction(
      id: 'undo2',
      accountId: 'jmap1',
      type: UndoType.delete,
      emailIds: [emailId],
      sourceMailboxPath: 'INBOX',
    );
    await container.read(undoServiceProvider.notifier).pushAction(action);
    await container.read(undoServiceProvider.notifier).undo();

    // 3. Verify it is back in Inbox
    final restored = await (db.select(db.emails)
          ..where((t) => t.id.equals(emailId))
          ..where((t) => t.mailboxPath.equals('INBOX')))
        .get();
    expect(
      restored,
      isNotEmpty,
      reason: 'JMAP email should be restored to Inbox after undo',
    );
  });

  test(
    'Undo deletion for IMAP enqueues reverse move if cancel fails',
    () async {
      const emailId = 'acc1:101';
      final original = await repo.getEmail(emailId);

      // 1. Delete
      final destPath = await repo.deleteEmail(emailId);
      expect(destPath, 'Trash');

      // 2. Mark the pending change as "attempted" so it cannot be cancelled
      await (db.update(db.pendingChanges)
            ..where((t) => t.resourceId.equals(emailId)))
          .write(const PendingChangesCompanion(attempts: Value(1)));

      // 3. Undo
      final action = UndoAction(
        id: 'undo3',
        accountId: 'acc1',
        type: UndoType.delete,
        emailIds: [emailId],
        sourceMailboxPath: 'INBOX',
        destinationMailboxPath: destPath,
        originalEmails: [original!],
      );
      await container.read(undoServiceProvider.notifier).pushAction(action);
      await container.read(undoServiceProvider.notifier).undo();

      // 4. Verify local state
      final restored = await (db.select(db.emails)
            ..where((t) => t.id.equals(emailId))
            ..where((t) => t.mailboxPath.equals('INBOX')))
          .get();
      expect(restored, isNotEmpty);

      // 5. Verify a NEW pending change was enqueued (Trash -> INBOX)
      final changes = await db.select(db.pendingChanges).get();
      final reverseMove = changes.firstWhere(
        (c) => c.changeType == 'move' && c.attempts == 0,
      );
      final payload = jsonDecode(reverseMove.payload) as Map<String, dynamic>;
      expect(payload['mailboxPath'], 'Trash');
      expect(payload['dest'], 'INBOX');
    },
  );

  test(
    'Undo deletion for IMAP succeeds after sync assigned new UID (message-id lookup)',
    () async {
      const oldEmailId = 'acc1:101';
      final original = await repo.getEmail(oldEmailId);
      expect(original, isNotNull);
      expect(original!.messageId, isNull); // set a messageId so lookup works

      // Seed a messageId so undo can find the email after UID change.
      await (db.update(db.emails)..where((t) => t.id.equals(oldEmailId))).write(
        const EmailsCompanion(messageId: Value('msg-101@test')),
      );

      final originalWithMsgId = await repo.getEmail(oldEmailId);

      // 1. Delete → moves to Trash locally (uid=101, id='acc1:101')
      final destPath = await repo.deleteEmail(oldEmailId);
      expect(destPath, 'Trash');

      // 2. Simulate IMAP sync: the server assigned a new UID (205) in Trash.
      // The old row (acc1:101) is removed and a new row (acc1:205) is inserted.
      await (db.delete(db.emails)..where((t) => t.id.equals(oldEmailId))).go();
      await db.into(db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc1:205',
              accountId: 'acc1',
              mailboxPath: 'Trash',
              uid: 205,
              subject: const Value('Test Email'),
              receivedAt: DateTime.now(),
              messageId: const Value('msg-101@test'),
            ),
          );

      // Mark the original pending change as already applied (cannot cancel).
      await (db.update(db.pendingChanges)
            ..where((t) => t.resourceId.equals(oldEmailId)))
          .write(const PendingChangesCompanion(attempts: Value(1)));

      // 3. Undo using the old email id — undo must locate 'acc1:205' by message-id.
      final action = UndoAction(
        id: 'undo-uid-change',
        accountId: 'acc1',
        type: UndoType.delete,
        emailIds: [oldEmailId],
        sourceMailboxPath: 'INBOX',
        destinationMailboxPath: destPath,
        originalEmails: [originalWithMsgId!],
      );
      await container.read(undoServiceProvider.notifier).pushAction(action);
      await container.read(undoServiceProvider.notifier).undo();

      // 4. Verify the current email row is now in INBOX.
      final inInbox = await (db.select(
        db.emails,
      )..where((t) => t.mailboxPath.equals('INBOX')))
          .get();
      expect(
        inInbox,
        isNotEmpty,
        reason: 'Email should be in INBOX after undo',
      );

      // 5. Verify the pending change uses the new UID (205), not the old one (101).
      final changes = await db.select(db.pendingChanges).get();
      final reverseMove = changes.firstWhere(
        (c) => c.changeType == 'move' && c.attempts == 0,
      );
      final payload = jsonDecode(reverseMove.payload) as Map<String, dynamic>;
      expect(payload['uid'], 205, reason: 'Pending move must use the new UID');
      expect(payload['dest'], 'INBOX');
    },
  );

  test('Undo snooze clears snooze metadata and moves back', () async {
    const emailId = 'acc1:101';
    final original = await repo.getEmail(emailId);

    // 1. Snooze
    final until = DateTime(2026, 5, 10, 15);
    await repo.snoozeEmail(emailId, until);

    // Verify it snoozed locally
    var email = await repo.getEmail(emailId);
    expect(email!.mailboxPath, 'Snoozed');
    expect(email.snoozedUntil, until);

    // 2. Undo
    final action = UndoAction(
      id: 'undo4',
      accountId: 'acc1',
      type: UndoType.snooze,
      emailIds: [emailId],
      sourceMailboxPath: 'INBOX',
      originalEmails: [original!],
    );
    await container.read(undoServiceProvider.notifier).pushAction(action);
    await container.read(undoServiceProvider.notifier).undo();

    // 3. Verify it is back in Inbox and metadata is cleared
    email = await repo.getEmail(emailId);
    expect(email!.mailboxPath, 'INBOX');
    expect(email.snoozedUntil, isNull);
    expect(email.snoozedFromMailboxPath, isNull);
  });
}
