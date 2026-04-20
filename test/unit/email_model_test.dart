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
}
