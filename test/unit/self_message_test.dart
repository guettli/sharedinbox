import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart'
    show SendNowOutcome;
import 'package:sharedinbox/data/db/database.dart' hide Account, Email;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';

import 'account_repository_impl_test.dart' show MapSecureStorage;
import 'db_test_helper.dart';
import 'fake_imap.dart' show ScriptedSmtpClient;

// Mail-to-self "virtual" message support (#545): a mail addressed to one of the
// user's own accounts appears in the inbox as soon as SMTP accepted it, for
// note-taking, and is dissolved into the real message once it arrives via
// sync. Never before acceptance: a rejected or discarded send must not leave a
// phantom inbox message behind.

typedef _Repos = ({
  AppDatabase db,
  AccountRepositoryImpl accounts,
  EmailRepositoryImpl emails,
});

const _account = Account(
  id: 'acc-1',
  displayName: 'Alice',
  email: 'alice@example.com',
  imapHost: 'imap.example.com',
  smtpHost: 'smtp.example.com',
);

Future<imap.ImapClient> _noImapConnect(Account a, String u, String p) =>
    Future.error(UnsupportedError('IMAP unavailable in unit tests'));

/// [smtpRejectWith], when set, makes SMTP refuse every message with those
/// response lines; otherwise SMTP accepts. IMAP stays unavailable, so the
/// best-effort Sent-copy APPEND fails quietly after a successful send.
_Repos _makeRepos({List<String>? smtpRejectWith}) {
  final db = openTestDatabase();
  final accounts = AccountRepositoryImpl(db, MapSecureStorage());
  final emails = EmailRepositoryImpl(
    db,
    accounts,
    imapConnect: _noImapConnect,
    smtpConnect: (a, u, p) async =>
        ScriptedSmtpClient(rejectWith: smtpRejectWith),
  );
  return (db: db, accounts: accounts, emails: emails);
}

/// Repos with the account registered and an INBOX mailbox seeded — the minimum
/// needed for a self-send to land somewhere.
Future<_Repos> _reposWithInbox({List<String>? smtpRejectWith}) async {
  final r = _makeRepos(smtpRejectWith: smtpRejectWith);
  await r.accounts.addAccount(_account, 'pw');
  await _seedMailbox(r.db, 'INBOX', 'inbox');
  return r;
}

/// Repos with INBOX and a Trash mailbox — the setup for trash-related tests.
Future<_Repos> _reposWithTrash() async {
  final r = await _reposWithInbox();
  await _seedMailbox(r.db, 'Trash', 'trash');
  return r;
}

Future<void> _seedMailbox(AppDatabase db, String path, String role) =>
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

Future<List<Email>> _inbox(_Repos r) =>
    r.emails.observeEmails('acc-1', 'INBOX').first;

/// Queues [draft] and sends it right away, returning the send outcome.
Future<SendNowOutcome> _enqueueAndSend(_Repos r, EmailDraft draft) async {
  final rowId = await r.emails.enqueueSend('acc-1', draft);
  return (await r.emails.sendNow('acc-1', outboxRowId: rowId)).outcome;
}

/// Sends a note to self and returns the virtual inbox copy it creates.
Future<Email> _enqueueSelfNote(_Repos r) async {
  await _enqueueAndSend(r, _draftTo('alice@example.com'));
  return (await _inbox(r)).single;
}

/// Sends a note to self and trashes the virtual copy, returning it.
Future<Email> _enqueueAndTrashSelfNote(_Repos r) async {
  final virtual = await _enqueueSelfNote(r);
  await r.emails.deleteEmail(virtual.id);
  return virtual;
}

/// Asserts the inbox is now empty and the message lives in Trash instead,
/// returning the Trash contents.
Future<List<Email>> _expectMovedToTrash(_Repos r) async {
  expect(await _inbox(r), isEmpty);
  final trash = await r.emails.observeEmails('acc-1', 'Trash').first;
  expect(trash, hasLength(1));
  return trash;
}

