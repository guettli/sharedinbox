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
      expect(account.smtpPort, 587);
      expect(account.smtpSsl, isFalse);
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
  });
}
