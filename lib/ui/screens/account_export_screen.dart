import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:sharedinbox/di.dart';

class AccountExportScreen extends ConsumerStatefulWidget {
  const AccountExportScreen({super.key, required this.accountId});

  final String accountId;

  @override
  ConsumerState<AccountExportScreen> createState() =>
      _AccountExportScreenState();
}

class _AccountExportScreenState extends ConsumerState<AccountExportScreen> {
  bool _loading = true;
  String? _exportCode;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final repo = ref.read(accountRepositoryProvider);
      final account = await repo.getAccount(widget.accountId);
      if (account == null) {
        setState(() {
          _error = 'Account not found';
          _loading = false;
        });
        return;
      }
      final password = await repo.getPassword(widget.accountId);
      final payload = jsonEncode({
        'v': 1,
        'account': account.toJson(),
        'password': password,
      });
      setState(() {
        _exportCode = payload;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Export account')),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Text('Error: $_error'));
    }

    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            color: theme.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.warning_amber, color: theme.colorScheme.error),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'This code contains your password. Keep it private.',
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: QrImageView(
              key: const Key('accountQrCode'),
              data: _exportCode!,
              size: 260,
            ),
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            key: const Key('copyCodeButton'),
            icon: const Icon(Icons.copy),
            label: const Text('Copy code'),
            onPressed: () {
              unawaited(Clipboard.setData(ClipboardData(text: _exportCode!)));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Code copied to clipboard')),
              );
            },
          ),
          const SizedBox(height: 8),
          const Text(
            'Scan the QR code on your other device, or tap "Copy code" and '
            'paste it into the "Import account" screen.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}
