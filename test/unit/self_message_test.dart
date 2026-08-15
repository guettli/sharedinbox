import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account, Email;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';

import 'account_repository_impl_test.dart' show MapSecureStorage;
import 'db_test_helper.dart';

// Mail-to-self "virtual" message support (#545): a mail addressed to one of the
// user's own accounts appears in the inbox immediately for note-taking, and is
// dissolved into the real message once it arrives via sync.

const _account = Account(
  id: 'acc-1',
  displayName: 'Alice',
  email: 'alice@example.com',
  imapHost: 'imap.example.com',
  smtpHost: 'smtp.example.com',
);

Future<imap.ImapClient> _noImapConnect(Account a, String u, String p) =>
    Future.error(UnsupportedError('IMAP unavailable in unit tests'));

Future<imap.SmtpClient> _noSmtpConnect(Account a, String u, String p) =>
    Future.error(UnsupportedError('SMTP unavailable in unit tests'));

({AppDatabase db, AccountRepositoryImpl accounts, EmailRepositoryImpl emails})
    _makeRepos() {
  final db = openTestDatabase();
  final accounts = AccountRepositoryImpl(db, MapSecureStorage());
  final emails = EmailRepositoryImpl(
    db,
    accounts,
    imapConnect: _noImapConnect,
    smtpConnect: _noSmtpConnect,
  );
  return (db: db, accounts: accounts, emails: emails);
}

Future<void> _seedMailbox(
  AppDatabase db,
  String path,
  String role,
) =>
    db.into(db.mailboxes).insert(
          MailboxesCompanion.insert(
            id: 'acc-1:$path',
            accountId: 'acc-1',
            path: path,
            name: path,
            role: Value(role),
          ),
        );

EmailDraft _draftTo(String recipient, {String subject = 'note'}) => EmailDraft(
      from: const EmailAddress(email: 'alice@example.com'),
      to: [EmailAddress(email: recipient)],
      cc: const [],
      subject: subject,
      body: 'remember milk',
    );

/// Inserts a row that mimics what the sync engine writes when the real message
/// arrives, sharing [messageId] with the virtual copy.
Future<String> _insertRealArrival(
  AppDatabase db,
  String messageId, {
  String mailboxPath = 'INBOX',
  int uid = 42,
}) async {
  final id = 'acc-1:$mailboxPath:$uid';
  await db.into(db.emails).insert(
        EmailsCompanion.insert(
          id: id,
          accountId: 'acc-1',
          mailboxPath: mailboxPath,
          uid: uid,
          receivedAt: DateTime(2024, 6),
          subject: const Value('note'),
          messageId: Value(messageId),
          threadId: Value(messageId),
          isSeen: const Value(false),
        ),
      );
  return id;
}

