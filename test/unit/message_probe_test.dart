import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/sync/message_probe.dart';

LocalMessageSnapshot _local({
  String mailboxPath = 'INBOX',
  String? messageId = 'abc@example.com',
  String? subject = 'Hello',
  bool isSeen = false,
  bool isFlagged = false,
  int uid = 42,
  List<EmailAddress> from = const [EmailAddress(email: 'a@example.com')],
  List<EmailAddress> to = const [EmailAddress(email: 'b@example.com')],
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
}
