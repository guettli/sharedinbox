import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/services/share_encryption_service.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';
import 'package:sharedinbox/ui/widgets/qr_scanner_view.dart';

/// Receiving side of the secure account-sharing flow.
///
/// Step 1 – generates an X25519 key pair with a 20-minute lifetime and shows
///           the public key as a QR code to be scanned by the sender.
///
/// Step 2 – scans the encrypted-accounts QR code shown by the sender, decrypts
///           it using the private key, and imports the accounts.
class AccountReceiveScreen extends ConsumerStatefulWidget {
  const AccountReceiveScreen({super.key});

  @override
  ConsumerState<AccountReceiveScreen> createState() =>
      _AccountReceiveScreenState();
}

enum _Step { generatingKey, showingPubKey, scanning, importing, done, error }

class _AccountReceiveScreenState extends ConsumerState<AccountReceiveScreen> {
  _Step _step = _Step.generatingKey;
  ShareKeyMaterial? _keyMaterial;
  DateTime? _keyExpiresAt;
  String? _pubKeyQr;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    unawaited(_generateKey());
  }

  Future<void> _generateKey() async {
    try {
      final repo = ref.read(shareKeyRepositoryProvider);
      final material = await repo.createKeyPair();
      final qr = ShareEncryptionService.encodePublicKeyQr(
        material.keyId,
        material.publicKeyBytes,
      );
      setState(() {
        _keyMaterial = material;
        _keyExpiresAt = DateTime.now().toUtc().add(const Duration(minutes: 20));
        _pubKeyQr = qr;
        _step = _Step.showingPubKey;
      });
    } catch (e, stack) {
      unawaited(
        ref.read(appLoggerProvider).error(
              'account.receive.key_generation_failed',
              'Failed to generate share key pair',
              screen: 'AccountReceiveScreen',
              error: e,
              stack: stack,
            ),
      );
      setState(() {
        _errorMessage = e.toString();
        _step = _Step.error;
      });
    }
  }

  void _startScanning() {
    setState(() => _step = _Step.scanning);
  }

  // Returns true so [QrScannerView] stops scanning: on success the screen
  // transitions to the import result, and on failure it returns to the pubkey
  // step (both unmount the scanner).
  Future<bool> _onScanned(String rawValue) async {
    setState(() => _step = _Step.importing);

    try {
      final material = _keyMaterial!;
      final accounts = await ShareEncryptionService.decryptAccounts(
        qrString: rawValue,
        privateKeyBytes: material.privateKeyBytes,
        publicKeyBytes: material.publicKeyBytes,
        keyId: material.keyId,
      );

      final repo = ref.read(accountRepositoryProvider);
      for (final ap in accounts) {
        final account = Account.fromJson(ap.accountJson);
        final newAccount = Account(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          displayName: account.displayName,
          email: account.email,
          username: account.username,
          type: account.type,
          imapHost: account.imapHost,
          imapPort: account.imapPort,
          imapSsl: account.imapSsl,
          smtpHost: account.smtpHost,
          smtpPort: account.smtpPort,
          smtpSsl: account.smtpSsl,
          manageSieveHost: account.manageSieveHost,
          manageSievePort: account.manageSievePort,
          manageSieveSsl: account.manageSieveSsl,
          jmapUrl: account.jmapUrl,
        );
        await repo.addAccount(newAccount, ap.password);
      }

      if (mounted) {
        setState(() => _step = _Step.done);
        context.showAppSnackBar(
          'Imported ${accounts.length} account${accounts.length == 1 ? '' : 's'} successfully.',
        );
        context.pop();
      }
    } catch (e, stack) {
      if (mounted) {
        setState(() {
          _errorMessage = _friendlyError(e);
          // Let user retry from the pubkey step.
          _step = _Step.showingPubKey;
        });
        context.showAppSnackBar(
          _friendlyError(e),
          level: AppLogLevel.error,
          event: 'account.receive.import_failed',
          backgroundColor: Theme.of(context).colorScheme.error,
          error: e,
          stack: stack,
        );
      }
    }
    return true;
  }

  String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('expired') || s.contains('older than')) {
      return 'The QR code has expired. Ask the sender to generate a new one.';
    }
    if (s.contains('Key ID mismatch') || s.contains('Unknown')) {
      return 'QR code does not match this session. Regenerate the public key and try again.';
    }
    if (s.contains('authentication') ||
        s.contains('mac') ||
        s.contains('SecretBox')) {
      return 'Authentication failed — the QR code may have been tampered with.';
    }
    return 'Import failed: $s';
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Receive accounts')),
      body: switch (_step) {
        _Step.generatingKey => const Center(child: CircularProgressIndicator()),
        _Step.showingPubKey => _buildPubKeyView(context),
        _Step.scanning => _buildScannerView(context),
        _Step.importing => const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: AppSpacing.lg),
                Text('Importing accounts…'),
              ],
            ),
          ),
        _Step.done => const Center(
            child: Icon(
              Icons.check_circle,
              size: AppIconSize.hero,
              color: Colors.green,
            ),
          ),
        _Step.error => Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Text('Error: $_errorMessage'),
            ),
          ),
      },
    );
  }

  Widget _buildPubKeyView(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Step 1 of 2 — Show this QR code to the sender',
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'The sender scans this code, selects the account(s) to transfer, '
            'and shows an encrypted QR code. Then come back here for step 2.',
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.xl),
          Center(
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: QrImageView(
                key: const Key('pubKeyQrCode'),
                data: _pubKeyQr!,
                size: 260,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          OutlinedButton.icon(
            icon: const Icon(Icons.copy),
            label: const Text('Copy public key'),
            onPressed: () {
              unawaited(Clipboard.setData(ClipboardData(text: _pubKeyQr!)));
              context.showAppSnackBar(
                'Public key copied to clipboard',
              );
            },
          ),
          const SizedBox(height: AppSpacing.sm),
          _ExpiryHint(expiresAt: _keyExpiresAt!),
          const SizedBox(height: AppSpacing.xxl),
          if (_errorMessage != null) ...[
            Text(
              _errorMessage!,
              style: TextStyle(color: theme.colorScheme.error),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.lg),
          ],
          FilledButton.icon(
            key: const Key('scanEncryptedButton'),
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Step 2 — Scan encrypted QR code'),
            onPressed: _startScanning,
          ),
        ],
      ),
    );
  }

  Widget _buildScannerView(BuildContext context) {
    return QrScannerView(
      onDetect: _onScanned,
      fallbackBuilder: _buildTextFallbackView,
      logEvent: 'account.receive.scanner_failed',
      screen: 'AccountReceiveScreen',
      overlayBuilder: (context) => Stack(
        children: [
          Positioned(
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
                'Point the camera at the encrypted QR code from the sender\'s device',
                style: TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ),
          ),
          Positioned(
            bottom: AppSpacing.xxl,
            left: AppSpacing.lg,
            right: AppSpacing.lg,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                backgroundColor: Colors.black54,
                foregroundColor: Colors.white,
              ),
              // Leaving the scanning step unmounts QrScannerView, which
              // disposes the camera controller.
              onPressed: () => setState(() => _step = _Step.showingPubKey),
              child: const Text('Cancel'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextFallbackView(BuildContext context) {
    final ctrl = TextEditingController();
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Paste the encrypted code from the sender\'s device',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.lg),
          TextField(
            key: const Key('encryptedCodeField'),
            controller: ctrl,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: 'Encrypted code',
              border: OutlineInputBorder(),
              hintText: 'sharedinbox.de:encrypted-accounts:v1:…',
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          FilledButton(
            onPressed: () {
              final text = ctrl.text.trim();
              if (text.isNotEmpty) unawaited(_onScanned(text));
            },
            child: const Text('Import'),
          ),
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton(
            onPressed: () => setState(() => _step = _Step.showingPubKey),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}

class _ExpiryHint extends StatefulWidget {
  const _ExpiryHint({required this.expiresAt});

  final DateTime expiresAt;

  @override
  State<_ExpiryHint> createState() => _ExpiryHintState();
}

class _ExpiryHintState extends State<_ExpiryHint> {
  late Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  String _formatRemaining() {
    final remaining = widget.expiresAt.difference(DateTime.now().toUtc());
    if (remaining.isNegative) return 'expired';
    final minutes = remaining.inMinutes;
    final seconds = remaining.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.timer_outlined, size: AppIconSize.sm, color: muted),
        const SizedBox(width: AppSpacing.xs),
        Text(
          'This key expires in ${_formatRemaining()}',
          style: theme.textTheme.bodySmall?.copyWith(color: muted),
        ),
      ],
    );
  }
}