void main() {
  setUpAll(configureSqliteForTests);

  group('enqueueSend self-detection', () {
    test('creates a virtual inbox message for a mail to self', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      await _seedMailbox(r.db, 'INBOX', 'inbox');

      await r.emails.enqueueSend('acc-1', _draftTo('alice@example.com'));

      final inbox = await r.emails.observeEmails('acc-1', 'INBOX').first;
      expect(inbox, hasLength(1));
      final virtual = inbox.single;
      expect(virtual.isLocal, isTrue);
      expect(virtual.isSeen, isTrue, reason: 'self-sent, so pre-read');
      expect(virtual.subject, 'note');
      expect(virtual.messageId, isNotNull);
      expect(virtual.messageId, isNot(startsWith('<')));

      // The body is served from the local cache without touching the network.
      final body = await r.emails.getEmailBody(virtual.id);
      expect(body.textBody, 'remember milk');

      // The mail is still queued to actually be sent.
      final outbox = await r.db.select(r.db.outbox).get();
      expect(outbox, hasLength(1));

      // The queued MIME carries the same deterministic Message-ID so the real
      // message can be matched on arrival.
      final mime = utf8.decode(base64.decode(outbox.single.mimeBase64));
      expect(mime, contains(virtual.messageId!));
    });

    test('does not create a virtual message for a mail to someone else',
        () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      await _seedMailbox(r.db, 'INBOX', 'inbox');

      await r.emails.enqueueSend('acc-1', _draftTo('bob@other.example'));

      final inbox = await r.emails.observeEmails('acc-1', 'INBOX').first;
      expect(inbox, isEmpty);
      expect(await r.db.select(r.db.outbox).get(), hasLength(1));
    });

    test('address match is case-insensitive', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      await _seedMailbox(r.db, 'INBOX', 'inbox');

      await r.emails.enqueueSend('acc-1', _draftTo('Alice@Example.com'));

      final inbox = await r.emails.observeEmails('acc-1', 'INBOX').first;
      expect(inbox, hasLength(1));
    });
  });

  group('mutations on the virtual message', () {
    test('starring a virtual message does not queue a server change', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      await _seedMailbox(r.db, 'INBOX', 'inbox');
      await r.emails.enqueueSend('acc-1', _draftTo('alice@example.com'));
      final virtual =
          (await r.emails.observeEmails('acc-1', 'INBOX').first).single;

      await r.emails.setFlag(virtual.id, flagged: true);

      final updated =
          (await r.emails.observeEmails('acc-1', 'INBOX').first).single;
      expect(updated.isFlagged, isTrue);
      expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);
    });

    test('trashing a virtual message does not queue a server change', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      await _seedMailbox(r.db, 'INBOX', 'inbox');
      await _seedMailbox(r.db, 'Trash', 'trash');
      await r.emails.enqueueSend('acc-1', _draftTo('alice@example.com'));
      final virtual =
          (await r.emails.observeEmails('acc-1', 'INBOX').first).single;

      await r.emails.deleteEmail(virtual.id);

      expect(await r.emails.observeEmails('acc-1', 'INBOX').first, isEmpty);
      final trash = await r.emails.observeEmails('acc-1', 'Trash').first;
      expect(trash, hasLength(1));
      expect(await r.db.select(r.db.pendingChanges).get(), isEmpty);
    });
  });

  group('dissolving on real arrival', () {
    test('transfers the star to the real message and removes the virtual row',
        () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      await _seedMailbox(r.db, 'INBOX', 'inbox');
      await r.emails.enqueueSend('acc-1', _draftTo('alice@example.com'));
      final virtual =
          (await r.emails.observeEmails('acc-1', 'INBOX').first).single;
      await r.emails.setFlag(virtual.id, flagged: true);

      final realId = await _insertRealArrival(r.db, virtual.messageId!);
      await r.emails.maybeDissolveLocalMessageForTest(
        'acc-1',
        'INBOX',
        realId,
        virtual.messageId,
      );

      final inbox = await r.emails.observeEmails('acc-1', 'INBOX').first;
      expect(inbox, hasLength(1));
      expect(inbox.single.id, realId);
      expect(inbox.single.isLocal, isFalse);
      expect(inbox.single.isFlagged, isTrue, reason: 'star carried over');

      // The star is now pushed to the server for the real message.
      final changes = await r.db.select(r.db.pendingChanges).get();
      expect(changes.map((c) => c.changeType), contains('flag_flagged'));
    });

    test('moves the real message to the folder the virtual was filed into',
        () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      await _seedMailbox(r.db, 'INBOX', 'inbox');
      await _seedMailbox(r.db, 'Trash', 'trash');
      await r.emails.enqueueSend('acc-1', _draftTo('alice@example.com'));
      final virtual =
          (await r.emails.observeEmails('acc-1', 'INBOX').first).single;
      // User trashes the note before the real mail arrives.
      await r.emails.deleteEmail(virtual.id);

      final realId = await _insertRealArrival(r.db, virtual.messageId!);
      await r.emails.maybeDissolveLocalMessageForTest(
        'acc-1',
        'INBOX',
        realId,
        virtual.messageId,
      );

      expect(await r.emails.observeEmails('acc-1', 'INBOX').first, isEmpty);
      final trash = await r.emails.observeEmails('acc-1', 'Trash').first;
      expect(trash, hasLength(1));
      expect(trash.single.id, realId);

      // The move to Trash is queued for the server too.
      final changes = await r.db.select(r.db.pendingChanges).get();
      expect(changes.map((c) => c.changeType), contains('move'));
    });

    test('leaves the virtual message untouched for the Sent copy', () async {
      final r = _makeRepos();
      await r.accounts.addAccount(_account, 'pw');
      await _seedMailbox(r.db, 'INBOX', 'inbox');
      await _seedMailbox(r.db, 'Sent', 'sent');
      await r.emails.enqueueSend('acc-1', _draftTo('alice@example.com'));
      final virtual =
          (await r.emails.observeEmails('acc-1', 'INBOX').first).single;

      final sentId = await _insertRealArrival(
        r.db,
        virtual.messageId!,
        mailboxPath: 'Sent',
        uid: 7,
      );
      await r.emails.maybeDissolveLocalMessageForTest(
        'acc-1',
        'Sent',
        sentId,
        virtual.messageId,
      );

      // The virtual inbox copy survives; only the inbox arrival dissolves it.
      final inbox = await r.emails.observeEmails('acc-1', 'INBOX').first;
      expect(inbox, hasLength(1));
      final sent = await r.emails.observeEmails('acc-1', 'Sent').first;
      expect(sent, hasLength(1));
    });
  });
}
