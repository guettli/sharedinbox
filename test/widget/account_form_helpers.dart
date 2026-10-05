// Shared steps for the add- and edit-account screen widget tests.

import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

/// Taps Save and asserts the single stored account is the remote
/// `imap.example.com` host with both SSL switches off (i.e. STARTTLS).
Future<void> saveAndExpectRemoteStartTls(
  WidgetTester tester,
  FakeAccountRepository repo,
) async {
  await tester.tap(find.text('Save'));
  await tester.pumpAndSettle();

  final saved = repo.accounts.single;
  expect(saved.imapHost, 'imap.example.com');
  expect(saved.imapSsl, isFalse);
  expect(saved.smtpSsl, isFalse);
}
