import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/di.dart';

class AccountImportScreen extends ConsumerStatefulWidget {
  const AccountImportScreen({super.key});

  @override
  ConsumerState<AccountImportScreen> createState() =>
      _AccountImportScreenState();
}

class _AccountImportScreenState extends ConsumerState<AccountImportScreen> {
  final _ctrl = TextEditingController();
  Account? _parsed;
  String? _parsedPassword;
  String? _parseError;
  bool _saving = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onTextChanged(String value) {
    final text = value.trim();
    if (text.isEmpty) {
      setState(() {
        _parsed = null;
        _parsedPassword = null;
        _parseError = null;
      });
      return;
    }
    try {
      final json = jsonDecode(text) as Map<String, dynamic>;
      if ((json['v'] as int?) != 1) {
        throw const FormatException('Unknown version');
      }
      final account = Account.fromJson(
        json['account'] as Map<String, dynamic>,
      );
      final password = json['password'] as String;
      setState(() {
        _parsed = Account(
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
        _parsedPassword = password;
        _parseError = null;
      });
    } catch (_) {
      setState(() {
        _parsed = null;
        _parsedPassword = null;
        _parseError =
            'Invalid code — paste the full text from "Export account"';
      });
    }
  }

  Future<void> _import() async {
    if (_parsed == null || _parsedPassword == null) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(accountRepositoryProvider)
          .addAccount(_parsed!, _parsedPassword!);
      if (mounted) context.pop();
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Import account')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'On your other device, open the account menu and tap '
              '"Export account". Then copy the code and paste it below.',
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('importCodeField'),
              controller: _ctrl,
              maxLines: 6,
              onChanged: _onTextChanged,
              decoration: const InputDecoration(
                labelText: 'Account code',
                border: OutlineInputBorder(),
                hintText: 'Paste code here',
              ),
            ),
            if (_parseError != null) ...[
              const SizedBox(height: 8),
              Text(
                _parseError!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            if (_parsed != null) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Ready to import:',
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(_parsed!.displayName),
                      Text(_parsed!.email),
                      Text(
                        _parsed!.type == AccountType.jmap ? 'JMAP' : 'IMAP',
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('importButton'),
              onPressed: (_parsed != null && !_saving) ? _import : null,
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Import'),
            ),
          ],
        ),
      ),
    );
  }
}
