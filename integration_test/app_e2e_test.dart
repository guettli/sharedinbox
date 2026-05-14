// E2E integration tests — requires a running Stalwart instance and a display.
// Run via: stalwart-dev/integration_ui_test.sh
//
// Environment variables (set by the runner script):
//   STALWART_IMAP_HOST, STALWART_IMAP_PORT
//   STALWART_SMTP_HOST, STALWART_SMTP_PORT
//   STALWART_USER_B / STALWART_PASS_B  (alice@example.com)

import 'dart:io';

import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/storage/secure_storage.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/main.dart' as app;

/// Plaintext IMAP connection — Stalwart dev server has no TLS certificate.
Future<imap.ImapClient> _connectImapPlaintext(
  Account account,
  String username,
  String password,
) async {
  final client = imap.ImapClient(
    defaultResponseTimeout: const Duration(seconds: 20),
  );
  await client.connectToServer(
    account.imapHost,
    account.imapPort,
    isSecure: false,
  );
  await client.login(username, password);
  return client;
}

/// Plaintext SMTP connection — Stalwart dev server has no TLS certificate.
Future<imap.SmtpClient> _connectSmtpPlaintext(
  Account account,
  String username,
  String password,
) async {
  final atIndex = account.email.lastIndexOf('@');
  final clientDomain =
      atIndex != -1 ? account.email.substring(atIndex + 1) : account.smtpHost;
  final client = imap.SmtpClient(clientDomain);
  await client.connectToServer(
    account.smtpHost,
    account.smtpPort,
    isSecure: false,
  );
  await client.ehlo();
  await client.authenticate(username, password);
  return client;
}

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
  // pump(300ms) instead of pumpAndSettle(): a continuously-running animation
  // (e.g. a spinner in a concurrent test under CPU load) would prevent
  // pumpAndSettle() from ever settling. One bounded pump is enough for any
  // route transition to complete.
  await tester.pump(const Duration(milliseconds: 300));
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

      // Capture the test binding's error recorder BEFORE app.main() so we can
      // restore it in teardown. app.main() sets its own FlutterError.onError
      // (crash-screen handler); we must override it AFTER the call so our
      // filter takes precedence, yet teardown still restores to the binding's
      // recorder (not to the crash handler).
      final bindingError = FlutterError.onError;

      _log('app start');
      app.main(
        overrides: [
          secureStorageProvider.overrideWithValue(_InMemorySecureStorage()),
          // Stalwart dev server has no TLS — use plaintext IMAP/SMTP throughout.
          imapConnectProvider.overrideWithValue(_connectImapPlaintext),
          smtpConnectProvider.overrideWithValue(_connectSmtpPlaintext),
          // Skip the real IMAP connection-check so _AccountTile never shows a
          // CircularProgressIndicator — pumpAndSettle() cannot settle while a
          // continuously-running animation is in the tree.
          accountConnectionStatusProvider.overrideWith((ref, _) async {}),
        ],
      );

      // Override the crash handler that app.main() just installed with a
      // filter that forwards non-spurious errors to the binding's recorder.
      // On Android/Linux, keyboard-dismiss or teardown can produce
      // DEFUNCT/DISPOSED layout errors; discard those silently.
      FlutterError.onError = (details) {
        final msg = details.toString();
        if (msg.contains('DEFUNCT') || msg.contains('DISPOSED')) return;
        bindingError?.call(details);
      };
      addTearDown(() => FlutterError.onError = bindingError);

      await pumpUntil(tester, find.text('Welcome to SharedInbox'));
      _log('app settled');

      // ── Add account ────────────────────────────────────────────────────────
      await tester.tap(find.widgetWithIcon(FloatingActionButton, Icons.add));
      await pumpUntil(tester, find.text('Add account'));

      // Step 1 — enter email and continue.
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Email address'),
        userEmail,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Continue'));

      // Auto-detection fails for example.com → falls back to "choose type".
      await pumpUntil(
        tester,
        find.widgetWithText(OutlinedButton, 'IMAP / SMTP'),
        timeout: const Duration(seconds: 30),
      );
      await tester.tap(find.widgetWithText(OutlinedButton, 'IMAP / SMTP'));
      await tester.pumpAndSettle();

      // Step 2 — IMAP / SMTP form.
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Display name'),
        'Alice',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        userPass,
      );

      // 'Host' appears twice: index 0 = IMAP, index 1 = SMTP.
      final imapHostField = find.widgetWithText(TextFormField, 'Host').at(0);
      await tester.ensureVisible(imapHostField);
      await tester.enterText(imapHostField, imapHost);

      // 'Port' appears twice: index 0 = IMAP, index 1 = SMTP.
      final imapPortField = find.widgetWithText(TextFormField, 'Port').at(0);
      await tester.ensureVisible(imapPortField);
      await tester.enterText(imapPortField, imapPort.toString());

      final smtpHostField = find.widgetWithText(TextFormField, 'Host').at(1);
      await tester.ensureVisible(smtpHostField);
      await tester.enterText(smtpHostField, smtpHost);

      final smtpPortField = find.widgetWithText(TextFormField, 'Port').at(1);
      await tester.ensureVisible(smtpPortField);
      await tester.enterText(smtpPortField, smtpPort.toString());

      final saveButton = find.widgetWithText(FilledButton, 'Save');
      await tester.ensureVisible(saveButton);
      // Dismiss keyboard to stop cursor animation and avoid layout artifacts.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      // Extra wait to ensure layout is fully stable on slow emulators.
      await tester.pump(const Duration(seconds: 2));
      await tester.tap(saveButton);

      // Wait for the account tile to appear in the account list. Use a
      // ListTile-scoped finder so we don't exit early when 'Alice' still
      // appears in the form's EditableText before navigation pops back.
      final aliceTile = find.descendant(
        of: find.byType(ListTile),
        matching: find.text('Alice'),
      );
      await pumpUntil(tester, aliceTile, timeout: const Duration(seconds: 30));

      // ── Navigate to mailboxes ──────────────────────────────────────────────
      _log('navigate to mailboxes');
      // On the slow Android emulator (software rendering), animations can lag.
      // Ensure the route transition is fully settled before tapping.
      await tester.pumpAndSettle();
      await tester.tap(aliceTile);
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
      // Use the drawer to switch folders (no back button on Linux desktop).
      await tester.tap(find.byTooltip('Open navigation menu'));
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
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('INBOX'));
      await tester.pumpAndSettle();

      // Sync INBOX — pump at short intervals so the StreamBuilder rebuilds as
      // soon as the DB stream emits after each sync.  Re-tap sync every ~5 s
      // in case Stalwart's local delivery is slightly delayed.
      _log('sync INBOX');
      await tester.tap(find.byIcon(Icons.sync));
      var tick = 0;
      final inboxDeadline = DateTime.now().add(const Duration(seconds: 60));
      while (!tester.any(find.text(subject))) {
        if (DateTime.now().isAfter(inboxDeadline)) {
          throw Exception('INBOX sync timed out — email never appeared');
        }
        await tester.pump(const Duration(milliseconds: 200));
        tick++;
        // Re-tap every ~5 s (25 × 200 ms) in case the first sync fired before
        // the email was delivered.
        if (tick % 25 == 0) {
          await tester.tap(find.byIcon(Icons.sync));
        }
      }
      await tester.pumpAndSettle();
      _log('sync INBOX done');

      expect(find.text(subject), findsOneWidget);

      // ── Search ─────────────────────────────────────────────────────────────
      // Search by the 'E2E-' prefix — should match the message we just sent.
      // SearchBar is always visible in the AppBar bottom; no icon tap needed.
      _log('search');
      await tester.enterText(find.byType(SearchBar), 'E2E-');
      // Dismiss the IME keyboard so the results ListView.builder gets full
      // body height.  On Android the soft keyboard reduces viewInsets.bottom,
      // leaving near-zero height for the body — ListView.builder then renders
      // 0 items and find.text() always fails even when results are present.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();

      await pumpUntil(
        tester,
        find.text(subject),
        timeout: const Duration(seconds: 30),
      );
      _log('search done');

      expect(find.text(subject), findsOneWidget);
    },
  );
}
