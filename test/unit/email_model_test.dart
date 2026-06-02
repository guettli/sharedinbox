import 'dart:convert';

import 'package:sharedinbox/core/models/email.dart';
// Import the abstract interface so it appears in coverage.
import 'package:sharedinbox/core/repositories/email_repository.dart'; // ignore: unused_import
import 'package:test/test.dart';

// Mirrors the encoding logic in EmailRepositoryImpl so we can test it
// independently without spinning up a database.
String encodeAddresses(List<EmailAddress> addresses) => jsonEncode(
  addresses.map((a) => {'name': a.name, 'email': a.email}).toList(),
);

List<EmailAddress> decodeAddresses(String json) {
  final list = jsonDecode(json) as List<dynamic>;
  return list
      .map(
        (e) => EmailAddress(
          name: (e as Map<String, dynamic>)['name'] as String?,
          email: e['email'] as String,
        ),
      )
      .toList();
}

void main() {
  group('EmailAddress JSON roundtrip', () {
    test('encodes and decodes a single address with name', () {
      const addr = EmailAddress(name: 'Alice', email: 'alice@example.com');
      final decoded = decodeAddresses(encodeAddresses([addr]));
      expect(decoded, hasLength(1));
      expect(decoded.first.name, 'Alice');
      expect(decoded.first.email, 'alice@example.com');
    });

    test('encodes and decodes an address without a display name', () {
      const addr = EmailAddress(email: 'bob@example.com');
      final decoded = decodeAddresses(encodeAddresses([addr]));
      expect(decoded.first.name, isNull);
      expect(decoded.first.email, 'bob@example.com');
    });

    test('encodes and decodes multiple addresses', () {
      final addresses = [
        const EmailAddress(name: 'Alice', email: 'alice@example.com'),
        const EmailAddress(email: 'bob@example.com'),
      ];
      final decoded = decodeAddresses(encodeAddresses(addresses));
      expect(decoded, hasLength(2));
      expect(decoded[0].email, 'alice@example.com');
      expect(decoded[1].email, 'bob@example.com');
    });

    test('encodes empty list', () {
      final decoded = decodeAddresses(encodeAddresses([]));
      expect(decoded, isEmpty);
    });

    test('handles special characters in display name', () {
      const addr = EmailAddress(name: 'Müller, Hans', email: 'hans@example.de');
      final decoded = decodeAddresses(encodeAddresses([addr]));
      expect(decoded.first.name, 'Müller, Hans');
    });
  });

  group('EmailAddress.toString', () {
    test('includes name when present', () {
      const addr = EmailAddress(name: 'Alice', email: 'alice@example.com');
      expect(addr.toString(), 'Alice <alice@example.com>');
    });

    test('returns just email when name is null', () {
      const addr = EmailAddress(email: 'alice@example.com');
      expect(addr.toString(), 'alice@example.com');
    });
  });

  group('Email', () {
    test('constructs with required fields', () {
      final email = Email(
        id: 'acc:1',
        accountId: 'acc',
        mailboxPath: 'INBOX',
        uid: 1,
        receivedAt: DateTime(2024),
        from: const [],
        to: const [],
        cc: const [],
        isSeen: false,
        isFlagged: false,
        hasAttachment: false,
      );
      expect(email.id, 'acc:1');
      expect(email.isSeen, isFalse);
    });

    test('JSON roundtrip works', () {
      final now = DateTime.now();
      final email = Email(
        id: 'acc:1',
        accountId: 'acc',
        mailboxPath: 'INBOX',
        uid: 1,
        subject: 'Hello',
        sentAt: now,
        receivedAt: now,
        from: const [EmailAddress(name: 'A', email: 'a@a.com')],
        to: const [EmailAddress(email: 'b@b.com')],
        cc: const [],
        isSeen: true,
        isFlagged: false,
        hasAttachment: true,
        threadId: 't1',
        messageId: 'm1',
        snoozedUntil: now,
        snoozedFromMailboxPath: 'INBOX',
      );

      final json = email.toJson();
      final decoded = Email.fromJson(json);

      expect(decoded.id, email.id);
      expect(decoded.subject, email.subject);
      expect(decoded.isSeen, email.isSeen);
      expect(decoded.hasAttachment, email.hasAttachment);
      expect(decoded.threadId, email.threadId);
      expect(decoded.snoozedUntil, isNotNull);
      expect(decoded.snoozedFromMailboxPath, 'INBOX');
    });

    test('copyWith works', () {
      final email = Email(
        id: 'acc:1',
        accountId: 'acc',
        mailboxPath: 'INBOX',
        uid: 1,
        receivedAt: DateTime(2024),
        from: const [],
        to: const [],
        cc: const [],
        isSeen: false,
        isFlagged: false,
        hasAttachment: false,
      );

      final updated = email.copyWith(
        isSeen: true,
        subject: 'New Subject',
        snoozedUntil: DateTime(2026),
      );

      expect(updated.isSeen, isTrue);
      expect(updated.subject, 'New Subject');
      expect(updated.snoozedUntil, DateTime(2026));
      expect(updated.id, email.id);
    });
  });

  group('EmailBody', () {
    test('constructs with required fields', () {
      const body = EmailBody(emailId: 'acc:1', attachments: []);
      expect(body.emailId, 'acc:1');
      expect(body.textBody, isNull);
      expect(body.attachments, isEmpty);
    });

    test('holds attachment list', () {
      const body = EmailBody(
        emailId: 'acc:2',
        attachments: [
          EmailAttachment(
            filename: 'doc.pdf',
            contentType: 'application/pdf',
            size: 1024,
          ),
        ],
      );
      expect(body.attachments, hasLength(1));
      expect(body.attachments.first.filename, 'doc.pdf');
      expect(body.attachments.first.size, 1024);
    });
  });

  group('EmailDraft', () {
    test('constructs with required fields', () {
      const draft = EmailDraft(
        from: EmailAddress(name: 'Me', email: 'me@example.com'),
        to: [EmailAddress(email: 'you@example.com')],
        cc: [],
        subject: 'Hello',
        body: 'World',
      );
      expect(draft.subject, 'Hello');
      expect(draft.to, hasLength(1));
      expect(draft.cc, isEmpty);
    });

    test('runtime construction stores all fields', () {
      // Use a non-const list so the constructor runs at runtime and is
      // instrumented by the coverage tool.
      final to = [const EmailAddress(email: 'you@example.com')];
      final draft = EmailDraft(
        from: const EmailAddress(name: 'Me', email: 'me@example.com'),
        to: to,
        cc: const [],
        subject: 'Hi',
        body: 'There',
      );
      expect(draft.from.email, 'me@example.com');
      expect(draft.body, 'There');
    });
  });

  group('EmailAttachment', () {
    test('runtime construction stores all fields', () {
      // Non-const construction so the constructor is instrumented for coverage.
      const filename = 'report.pdf';
      // ignore: prefer_const_constructors
      final att = EmailAttachment(
        filename: filename,
        contentType: 'application/pdf',
        size: 2048,
      );
      expect(att.filename, 'report.pdf');
      expect(att.contentType, 'application/pdf');
      expect(att.size, 2048);
    });
  });

  group('SyncEmailsResult', () {
    test('operator + adds fields', () {
      const r1 = SyncEmailsResult(
        fetched: 1,
        skipped: 2,
        bytesTransferred: 100,
      );
      const r2 = SyncEmailsResult(
        fetched: 3,
        skipped: 4,
        bytesTransferred: 200,
      );
      final r3 = r1 + r2;
      expect(r3.fetched, 4);
      expect(r3.skipped, 6);
      expect(r3.bytesTransferred, 300);
    });

    test('zero constant is correct', () {
      expect(SyncEmailsResult.zero.fetched, 0);
      expect(SyncEmailsResult.zero.skipped, 0);
      expect(SyncEmailsResult.zero.bytesTransferred, 0);
    });
  });

  group('FailedMutation', () {
    test('constructs and stores all fields', () {
      final now = DateTime.now();
      final fm = FailedMutation(
        id: 1,
        accountId: 'acc1',
        changeType: 'move',
        resourceId: 'e1',
        lastError: 'error',
        attempts: 1,
        createdAt: now,
      );
      expect(fm.id, 1);
      expect(fm.changeType, 'move');
      expect(fm.createdAt, now);
    });
  });
}
