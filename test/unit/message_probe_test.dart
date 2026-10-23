import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/sync/message_probe.dart';

import 'fake_imap.dart';

/// Serves one message for `MessageProbeImpl`'s IMAP branch, returning its
/// INTERNALDATE only when the FETCH asked for it, like a real server.
class _ProbeImapClient extends SelectingFakeImapClient {
  @override
  Future<imap.FetchImapResult> uidFetchMessage(
    int messageUid,
    String fetchContentDefinition, {
    Duration? responseTimeout,
  }) async {
    final msg = imap.MimeMessage()
      ..uid = messageUid
      ..flags = <String>[]
      ..envelope = imap.Envelope(
        date: DateTime.utc(2024, 6, 15, 12),
        subject: 'Hello',
      );
    if (fetchContentDefinition.contains('INTERNALDATE')) {
      msg.internalDate = '16-Jun-2024 10:00:00 +0200';
    }
    return imap.FetchImapResult([msg], null);
  }
}

LocalMessageSnapshot _local({
  String mailboxPath = 'INBOX',
  String? messageId = 'abc@example.com',
  String? subject = 'Hello',
  bool isSeen = false,
  bool isFlagged = false,
  int uid = 42,
  List<EmailAddress> from = const [EmailAddress(email: 'a@example.com')],
  List<EmailAddress> to = const [EmailAddress(email: 'b@example.com')],
  List<EmailAddress> replyTo = const [],
  List<EmailAddress> bcc = const [],
  String? references,
  List<EmailAttachment> attachments = const [],
}) =>
    LocalMessageSnapshot(
      mailboxPath: mailboxPath,
      messageId: messageId,
      subject: subject,
      sentAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
      receivedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
      isSeen: isSeen,
      isFlagged: isFlagged,
      hasAttachment: false,
      uid: uid,
      from: from,
      to: to,
      cc: const [],
      replyTo: replyTo,
      bcc: bcc,
      inReplyTo: null,
      references: references,
      listUnsubscribeHeader: null,
      attachments: attachments,
    );

RemoteMessageSnapshot _remote({
  String mailboxPath = 'INBOX',
  String? messageId = 'abc@example.com',
  String? subject = 'Hello',
  bool isSeen = false,
  bool isFlagged = false,
  int? uid = 42,
  List<EmailAddress> from = const [EmailAddress(email: 'a@example.com')],
  List<EmailAddress> to = const [EmailAddress(email: 'b@example.com')],
  List<EmailAddress> replyTo = const [],
  List<EmailAddress> bcc = const [],
  String? references,
  List<EmailAttachment> attachments = const [],
}) =>
    RemoteMessageSnapshot(
      mailboxPath: mailboxPath,
      messageId: messageId,
      subject: subject,
      sentAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
      receivedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
      isSeen: isSeen,
      isFlagged: isFlagged,
      hasAttachment: false,
      uid: uid,
      from: from,
      to: to,
      replyTo: replyTo,
      bcc: bcc,
      references: references,
      attachments: attachments,
    );

void main() {
  group('compareMessage', () {
    test('reports a match when every field agrees', () {
      final result = compareMessage(_local(), _remote());
      expect(result.isMatch, isTrue);
      expect(result.diffs, isEmpty);
    });

    test('normalises <>-wrapped Message-IDs before comparing', () {
      final result = compareMessage(
        _local(),
        _remote(messageId: '<abc@example.com>'),
      );
      expect(
        result.isMatch,
        isTrue,
        reason: 'angle brackets should be stripped before comparing',
      );
    });

    test('flags a subject mismatch', () {
      final result = compareMessage(
        _local(subject: 'Local subject'),
        _remote(subject: 'Remote subject'),
      );
      expect(result.isMatch, isFalse);
      expect(result.diffs, hasLength(1));
      expect(result.diffs.single.field, 'subject');
      expect(result.diffs.single.local, 'Local subject');
      expect(result.diffs.single.remote, 'Remote subject');
    });

    test('flags mismatching flags independently', () {
      final result = compareMessage(
        _local(isFlagged: true),
        _remote(isSeen: true),
      );
      final fields = result.diffs.map((d) => d.field).toSet();
      expect(fields, containsAll({'isSeen', 'isFlagged'}));
    });

    test('canonicalises addresses (case-insensitive, order-insensitive)', () {
      final result = compareMessage(
        _local(
          from: const [
            EmailAddress(email: 'One@example.com'),
            EmailAddress(email: 'two@Example.com'),
          ],
        ),
        _remote(
          from: const [
            EmailAddress(email: 'TWO@example.com'),
            EmailAddress(email: 'one@example.com'),
          ],
        ),
      );
      expect(
        result.isMatch,
        isTrue,
        reason: 'address list order and case should not matter',
      );
    });

    test('flags Reply-To and Bcc mismatches', () {
      const boss = [EmailAddress(email: 'boss@example.com')];
      final same = compareMessage(_local(bcc: boss), _remote(bcc: boss));
      expect(same.isMatch, isTrue);
      final result = compareMessage(
        _local(),
        _remote(replyTo: boss, bcc: boss),
      );
      expect(result.diffs.map((d) => d.field), ['replyTo', 'bcc']);
    });

    test('compares uid only when remote provides one', () {
      final resultWithUid = compareMessage(_local(), _remote(uid: 43));
      expect(resultWithUid.diffs.map((d) => d.field), contains('uid'));
      final resultWithoutUid = compareMessage(_local(), _remote(uid: null));
      expect(
        resultWithoutUid.diffs.map((d) => d.field),
        isNot(contains('uid')),
        reason: 'JMAP snapshots have no uid, so skip that diff',
      );
    });

    test('normalises References header whitespace and angle brackets', () {
      final result = compareMessage(
        _local(references: '<a@x> <b@x>'),
        _remote(references: 'a@x b@x'),
      );
      expect(result.isMatch, isTrue);
    });

    test('flags mailbox-path drift', () {
      final result = compareMessage(_local(), _remote(mailboxPath: 'Archive'));
      expect(result.diffs.map((d) => d.field), contains('mailboxPath'));
    });

    test('flags attachment count mismatch', () {
      final result = compareMessage(
        _local(
          attachments: const [
            EmailAttachment(
              filename: 'a.pdf',
              contentType: 'application/pdf',
              size: 10,
            ),
          ],
        ),
        _remote(),
      );
      expect(result.diffs.map((d) => d.field), contains('attachmentCount'));
    });
  });

  group('MessageProbeImpl IMAP', () {
    test('reports receivedAt from INTERNALDATE, like the sync', () async {
      final probe = MessageProbeImpl(
        imapConnect: (Account _, String __, String ___) async =>
            _ProbeImapClient(),
      );
      final result = await probe.fetch(
        account: const Account(
          id: 'acc-1',
          displayName: 'Alice',
          email: 'alice@example.com',
          imapHost: 'imap.example.com',
          smtpHost: 'smtp.example.com',
        ),
        password: 'pw',
        mailboxPath: 'INBOX',
        emailId: 'acc-1:INBOX:42',
        uid: 42,
      );
      expect(result.error, isNull);
      expect(result.snapshot!.sentAt, DateTime.utc(2024, 6, 15, 12));
      expect(result.snapshot!.receivedAt, DateTime.utc(2024, 6, 16, 8));
    });
  });
}
