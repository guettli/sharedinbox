import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';
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
    await db.into(db.mailboxes).insert(MailboxesCompanion.insert(
          id: 'acc1:INBOX',
          accountId: 'acc1',
          path: 'INBOX',
          name: 'Inbox',
        ),);
    await db.into(db.mailboxes).insert(MailboxesCompanion.insert(
          id: 'acc1:Trash',
          accountId: 'acc1',
          path: 'Trash',
          name: 'Trash',
          role: const Value('trash'),
        ),);

    // Setup an email in Inbox
    await db.into(db.emails).insert(EmailsCompanion.insert(
          id: 'acc1:101',
          accountId: 'acc1',
          mailboxPath: 'INBOX',
          uid: 101,
          subject: const Value('Test Email'),
          receivedAt: DateTime.now(),
        ),);
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
    container.read(undoServiceProvider.notifier).pushAction(action);
    await container.read(undoServiceProvider.notifier).undo();

    // 3. Verify it is back in Inbox
    final restored = await (db.select(db.emails)
          ..where((t) => t.id.equals(emailId))
          ..where((t) => t.mailboxPath.equals('INBOX')))
        .get();
    
    expect(restored, isNotEmpty, reason: 'Email should be restored to Inbox after undo');
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
    await db.into(db.mailboxes).insert(MailboxesCompanion.insert(
          id: 'jmap1:INBOX',
          accountId: 'jmap1',
          path: 'INBOX',
          name: 'Inbox',
          role: const Value('inbox'),
        ),);
    await db.into(db.mailboxes).insert(MailboxesCompanion.insert(
          id: 'jmap1:Trash',
          accountId: 'jmap1',
          path: 'Trash',
          name: 'Trash',
          role: const Value('trash'),
        ),);

    // Setup an email in JMAP Inbox
    await db.into(db.emails).insert(EmailsCompanion.insert(
          id: emailId,
          accountId: 'jmap1',
          mailboxPath: 'INBOX',
          uid: 0, // not used for JMAP ID
          subject: const Value('JMAP Test Email'),
          receivedAt: DateTime.now(),
        ),);

    // 1. Delete the email
    await repo.deleteEmail(emailId);

    // Verify it moved to Trash locally (JMAP moveEmail updates mailboxPath)
    final inTrash = await (db.select(db.emails)
          ..where((t) => t.id.equals(emailId))
          ..where((t) => t.mailboxPath.equals('Trash')))
        .get();
    expect(inTrash, isNotEmpty, reason: 'Email should be in Trash');

    // 2. Push undo action and undo
    const action = UndoAction(
      id: 'undo2',
      accountId: 'jmap1',
      type: UndoType.delete,
      emailIds: [emailId],
      sourceMailboxPath: 'INBOX',
    );
    container.read(undoServiceProvider.notifier).pushAction(action);
    await container.read(undoServiceProvider.notifier).undo();

    // 3. Verify it is back in Inbox
    final restored = await (db.select(db.emails)
          ..where((t) => t.id.equals(emailId))
          ..where((t) => t.mailboxPath.equals('INBOX')))
        .get();
    expect(restored, isNotEmpty, reason: 'JMAP email should be restored to Inbox after undo');
  });
}
