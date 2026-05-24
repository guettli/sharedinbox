import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/services/share_encryption_service.dart';
import 'package:sharedinbox/di.dart';

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
  bool _scannerActive = true;

  MobileScannerController? _scannerController;
  // True when the scanner plugin fails to initialise at runtime (e.g.
  // MissingPluginException on some Android builds).
  bool _scannerFailed = false;

  @override
  void initState() {
    super.initState();
    if (_cameraScanSupported()) {
      unawaited(_initScanner());
    }
  }

  // Pre-flight: start + stop the scanner to verify the plugin is available.
  // Falls back to text entry on any exception (including MissingPluginException).
  Future<void> _initScanner() async {
    MobileScannerController? ctrl;
    bool available = false;
    try {
      ctrl = MobileScannerController();
      await ctrl.start();
      await ctrl.stop();
      available = true;
    } catch (_) {
      // Plugin not available on this device; text fallback will be shown.
    } finally {
      try {
        await ctrl?.dispose();
      } catch (_) {}
    }
    if (!mounted) return;
    if (available) {
      setState(() => _scannerController = MobileScannerController());
    } else {
      setState(() => _scannerFailed = true);
    }
  }

  @override
  void dispose() {
    final ctrl = _scannerController;
    if (ctrl != null) unawaited(ctrl.dispose());
    super.dispose();
  }

  // ── Step 1: scan pubkey QR ──────────────────────────────────────────────────

  Future<void> _onPubKeyScanned(String rawValue) async {
    if (!_scannerActive) return;
    _scannerActive = false;
    await _scannerController?.stop();

    final parsed = ShareEncryptionService.parsePublicKeyQr(rawValue);
    if (parsed == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Not a valid sharedinbox.de public-key QR code. '
              'Ask the receiver to show step 1 of "Receive accounts".',
            ),
          ),
        );
        // Allow retry.
        setState(() => _scannerActive = true);
        await _scannerController?.start();
      }
      return;
    }

    // Load all available accounts.
    final accounts =
        await ref.read(accountRepositoryProvider).observeAccounts().first;

    if (!mounted) return;

    if (accounts.isEmpty) {
      setState(() {
        _errorMessage = 'No accounts to send.';
        _step = _Step.error;
      });
      return;
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
  }

  // ── Step 2: account selection ───────────────────────────────────────────────

  Future<void> _encryptAndShow() async {
    final repo = ref.read(accountRepositoryProvider);
    final selected = _accounts.where((a) => _selectedIds.contains(a.id));

    final payloads = <AccountPayload>[];
    for (final account in selected) {
      final password = await repo.getPassword(account.id);
      payloads.add(
        AccountPayload(
          accountJson: account.toJson(),
          password: password,
        ),
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
    } catch (e) {
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
              padding: const EdgeInsets.all(16),
              child: Text('Error: $_errorMessage'),
            ),
          ),
      },
    );
  }

  Widget _buildScanStep(BuildContext context) {
    if (!_cameraScanSupported() || _scannerFailed) {
      return _buildTextFallbackView(context);
    }
    if (_scannerController == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Stack(
      children: [
        MobileScanner(
          controller: _scannerController!,
          onDetect: (capture) {
            final raw = capture.barcodes.firstOrNull?.rawValue;
            if (raw != null) unawaited(_onPubKeyScanned(raw));
          },
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Container(
            color: Colors.black54,
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            child: const Text(
              'Point the camera at the public-key QR code shown by the receiver',
              style: TextStyle(color: Colors.white),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTextFallbackView(BuildContext context) {
    final ctrl = TextEditingController();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Paste the public key shown by the receiver\'s "Receive accounts" screen.',
          ),
          const SizedBox(height: 16),
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
          const SizedBox(height: 16),
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
          padding: const EdgeInsets.all(16),
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
          padding: const EdgeInsets.all(16),
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
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Step 3 — Show this QR code to the receiver',
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'The receiver taps "Step 2 — Scan encrypted QR code" and scans this.',
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Center(
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(8),
              child: QrImageView(
                key: const Key('encryptedAccountsQrCode'),
                data: _encryptedQr!,
                size: 280,
              ),
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            key: const Key('copyEncryptedButton'),
            icon: const Icon(Icons.copy),
            label: const Text('Copy encrypted code'),
            onPressed: () {
              unawaited(Clipboard.setData(ClipboardData(text: _encryptedQr!)));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Encrypted code copied to clipboard',
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 8),
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

bool _cameraScanSupported() =>
    Platform.isAndroid ||
    Platform.isIOS ||
    Platform.isMacOS ||
    Platform.isWindows;