/// Inserts a row mimicking what the sync engine writes when the real message
/// arrives (sharing [messageId] with the virtual copy) and dissolves it.
/// Returns the real row's id.
Future<String> _arriveAndDissolve(
  _Repos r,
  String messageId, {
  String mailboxPath = 'INBOX',
  int uid = 42,
}) async {
  final id = 'acc-1:$mailboxPath:$uid';
  await r.db.into(r.db.emails).insert(
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
  await r.emails.maybeDissolveLocalMessageForTest(
    'acc-1',
    mailboxPath,
    id,
    messageId,
  );
  return id;
}

Future<List<String>> _pendingChangeTypes(_Repos r) async {
  final changes = await r.db.select(r.db.pendingChanges).get();
  return changes.map((c) => c.changeType).toList();
}

void main() {
  setUpAll(configureSqliteForTests);

  group('self-detection', () {
    test('creates a virtual inbox message for a mail to self once sent',
        () async {
      final r = await _reposWithInbox();

      await r.emails.enqueueSend('acc-1', _draftTo('alice@example.com'));

      // Still queued: SMTP has not accepted it, so nothing is in the inbox.
      expect(await _inbox(r), isEmpty);
      final outbox = await r.db.select(r.db.outbox).get();
      expect(outbox, hasLength(1));

      expect(
        (await r.emails.sendNow('acc-1', outboxRowId: outbox.single.id))
            .outcome,
        SendNowOutcome.sent,
      );

      final inbox = await _inbox(r);
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

      // The queued MIME carried the same deterministic Message-ID so the real
      // message can be matched on arrival.
      final mime = utf8.decode(base64.decode(outbox.single.mimeBase64));
      expect(mime, contains(virtual.messageId!));
      expect(await r.db.select(r.db.outbox).get(), isEmpty);
    });

    test('a send rejected by SMTP leaves no phantom message in the inbox',
        () async {
      // To: self plus an address the server does not know, so the whole
      // message is refused with a 5xx and nothing is delivered to anyone.
      final r = await _reposWithInbox(
        smtpRejectWith: ['550 5.1.2 Mailbox does not exist.'],
      );
      const draft = EmailDraft(
        from: EmailAddress(email: 'alice@example.com'),
        to: [
          EmailAddress(email: 'alice@example.com'),
          EmailAddress(email: 'carol@example.com'),
        ],
        cc: [],
        subject: 'multi rcpt',
        body: 'hello all',
      );

      expect(
        await _enqueueAndSend(r, draft),
        SendNowOutcome.permanentlyFailed,
      );
      expect(await _inbox(r), isEmpty);
      // Nowhere else either, so discarding the failed row from the Sent Queue
      // leaves no orphan behind.
      expect(await r.db.select(r.db.emails).get(), isEmpty);
      expect((await r.db.select(r.db.outbox).get()).single.status, 'failed');
    });

    test('no virtual message when the real one already arrived', () async {
      final r = await _reposWithInbox();
      const draft = EmailDraft(
        from: EmailAddress(email: 'alice@example.com'),
        to: [EmailAddress(email: 'alice@example.com')],
        cc: [],
        subject: 'note',
        body: 'remember milk',
        messageId: '<fast-1@example.com>',
      );
      // A sync stored the delivered message before the sender got to add the
      // note; a note now would never dissolve and stay a duplicate.
      await r.db.into(r.db.emails).insert(
            EmailsCompanion.insert(
              id: 'acc-1:INBOX:42',
              accountId: 'acc-1',
              mailboxPath: 'INBOX',
              uid: 42,
              receivedAt: DateTime(2024, 6),
              subject: const Value('note'),
              messageId: const Value('fast-1@example.com'),
            ),
          );

      expect(await _enqueueAndSend(r, draft), SendNowOutcome.sent);

      final inbox = await _inbox(r);
      expect(inbox, hasLength(1));
      expect(inbox.single.isLocal, isFalse);
    });

    test('does not create a virtual message for a mail to someone else',
        () async {
      final r = await _reposWithInbox();

      await _enqueueAndSend(r, _draftTo('bob@other.example'));

      expect(await _inbox(r), isEmpty);
    });

    test('address match is case-insensitive', () async {
      final r = await _reposWithInbox();

      await _enqueueAndSend(r, _draftTo('Alice@Example.com'));

      expect(await _inbox(r), hasLength(1));
    });
  });

  group('mutations on the virtual message', () {
    test('starring a virtual message does not queue a server change', () async {
      final r = await _reposWithInbox();
      final virtual = await _enqueueSelfNote(r);

      await r.emails.setFlag(virtual.id, flagged: true);

      expect((await _inbox(r)).single.isFlagged, isTrue);
      expect(await _pendingChangeTypes(r), isEmpty);
    });

    test('trashing a virtual message does not queue a server change', () async {
      final r = await _reposWithTrash();

      await _enqueueAndTrashSelfNote(r);

      await _expectMovedToTrash(r);
      expect(await _pendingChangeTypes(r), isEmpty);
    });
  });

  group('dissolving on real arrival', () {
    test('transfers the star to the real message and removes the virtual row',
        () async {
      final r = await _reposWithInbox();
      final virtual = await _enqueueSelfNote(r);
      await r.emails.setFlag(virtual.id, flagged: true);

      final realId = await _arriveAndDissolve(r, virtual.messageId!);

      final inbox = await _inbox(r);
      expect(inbox, hasLength(1));
      expect(inbox.single.id, realId);
      expect(inbox.single.isLocal, isFalse);
      expect(inbox.single.isFlagged, isTrue, reason: 'star carried over');

      // The star is now pushed to the server for the real message.
      expect(await _pendingChangeTypes(r), contains('flag_flagged'));
    });

    test('moves the real message to the folder the virtual was filed into',
        () async {
      final r = await _reposWithTrash();
      // User trashes the note before the real mail arrives.
      final virtual = await _enqueueAndTrashSelfNote(r);

      final realId = await _arriveAndDissolve(r, virtual.messageId!);

      final trash = await _expectMovedToTrash(r);
      expect(trash.single.id, realId);

      // The move to Trash is queued for the server too.
      expect(await _pendingChangeTypes(r), contains('move'));
    });

    test('leaves the virtual message untouched for the Sent copy', () async {
      final r = await _reposWithInbox();
      await _seedMailbox(r.db, 'Sent', 'sent');
      final virtual = await _enqueueSelfNote(r);

      await _arriveAndDissolve(
        r,
        virtual.messageId!,
        mailboxPath: 'Sent',
        uid: 7,
      );

      // The virtual inbox copy survives; only the inbox arrival dissolves it.
      expect(await _inbox(r), hasLength(1));
      expect(await r.emails.observeEmails('acc-1', 'Sent').first, hasLength(1));
    });
  });
}
