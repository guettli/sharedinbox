import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/account.dart';
import '../../di.dart';

class EditAccountScreen extends ConsumerStatefulWidget {
  const EditAccountScreen({super.key, required this.accountId});
  final String accountId;

  @override
  ConsumerState<EditAccountScreen> createState() => _EditAccountScreenState();
}

class _EditAccountScreenState extends ConsumerState<EditAccountScreen> {
  final _formKey = GlobalKey<FormState>();
  bool _loading = true;
  bool _saving = false;
  String? _errorMessage;

  Account? _account;

  final _displayNameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _imapHostCtrl = TextEditingController();
  final _imapPortCtrl = TextEditingController();
  var _imapSsl = true;
  final _smtpHostCtrl = TextEditingController();
  final _smtpPortCtrl = TextEditingController();
  var _smtpSsl = false;
  final _jmapUrlCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = ref.read(accountRepositoryProvider);
    final account = await repo.getAccount(widget.accountId);
    if (!mounted) return;
    if (account == null) {
      context.pop();
      return;
    }
    _account = account;
    _displayNameCtrl.text = account.displayName;
    _imapHostCtrl.text = account.imapHost;
    _imapPortCtrl.text = account.imapPort.toString();
    _imapSsl = account.imapSsl;
    _smtpHostCtrl.text = account.smtpHost;
    _smtpPortCtrl.text = account.smtpPort.toString();
    _smtpSsl = account.smtpSsl;
    _jmapUrlCtrl.text = account.jmapUrl ?? '';
    setState(() => _loading = false);
  }

  @override
  void dispose() {
    for (final c in [
      _displayNameCtrl,
      _passwordCtrl,
      _imapHostCtrl,
      _imapPortCtrl,
      _smtpHostCtrl,
      _smtpPortCtrl,
      _jmapUrlCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final account = _account!;
    final password =
        _passwordCtrl.text.isNotEmpty ? _passwordCtrl.text : null;

    final updated = Account(
      id: account.id,
      displayName: _displayNameCtrl.text.trim(),
      email: account.email,
      type: account.type,
      imapHost: _imapHostCtrl.text.trim(),
      imapPort: int.tryParse(_imapPortCtrl.text) ?? account.imapPort,
      imapSsl: _imapSsl,
      smtpHost: _smtpHostCtrl.text.trim(),
      smtpPort: int.tryParse(_smtpPortCtrl.text) ?? account.smtpPort,
      smtpSsl: _smtpSsl,
      jmapUrl:
          _jmapUrlCtrl.text.trim().isEmpty ? null : _jmapUrlCtrl.text.trim(),
    );

    setState(() {
      _saving = true;
      _errorMessage = null;
    });

    try {
      if (password != null) {
        await ref
            .read(connectionTestServiceProvider)
            .testConnection(updated, password);
      }
      await ref
          .read(accountRepositoryProvider)
          .updateAccount(updated, password: password);
      if (mounted) context.pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _errorMessage = 'Save failed: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edit account')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _saving
              ? const Center(child: CircularProgressIndicator())
              : _buildForm(),
    );
  }

  Widget _buildForm() {
    final account = _account!;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(account.email,
                style: Theme.of(context).textTheme.titleMedium),
            Text(
              account.type == AccountType.jmap ? 'JMAP' : 'IMAP',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            if (_errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  _errorMessage!,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            _field(_displayNameCtrl, 'Display name'),
            _field(_passwordCtrl, 'New password (leave blank to keep)',
                key: const Key('editPasswordField'),
                obscure: true,
                required: false),
            if (account.type == AccountType.jmap) ...[
              const Divider(height: 32),
              _field(_jmapUrlCtrl, 'JMAP API URL',
                  keyboardType: TextInputType.url),
            ],
            if (account.type == AccountType.imap) ...[
              const Divider(height: 32),
              Text('IMAP', style: Theme.of(context).textTheme.titleSmall),
              _field(_imapHostCtrl, 'Host'),
              _field(_imapPortCtrl, 'Port',
                  keyboardType: TextInputType.number),
              SwitchListTile(
                title: const Text('SSL/TLS'),
                value: _imapSsl,
                onChanged: (v) => setState(() => _imapSsl = v),
              ),
              const Divider(height: 32),
              Text('SMTP', style: Theme.of(context).textTheme.titleSmall),
              _field(_smtpHostCtrl, 'Host'),
              _field(_smtpPortCtrl, 'Port',
                  keyboardType: TextInputType.number),
              SwitchListTile(
                title: const Text('SSL/TLS'),
                value: _smtpSsl,
                onChanged: (v) => setState(() => _smtpSsl = v),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(onPressed: _save, child: const Text('Save')),
          ],
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController ctrl,
    String label, {
    Key? key,
    bool obscure = false,
    bool required = true,
    TextInputType? keyboardType,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextFormField(
        key: key,
        controller: ctrl,
        obscureText: obscure,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        validator: required
            ? (v) => (v == null || v.trim().isEmpty) ? 'Required' : null
            : null,
      ),
    );
  }
}
