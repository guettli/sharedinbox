import 'package:sharedinbox/core/models/account.dart';
// Import the abstract interface so it appears in coverage.
import 'package:sharedinbox/core/repositories/account_repository.dart'; // ignore: unused_import
import 'package:test/test.dart';

void main() {
  group('Account', () {
    const account = Account(
      id: 'a1',
      displayName: 'Work',
      email: 'me@example.com',
      imapHost: 'imap.example.com',
      smtpHost: 'smtp.example.com',
    );

    test('stores all fields', () {
      expect(account.id, 'a1');
      expect(account.displayName, 'Work');
      expect(account.email, 'me@example.com');
      expect(account.imapHost, 'imap.example.com');
      expect(account.imapPort, 993);
      expect(account.imapSsl, isTrue);
      expect(account.smtpHost, 'smtp.example.com');
      expect(account.smtpPort, 465);
      expect(account.smtpSsl, isTrue);
    });

    test('const constructor produces equal instances', () {
      const same = Account(
        id: 'a1',
        displayName: 'Work',
        email: 'me@example.com',
        imapHost: 'imap.example.com',
        smtpHost: 'smtp.example.com',
      );
      expect(identical(account, same), isTrue);
    });

    test('signature defaults to empty', () {
      expect(account.signature, '');
    });

    test('copyWith works', () {
      final updated = account.copyWith(
        displayName: 'Personal',
        imapPort: 143,
        type: AccountType.jmap,
        manageSieveAvailable: true,
        signature: 'Cheers,\nAlex',
      );
      expect(updated.displayName, 'Personal');
      expect(updated.imapPort, 143);
      expect(updated.type, AccountType.jmap);
      expect(updated.manageSieveAvailable, isTrue);
      expect(updated.signature, 'Cheers,\nAlex');
      expect(updated.id, account.id);
    });

    test('JSON roundtrip works', () {
      final json =
          account.copyWith(signature: 'Sent from SharedInbox').toJson();
      final decoded = Account.fromJson(json);
      expect(decoded.id, account.id);
      expect(decoded.email, account.email);
      expect(decoded.type, account.type);
      expect(decoded.signature, 'Sent from SharedInbox');
    });

    test('fromJson defaults signature to empty when absent', () {
      final decoded = Account.fromJson({
        'id': 'a1',
        'displayName': 'Work',
        'email': 'me@example.com',
      });
      expect(decoded.signature, '');
    });
  });
}
