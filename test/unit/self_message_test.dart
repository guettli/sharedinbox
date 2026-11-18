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
import 'package:sharedinbox/data/repositories/email_state_writer.dart';

import 'account_repository_impl_test.dart' show MapSecureStorage;
import 'db_test_helper.dart';
import 'fake_imap.dart' show ScriptedSmtpClient;

// Mail-to-self "virtual" message support (#545): a mail addressed to one of the
// user's own accounts appears in the inbox as soon as SMTP accepted it, for
// note-taking, and the real message fills it in place once it arrives via
// sync (SYNC-REDESIGN.md §6): the row keeps its id, and the user's changes,
// parked until then, are sent. Never before acceptance: a rejected or
// discarded send must not leave a phantom inbox message behind.

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

/// [smtpRejects] scripts the SMTP replies: the n-th send attempt is refused
/// with the n-th entry's response lines; once they run out, SMTP accepts. IMAP
/// stays unavailable, so the best-effort Sent-copy APPEND fails quietly after
/// a successful send.
_Repos _makeRepos({
  List<List<String>> smtpRejects = const [],
  DateTime Function() now = DateTime.now,
}) {
  final db = openTestDatabase();
  final accounts = AccountRepositoryImpl(db, MapSecureStorage());
  final pending = List.of(smtpRejects);
  final emails = EmailRepositoryImpl(
    db,
    accounts,
    imapConnect: _noImapConnect,
    smtpConnect: (a, u, p) async => ScriptedSmtpClient(
      rejectWith: pending.isEmpty ? null : pending.removeAt(0),
    ),
    now: now,
  );
  return (db: db, accounts: accounts, emails: emails);
}

/// Repos with the account registered and an INBOX mailbox seeded — the minimum
/// needed for a self-send to land somewhere.
Future<_Repos> _reposWithInbox({
  List<List<String>> smtpRejects = const [],
  DateTime Function() now = DateTime.now,
}) async {
  final r = _makeRepos(smtpRejects: smtpRejects, now: now);
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

/// A note to self with a fixed Message-ID, so a test can pre-seed rows that
/// match it.
EmailDraft _selfDraft(String messageId) =>
    _draftTo('alice@example.com').copyWith(messageId: messageId);

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
/// arrives (sharing [messageId] with the virtual copy) and matches it in
/// place. Returns the real row's id.
Future<String> _arriveAndMatch(
  _Repos r,
  String messageId, {
  String mailboxPath = 'INBOX',
  int uid = 42,
}) async {
  final id = await _storeArrived(r, messageId, mailboxPath, uid);
  await r.emails.matchArrivalForTest(
    'acc-1',
    mailboxPath,
    id,
    messageId,
  );
  return id;
}

/// Inserts the row the sync engine writes for a synced (non-local) message
/// with [messageId] in [mailboxPath], returning its id.
Future<String> _storeArrived(
  _Repos r,
  String messageId,
  String mailboxPath,
  int uid,
) async {
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
          srvUid: Value(uid),
        ),
      );
  return id;
}

