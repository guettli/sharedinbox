// E2E integration tests — requires a running Stalwart instance and a display.
// Run via: stalwart-dev/integration_ui_test.sh
//
// Environment variables (set by the runner script):
//   STALWART_IMAP_HOST, STALWART_IMAP_PORT
//   STALWART_SMTP_HOST, STALWART_SMTP_PORT
//   STALWART_USER_B / STALWART_PASS_B  (alice@localhost)

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:sharedinbox/core/storage/secure_storage.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/main.dart' as app;

/// In-memory drop-in for SecureStorage — no D-Bus or keyring daemon required.
class _InMemorySecureStorage implements SecureStorage {
  final _store = <String, String>{};

  @override
  Future<void> write({required String key, required String? value}) async {
    if (value == null) {
      _store.remove(key);
    } else {
      _store[key] = value;
    }
  }

  @override
  Future<String?> read({required String key}) async => _store[key];

  @override
  Future<void> delete({required String key}) async => _store.remove(key);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late String imapHost;
  late int imapPort;
  late String smtpHost;
  late int smtpPort;
  late String userEmail;
  late String userPass;

  setUpAll(() {
    imapHost = Platform.environment['STALWART_IMAP_HOST'] ?? '127.0.0.1';
    imapPort = int.parse(Platform.environment['STALWART_IMAP_PORT'] ?? '1430');
    smtpHost = Platform.environment['STALWART_SMTP_HOST'] ?? '127.0.0.1';
    smtpPort = int.parse(Platform.environment['STALWART_SMTP_PORT'] ?? '1025');
    userEmail = Platform.environment['STALWART_USER_B'] ?? 'alice@localhost';
    userPass = Platform.environment['STALWART_PASS_B'] ?? 'secret';
  });

  testWidgets(
    'E2E: add account, send mail to self, verify sent/inbox, search',
    (tester) async {
      // The Flutter Linux test runner defaults to a 1×1 window; give it a
      // real size so widgets are laid out and hittable.
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      app.main(overrides: [
        secureStorageProvider.overrideWithValue(_InMemorySecureStorage()),
      ]);
      await tester.pumpAndSettle();

      // ── Add account ────────────────────────────────────────────────────────
      expect(find.text('No accounts yet.'), findsOneWidget);

      await tester.tap(find.widgetWithIcon(FloatingActionButton, Icons.add));
      await tester.pumpAndSettle();

      expect(find.text('Add account'), findsOneWidget);

      await tester.enterText(
          find.widgetWithText(TextFormField, 'Display name'), 'Alice');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Email address'), userEmail);
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Password'), userPass);
      await tester.enterText(
          find.widgetWithText(TextFormField, 'IMAP host'), imapHost);

      // The form has two "Port" fields: index 0 = IMAP, index 1 = SMTP.
      final imapPortField =
          find.widgetWithText(TextFormField, 'Port').at(0);
      await tester.ensureVisible(imapPortField);
      await tester.enterText(imapPortField, imapPort.toString());

      // IMAP SSL defaults to on — turn it off for the plaintext dev server.
      final imapSslSwitch =
          find.widgetWithText(SwitchListTile, 'SSL/TLS').at(0);
      await tester.ensureVisible(imapSslSwitch);
      await tester.tap(imapSslSwitch);
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextFormField, 'SMTP host'), smtpHost);

      final smtpPortField =
          find.widgetWithText(TextFormField, 'Port').at(1);
      await tester.ensureVisible(smtpPortField);
      await tester.enterText(smtpPortField, smtpPort.toString());

      final saveButton = find.widgetWithText(FilledButton, 'Save');
      await tester.ensureVisible(saveButton);
      await tester.tap(saveButton);
      await tester.pumpAndSettle();

      // Back at account list.
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text(userEmail), findsOneWidget);

      // ── Navigate to mailboxes ──────────────────────────────────────────────
      await tester.tap(find.text('Alice'));
      // Give the background sync time to populate mailboxes from IMAP.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      expect(find.text('INBOX'), findsOneWidget);

      // ── Compose and send email to self ─────────────────────────────────────
      await tester.tap(find.text('INBOX'));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.edit));
      await tester.pumpAndSettle();

      final subject = 'E2E-${DateTime.now().millisecondsSinceEpoch}';

      await tester.enterText(
          find.widgetWithText(TextFormField, 'To'), userEmail);
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Subject'), subject);

      final bodyField = find.widgetWithText(TextFormField, 'Body');
      await tester.ensureVisible(bodyField);
      await tester.enterText(bodyField, 'Hello from integration test!');

      await tester.tap(find.byIcon(Icons.send));
      // Wait for SMTP send + IMAP APPEND to complete.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      // ComposeScreen pops back to EmailListScreen (INBOX) after send.

      // ── Check Sent folder ──────────────────────────────────────────────────
      // Go back to MailboxListScreen.
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sent'));
      await tester.pumpAndSettle();

      // Sync Sent folder to fetch the appended message.
      await tester.tap(find.byIcon(Icons.sync));
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      expect(find.text(subject), findsOneWidget);

      // ── Check Inbox ────────────────────────────────────────────────────────
      await tester.pageBack(); // Sent EmailList → MailboxList
      await tester.pumpAndSettle();

      await tester.tap(find.text('INBOX'));
      await tester.pumpAndSettle();

      // Sync INBOX — Stalwart delivers to self near-instantly.
      await tester.tap(find.byIcon(Icons.sync));
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      expect(find.text(subject), findsOneWidget);

      // ── Search ─────────────────────────────────────────────────────────────
      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();

      // Search by the 'E2E-' prefix — should match the message we just sent.
      await tester.enterText(find.byType(TextField), 'E2E-');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      expect(find.text(subject), findsOneWidget);
    },
  );
}
