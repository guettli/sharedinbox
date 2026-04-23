// E2E integration tests — requires a running Stalwart instance and a display.
// Run via: stalwart-dev/integration_ui_test.sh
//
// Environment variables (set by the runner script):
//   STALWART_IMAP_HOST, STALWART_IMAP_PORT
//   STALWART_SMTP_HOST, STALWART_SMTP_PORT
//   STALWART_USER_B / STALWART_PASS_B  (alice@example.com)

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

final _sw = Stopwatch()..start();
void _log(String label) => debugPrint('[${_sw.elapsedMilliseconds}ms] $label');

/// Pumps the widget tree at [interval] until [finder] matches at least one
/// widget, or [timeout] elapses (which throws). Replaces fixed `pump(N)`
/// waits — stops as soon as the UI is ready rather than burning the full budget.
Future<void> pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 15),
  Duration interval = const Duration(milliseconds: 200),
}) async {
  final deadline = tester.binding.clock.now().add(timeout);
  while (!tester.any(finder)) {
    if (tester.binding.clock.now().isAfter(deadline)) {
      throw Exception('pumpUntil timed out waiting for $finder');
    }
    await tester.pump(interval);
  }
  await tester.pumpAndSettle();
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
    userEmail = Platform.environment['STALWART_USER_B'] ?? 'alice@example.com';
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

      _log('app start');
      app.main(
        overrides: [
          secureStorageProvider.overrideWithValue(_InMemorySecureStorage()),
        ],
      );
      await tester.pumpAndSettle();
      _log('app settled');

      // ── Add account ────────────────────────────────────────────────────────
      expect(find.text('No accounts yet.'), findsOneWidget);

      await tester.tap(find.widgetWithIcon(FloatingActionButton, Icons.add));
      await tester.pumpAndSettle();

      expect(find.text('Add account'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Display name'),
        'Alice',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Email address'),
        userEmail,
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        userPass,
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'IMAP host'),
        imapHost,
      );

      // The form has two "Port" fields: index 0 = IMAP, index 1 = SMTP.
      final imapPortField = find.widgetWithText(TextFormField, 'Port').at(0);
      await tester.ensureVisible(imapPortField);
      await tester.enterText(imapPortField, imapPort.toString());

      // IMAP SSL defaults to on — turn it off for the plaintext dev server.
      final imapSslSwitch =
          find.widgetWithText(SwitchListTile, 'SSL/TLS').at(0);
      await tester.ensureVisible(imapSslSwitch);
      await tester.tap(imapSslSwitch);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'SMTP host'),
        smtpHost,
      );

      final smtpPortField = find.widgetWithText(TextFormField, 'Port').at(1);
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
      _log('navigate to mailboxes');
      await tester.tap(find.text('Alice'));
      await pumpUntil(tester, find.text('INBOX'));
      _log('mailboxes settled');

      expect(find.text('INBOX'), findsOneWidget);

      // ── Compose and send email to self ─────────────────────────────────────
      await tester.tap(find.text('INBOX'));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.edit));
      await tester.pumpAndSettle();

      final subject = 'E2E-${DateTime.now().millisecondsSinceEpoch}';

      await tester.enterText(
        find.widgetWithText(TextFormField, 'To'),
        userEmail,
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Subject'),
        subject,
      );

      final bodyField = find.widgetWithText(TextFormField, 'Body');
      await tester.ensureVisible(bodyField);
      await tester.enterText(bodyField, 'Hello from integration test!');

      _log('send email');
      await tester.tap(find.byIcon(Icons.send));
      // Wait for ComposeScreen to pop back to EmailListScreen after send.
      await pumpUntil(tester, find.byIcon(Icons.edit));
      _log('send done');

      // ComposeScreen pops back to EmailListScreen (INBOX) after send.

      // ── Check Sent folder ──────────────────────────────────────────────────
      // Go back to MailboxListScreen.
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sent'));
      await tester.pumpAndSettle();

      // Sync Sent folder to fetch the appended message.
      _log('sync Sent');
      await tester.tap(find.byIcon(Icons.sync));
      await pumpUntil(tester, find.text(subject));
      _log('sync Sent done');

      expect(find.text(subject), findsOneWidget);

      // ── Check Inbox ────────────────────────────────────────────────────────
      await tester.pageBack(); // Sent EmailList → MailboxList
      await tester.pumpAndSettle();

      await tester.tap(find.text('INBOX'));
      await tester.pumpAndSettle();

      // Sync INBOX — Stalwart delivers to self near-instantly.
      _log('sync INBOX');
      await tester.tap(find.byIcon(Icons.sync));
      await pumpUntil(tester, find.text(subject));
      _log('sync INBOX done');

      expect(find.text(subject), findsOneWidget);

      // ── Search ─────────────────────────────────────────────────────────────
      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();

      // Search by the 'E2E-' prefix — should match the message we just sent.
      _log('search');
      await tester.enterText(find.byType(TextField), 'E2E-');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await pumpUntil(tester, find.text(subject));
      _log('search done');

      expect(find.text(subject), findsOneWidget);
    },
  );
}