/// (type, state) of every queued change.
Future<List<(String, String)>> _pendingChanges(_Repos r) async {
  final changes = await r.db.select(r.db.pendingChanges).get();
  return [for (final c in changes) (c.changeType, c.state)];
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
        smtpRejects: [
          ['550 5.1.2 Mailbox does not exist.'],
        ],
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

    test('a transient failure creates the note only on the later success',
        () async {
      final r = await _reposWithInbox(
        smtpRejects: [
          ['451 4.3.0 Try again later'],
        ],
      );

      expect(
        await _enqueueAndSend(r, _draftTo('alice@example.com')),
        SendNowOutcome.transientFailed,
      );
      expect(await _inbox(r), isEmpty, reason: 'not accepted yet');

      // The backoff elapses and the retry goes through.
      await r.db.update(r.db.outbox).write(
            const OutboxCompanion(nextAttemptAt: Value(null)),
          );
      final rowId = (await r.db.select(r.db.outbox).get()).single.id;
      expect(
        (await r.emails.sendNow('acc-1', outboxRowId: rowId)).outcome,
        SendNowOutcome.sent,
      );

      final inbox = await _inbox(r);
      expect(inbox, hasLength(1));
      expect(inbox.single.isLocal, isTrue);
    });

    test('a repeated send keeps the user edits on the note', () async {
      final r = await _reposWithInbox();
      final draft = _selfDraft('<twice-1@example.com>');
      await _enqueueAndSend(r, draft);
      final note = (await _inbox(r)).single;
      await r.emails.setFlag(note.id, flagged: true);

      await _enqueueAndSend(r, draft);

      final inbox = await _inbox(r);
      expect(inbox, hasLength(1));
      expect(inbox.single.isFlagged, isTrue, reason: 'star must survive');
    });

    test('no virtual message when the real one already arrived', () async {
      final r = await _reposWithInbox();
      // A sync stored the delivered message before the sender got to add the
      // note — filed by a server rule into a custom folder, not INBOX; a note
      // now would never dissolve and stay a duplicate.
      await _seedMailbox(r.db, 'Notes', 'custom');
      await _storeArrived(r, 'fast-1@example.com', 'Notes', 42);

      expect(
        await _enqueueAndSend(r, _selfDraft('<fast-1@example.com>')),
        SendNowOutcome.sent,
      );

      expect(await _inbox(r), isEmpty);
    });

    test('the Sent copy alone does not count as arrived', () async {
      final r = await _reposWithInbox();
      await _seedMailbox(r.db, 'Sent', 'sent');
      await _storeArrived(r, 'sent-1@example.com', 'Sent', 7);
      // Also a copy in a folder not synced yet (e.g. a just-created "Sent"
      // fallback): unknown, so it cannot be the delivered message either.
      await _storeArrived(r, 'sent-1@example.com', 'Sent Items', 8);
      final draft = _selfDraft('<sent-1@example.com>');

      await _enqueueAndSend(r, draft);

      expect((await _inbox(r)).single.isLocal, isTrue);
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
    test('starring a virtual message parks the change', () async {
      final r = await _reposWithInbox();
      final virtual = await _enqueueSelfNote(r);

      await r.emails.setFlag(virtual.id, flagged: true);

      expect((await _inbox(r)).single.isFlagged, isTrue);
      // Folded, but not sent: there is no server copy to change yet.
      expect(await _pendingChanges(r), [('flag_flagged', 'parked')]);
      expect(await EmailStateWriter(r.db).consistencyProblems(), isEmpty);
    });

    test('trashing a virtual message parks the move', () async {
      final r = await _reposWithTrash();

      final virtual = await _enqueueAndTrashSelfNote(r);

      final trash = await _expectMovedToTrash(r);
      expect(trash.single.id, virtual.id);
      expect(await _pendingChanges(r), [('move', 'parked')]);
    });

    test('Undo of a parked move cancels it', () async {
      final r = await _reposWithTrash();
      final virtual = await _enqueueSelfNote(r);

      final (_, ops) = await r.emails.captureOps(
        () => r.emails.moveEmail(virtual.id, 'Trash'),
      );
      await r.emails.cancelOps(ops[virtual.id]!);

      expect((await _inbox(r)).single.id, virtual.id);
      expect(await _pendingChanges(r), isEmpty);
    });
  });

  group('matching the server copy in place', () {
    test('the real message fills the virtual row, which keeps id and star',
        () async {
      final r = await _reposWithInbox();
      final virtual = await _enqueueSelfNote(r);
      await r.emails.setFlag(virtual.id, flagged: true);

      final realId = await _arriveAndMatch(r, virtual.messageId!);

      final inbox = await _inbox(r);
      expect(inbox, hasLength(1));
      expect(inbox.single.id, virtual.id, reason: 'matched in place');
      expect(inbox.single.isLocal, isFalse);
      expect(inbox.single.isFlagged, isTrue, reason: 'the parked star folds');
      expect(
        await (r.db.select(r.db.emails)..where((t) => t.id.equals(realId)))
            .getSingleOrNull(),
        isNull,
        reason: 'the stored copy was merged into the virtual row',
      );

      // The parked star is sent now, for the server copy.
      final change = (await r.db.select(r.db.pendingChanges).get()).single;
      expect(change.changeType, 'flag_flagged');
      expect(change.state, 'pending');
      final payload = jsonDecode(change.payload) as Map<String, dynamic>;
      expect(payload['uid'], 42);
      expect(payload['mailboxPath'], 'INBOX');
      expect(await EmailStateWriter(r.db).consistencyProblems(), isEmpty);
    });

    test(
        'a virtual row filed into Trash keeps showing there; the move is '
        'sent from where the server has the mail', () async {
      final r = await _reposWithTrash();
      // User trashes the note before the real mail arrives.
      final virtual = await _enqueueAndTrashSelfNote(r);

      await _arriveAndMatch(r, virtual.messageId!);

      final trash = await _expectMovedToTrash(r);
      expect(trash.single.id, virtual.id);
      final change = (await r.db.select(r.db.pendingChanges).get()).single;
      expect(change.changeType, 'move');
      expect(change.state, 'pending');
      final payload = jsonDecode(change.payload) as Map<String, dynamic>;
      expect(payload['uid'], 42);
      expect(payload['mailboxPath'], 'INBOX');
      expect(payload['dest'], 'Trash');
      expect(await EmailStateWriter(r.db).consistencyProblems(), isEmpty);
    });

    test('leaves the virtual message untouched for the Sent copy', () async {
      final r = await _reposWithInbox();
      await _seedMailbox(r.db, 'Sent', 'sent');
      final virtual = await _enqueueSelfNote(r);

      await _arriveAndMatch(
        r,
        virtual.messageId!,
        mailboxPath: 'Sent',
        uid: 7,
      );

      // The virtual inbox copy survives; only the inbox arrival matches it.
      expect((await _inbox(r)).single.isLocal, isTrue);
      expect(await r.emails.observeEmails('acc-1', 'Sent').first, hasLength(1));
    });
  });

  group('a note deleted for good before its delivery', () {
    Future<Email> deleteNoteForGood(_Repos r) async {
      // No Trash folder: the delete is for good, parked, the note hidden.
      final virtual = await _enqueueSelfNote(r);
      await r.emails.deleteEmail(virtual.id);
      expect(await _inbox(r), isEmpty);
      expect(await _pendingChanges(r), [('delete', 'parked')]);
      return virtual;
    }

    test('is sent when the mail arrives in the inbox', () async {
      final r = await _reposWithInbox();
      final virtual = await deleteNoteForGood(r);

      await _arriveAndMatch(r, virtual.messageId!);

      expect(await _pendingChanges(r), [('delete', 'pending')]);
      expect(await _inbox(r), isEmpty);
    });

    test('fails when a server filter filed the mail elsewhere', () async {
      final r = await _reposWithInbox();
      await _seedMailbox(r.db, 'Junk', 'junk');
      final virtual = await deleteNoteForGood(r);

      await _arriveAndMatch(r, virtual.messageId!, mailboxPath: 'Junk');

      // Not deleted for good: the mail shows where it is, and the delete
      // is listed as failed.
      final change = (await r.db.select(r.db.pendingChanges).get()).single;
      expect(change.state, 'failed');
      expect(change.lastError, contains('not deleted for good'));
      final junk = await r.emails.observeEmails('acc-1', 'Junk').first;
      expect(junk.single.id, virtual.id);
      expect(await EmailStateWriter(r.db).consistencyProblems(), isEmpty);
    });
  });

  test('a second copy with the same Message-ID does not match the row again',
      () async {
    final r = await _reposWithInbox();
    final virtual = await _enqueueSelfNote(r);
    await r.emails.setFlag(virtual.id, flagged: true);
    await _arriveAndMatch(r, virtual.messageId!);

    final second = await _arriveAndMatch(r, virtual.messageId!, uid: 43);

    expect(
      await (r.db.select(r.db.emails)..where((t) => t.id.equals(second)))
          .getSingleOrNull(),
      isNotNull,
      reason: 'the row no longer waits: the second copy stays a row',
    );
    final change = (await r.db.select(r.db.pendingChanges).get()).single;
    expect((jsonDecode(change.payload) as Map)['uid'], 42);
  });

  group('expiry', () {
    test(
        'a virtual row unmatched after 7 days is dropped; its parked change '
        'fails and stays listed', () async {
      var now = DateTime.now();
      final r = await _reposWithInbox(now: () => now);
      final virtual = await _enqueueSelfNote(r);
      await r.emails.setFlag(virtual.id, flagged: true);
      // Runs after each successful inbox sync (never before it).
      Future<void> expireAfterInboxSync() =>
          EmailStateWriter(r.db, now: () => now)
              .expireParked('acc-1', folder: 'INBOX', role: 'inbox');

      // Not yet.
      now = now.add(const Duration(days: 6));
      await expireAfterInboxSync();
      expect((await _inbox(r)).single.id, virtual.id);

      now = now.add(const Duration(days: 2));
      await expireAfterInboxSync();
      expect(await _inbox(r), isEmpty);
      final change = (await r.db.select(r.db.pendingChanges).get()).single;
      expect(change.state, 'failed');
      expect(change.lastError, contains('never arrived'));
    });
  });
}
