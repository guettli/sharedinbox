import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/services/share_encryption_service.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';
import 'package:sharedinbox/ui/widgets/qr_scanner_view.dart';

/// Sending side of the secure account-sharing flow.
///
/// Step 1 – scans (or pastes) the receiver's public-key QR code.
///
/// Step 2 – if more than one account exists, the user selects which accounts
///           to transfer (auto-selected when only one account is present).
///
/// Step 3 – shows the encrypted-accounts QR code for the receiver to scan.
class AccountSendScreen extends ConsumerStatefulWidget {
  const AccountSendScreen({super.key});

  @override
  ConsumerState<AccountSendScreen> createState() => _AccountSendScreenState();
}

enum _Step { scanning, selectAccounts, showEncrypted, error }

class _AccountSendScreenState extends ConsumerState<AccountSendScreen> {
  _Step _step = _Step.scanning;

  // Set after scanning the pubkey QR.
  Uint8List? _recipientKeyId;
  Uint8List? _recipientPublicKey;

  // All available accounts + the selection (for step 2).
  List<Account> _accounts = [];
  final Set<String> _selectedIds = {};

  // Set after encryption (step 3).
  String? _encryptedQr;
  String? _errorMessage;

  // ── Step 1: scan pubkey QR ──────────────────────────────────────────────────

  // Returns true once a valid public-key QR advances the flow; false on an
  // invalid code so [QrScannerView] keeps scanning for a retry.
  Future<bool> _onPubKeyScanned(String rawValue) async {
    final parsed = ShareEncryptionService.parsePublicKeyQr(rawValue);
    if (parsed == null) {
      if (mounted) {
        context.showAppSnackBar(
          'Not a valid sharedinbox.de public-key QR code. '
          'Ask the receiver to show step 1 of "Receive accounts".',
          level: AppLogLevel.warn,
        );
      }
      return false;
    }

    // Load all available accounts.
    final accounts =
        await ref.read(accountRepositoryProvider).observeAccounts().first;

    if (!mounted) return true;

    if (accounts.isEmpty) {
      setState(() {
        _errorMessage = 'No accounts to send.';
        _step = _Step.error;
      });
      return true;
    }

    setState(() {
      _recipientKeyId = parsed.keyId;
      _recipientPublicKey = parsed.publicKeyBytes;
      _accounts = accounts;
    });

    if (accounts.length == 1) {
      // Auto-select the only account; skip the selection step.
      _selectedIds.add(accounts.first.id);
      await _encryptAndShow();
    } else {
      setState(() {
        _selectedIds.addAll(accounts.map((a) => a.id));
        _step = _Step.selectAccounts;
      });
    }
    return true;
  }

  // ── Step 2: account selection ───────────────────────────────────────────────

  Future<void> _encryptAndShow() async {
    final repo = ref.read(accountRepositoryProvider);
    final selected = _accounts.where((a) => _selectedIds.contains(a.id));

    final payloads = <AccountPayload>[];
    for (final account in selected) {
      final password = await repo.getPassword(account.id);
      payloads.add(
        AccountPayload(accountJson: account.toJson(), password: password),
      );
    }

    try {
      final qr = await ShareEncryptionService.encryptAccounts(
        recipientKeyId: _recipientKeyId!,
        recipientPublicKeyBytes: _recipientPublicKey!,
        accounts: payloads,
      );
      if (mounted) {
        setState(() {
          _encryptedQr = qr;
          _step = _Step.showEncrypted;
        });
      }
    } catch (e, stack) {
      unawaited(
        ref.read(appLoggerProvider).error(
              'account.send.encrypt_failed',
              'Failed to encrypt accounts for sharing',
              screen: 'AccountSendScreen',
              error: e,
              stack: stack,
            ),
      );
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _step = _Step.error;
        });
      }
    }
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Send accounts')),
      body: switch (_step) {
        _Step.scanning => _buildScanStep(context),
        _Step.selectAccounts => _buildSelectStep(context),
        _Step.showEncrypted => _buildEncryptedQrStep(context),
        _Step.error => Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Text('Error: $_errorMessage'),
            ),
          ),
      },
    );
  }

  Widget _buildScanStep(BuildContext context) {
    return QrScannerView(
      onDetect: _onPubKeyScanned,
      fallbackBuilder: _buildTextFallbackView,
      logEvent: 'account.send.scanner_failed',
      screen: 'AccountSendScreen',
      overlayBuilder: (context) => Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: Container(
          color: Colors.black54,
          padding: const EdgeInsets.symmetric(
            vertical: AppSpacing.md,
            horizontal: AppSpacing.lg,
          ),
          child: const Text(
            'Point the camera at the public-key QR code shown by the receiver',
            style: TextStyle(color: Colors.white),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }

  Widget _buildTextFallbackView(BuildContext context) {
    final ctrl = TextEditingController();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Paste the public key shown by the receiver\'s "Receive accounts" screen.',
          ),
          const SizedBox(height: AppSpacing.lg),
          TextField(
            key: const Key('pubKeyInputField'),
            controller: ctrl,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Public key',
              border: OutlineInputBorder(),
              hintText: 'sharedinbox.de:pubkey:v1:…',
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          FilledButton(
            onPressed: () {
              final text = ctrl.text.trim();
              if (text.isNotEmpty) unawaited(_onPubKeyScanned(text));
            },
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectStep(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'Select accounts to send',
            style: theme.textTheme.titleMedium,
          ),
        ),
        Expanded(
          child: ListView(
            children: _accounts.map((account) {
              final selected = _selectedIds.contains(account.id);
              return CheckboxListTile(
                value: selected,
                title: Text(account.displayName),
                subtitle: Text(account.email),
                onChanged: (v) {
                  setState(() {
                    if (v == true) {
                      _selectedIds.add(account.id);
                    } else {
                      _selectedIds.remove(account.id);
                    }
                  });
                },
              );
            }).toList(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: FilledButton(
            key: const Key('sendSelectedButton'),
            onPressed: _selectedIds.isEmpty
                ? null
                : () => unawaited(_encryptAndShow()),
            child: const Text('Encrypt & show QR'),
          ),
        ),
      ],
    );
  }

  Widget _buildEncryptedQrStep(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Step 3 — Show this QR code to the receiver',
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'The receiver taps "Step 2 — Scan encrypted QR code" and scans this.',
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.xl),
          Center(
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: QrImageView(
                key: const Key('encryptedAccountsQrCode'),
                data: _encryptedQr!,
                size: 280,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          OutlinedButton.icon(
            key: const Key('copyEncryptedButton'),
            icon: const Icon(Icons.copy),
            label: const Text('Copy encrypted code'),
            onPressed: () {
              unawaited(Clipboard.setData(ClipboardData(text: _encryptedQr!)));
              context.showAppSnackBar(
                'Encrypted code copied to clipboard',
              );
            },
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'This code contains encrypted account data. It is safe to display '
            'briefly — only the receiver\'s device can decrypt it.',
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
