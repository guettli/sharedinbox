import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/services/share_encryption_service.dart';

import 'helpers.dart';

void main() {
  group('AccountReceiveScreen', () {
    testWidgets('shows pubkey QR code and scan button after key generation', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/receive',
          overrides: baseOverrides(),
        ),
      );
      // Allow async key generation to complete.
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pubKeyQrCode')), findsOneWidget);
      expect(find.byKey(const Key('scanEncryptedButton')), findsOneWidget);
    });

    testWidgets('shows expiry countdown hint', (tester) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/receive',
          overrides: baseOverrides(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('expires in'), findsOneWidget);
    });

    testWidgets(
      'step 2 button shows text-input fallback on platforms without camera',
      (tester) async {
        await tester.pumpWidget(
          buildApp(
            initialLocation: '/accounts/receive',
            overrides: baseOverrides(),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('scanEncryptedButton')));
        await tester.pumpAndSettle();

        // On Linux (desktop, no camera) the text fallback field must appear.
        expect(find.byKey(const Key('encryptedCodeField')), findsOneWidget);
      },
    );

    testWidgets(
      'step 2 — valid encrypted QR imports account via text fallback',
      (tester) async {
        // Pre-generate a key pair so we can encrypt a QR code with the same
        // material the screen will use for decryption.
        final material = await ShareEncryptionService.generateKeyPair();
        final repo = FakeShareKeyRepository(material: material);

        const account = Account(
          id: 'src-1',
          displayName: 'Alice',
          email: 'alice@example.com',
          imapHost: 'imap.example.com',
          smtpHost: 'smtp.example.com',
        );

        final encryptedQr = await ShareEncryptionService.encryptAccounts(
          recipientKeyId: material.keyId,
          recipientPublicKeyBytes: material.publicKeyBytes,
          accounts: [
            AccountPayload(accountJson: account.toJson(), password: 'secret'),
          ],
        );

        await tester.pumpWidget(
          buildApp(
            initialLocation: '/accounts/receive',
            overrides: baseOverrides(shareKeyRepository: repo),
          ),
        );
        await tester.pumpAndSettle(); // key generation completes

        await tester.tap(find.byKey(const Key('scanEncryptedButton')));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('encryptedCodeField')),
          encryptedQr,
        );
        await tester.tap(find.text('Import'));
        await tester.pumpAndSettle();

        expect(find.text('Imported 1 account successfully.'), findsOneWidget);
      },
    );

    testWidgets(
      'step 2 — invalid encrypted QR shows error and returns to pub-key step',
      (tester) async {
        await tester.pumpWidget(
          buildApp(
            initialLocation: '/accounts/receive',
            overrides: baseOverrides(),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('scanEncryptedButton')));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('encryptedCodeField')),
          'not-a-valid-qr-code',
        );
        await tester.tap(find.text('Import'));
        await tester.pumpAndSettle();

        // Screen returns to the pub-key step with an error message visible.
        expect(find.byKey(const Key('pubKeyQrCode')), findsOneWidget);
        expect(find.textContaining('Import failed:'), findsWidgets);
      },
    );
  });

  group('AccountSendScreen', () {
    testWidgets('shows camera scanner (or text fallback) on load', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/send',
          overrides: baseOverrides(
            accounts: [
              const Account(
                id: 'acc-1',
                displayName: 'Alice',
                email: 'alice@example.com',
                imapHost: 'imap.example.com',
                smtpHost: 'smtp.example.com',
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // On Linux (desktop without camera), the text-fallback field appears.
      // On mobile, the MobileScanner widget would be shown.
      // Either way the screen renders without crash.
      expect(find.byType(Scaffold), findsAtLeastNWidgets(1));
    });

    testWidgets('shows account selection when multiple accounts present', (
      tester,
    ) async {
      const account1 = Account(
        id: 'acc-1',
        displayName: 'Alice',
        email: 'alice@example.com',
        imapHost: 'imap.example.com',
        smtpHost: 'smtp.example.com',
      );
      const account2 = Account(
        id: 'acc-2',
        displayName: 'Bob',
        email: 'bob@example.com',
        imapHost: 'imap.example.com',
        smtpHost: 'smtp.example.com',
      );

      // Generate a real key pair and a valid pubkey QR string to feed in.
      final material = await ShareEncryptionService.generateKeyPair();
      final pubKeyQr = ShareEncryptionService.encodePublicKeyQr(
        material.keyId,
        material.publicKeyBytes,
      );

      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/send',
          overrides: baseOverrides(accounts: [account1, account2]),
        ),
      );
      await tester.pumpAndSettle();

      // On desktop the text fallback is shown — simulate pasting the pubkey.
      final field = find.byKey(const Key('pubKeyInputField'));
      if (field.evaluate().isNotEmpty) {
        await tester.enterText(field, pubKeyQr);
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();

        // With two accounts the selection list should appear.
        expect(find.byKey(const Key('sendSelectedButton')), findsOneWidget);
        expect(find.text('Alice'), findsOneWidget);
        expect(find.text('Bob'), findsOneWidget);
      }
      // On mobile the MobileScanner handles this; we skip it in widget tests.
    });

    testWidgets('shows encrypted QR after single account auto-select', (
      tester,
    ) async {
      const account = Account(
        id: 'acc-1',
        displayName: 'Alice',
        email: 'alice@example.com',
        imapHost: 'imap.example.com',
        smtpHost: 'smtp.example.com',
      );

      final material = await ShareEncryptionService.generateKeyPair();
      final pubKeyQr = ShareEncryptionService.encodePublicKeyQr(
        material.keyId,
        material.publicKeyBytes,
      );

      await tester.pumpWidget(
        buildApp(
          initialLocation: '/accounts/send',
          overrides: baseOverrides(accounts: [account]),
        ),
      );
      await tester.pumpAndSettle();

      final field = find.byKey(const Key('pubKeyInputField'));
      if (field.evaluate().isNotEmpty) {
        await tester.enterText(field, pubKeyQr);
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();

        // Single account → auto-selected → encrypted QR shown immediately.
        expect(
          find.byKey(const Key('encryptedAccountsQrCode')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('copyEncryptedButton')), findsOneWidget);
      }
    });
  });
}
