import 'package:sharedinbox/core/models/account.dart';

/// A plain IMAP account (`acc-1`) for unit tests that only need some account.
const testImapAccount = Account(
  id: 'acc-1',
  displayName: 'Alice',
  email: 'alice@example.com',
  imapHost: 'imap.example.com',
  smtpHost: 'smtp.example.com',
);
