import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/account.dart';
import '../../di.dart';

class AddAccountScreen extends ConsumerStatefulWidget {
  const AddAccountScreen({super.key});

  @override
  ConsumerState<AddAccountScreen> createState() => _AddAccountScreenState();
}

class _AddAccountScreenState extends ConsumerState<AddAccountScreen> {
  final _form = GlobalKey<FormState>();
  final _displayName = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _imapHost = TextEditingController();
  final _imapPort = TextEditingController(text: '993');
  bool _imapSsl = true;
  final _smtpHost = TextEditingController();
  final _smtpPort = TextEditingController(text: '587');
  bool _smtpSsl = false;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [
      _displayName,
      _email,
      _password,
      _imapHost,
      _imapPort,
      _smtpHost,
      _smtpPort,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final account = Account(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        displayName: _displayName.text.trim(),
        email: _email.text.trim(),
        imapHost: _imapHost.text.trim(),
        imapPort: int.parse(_imapPort.text),
        imapSsl: _imapSsl,
        smtpHost: _smtpHost.text.trim(),
        smtpPort: int.parse(_smtpPort.text),
        smtpSsl: _smtpSsl,
      );
      await ref
          .read(accountRepositoryProvider)
          .addAccount(account, _password.text);
      if (mounted) context.pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add account')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _field(_displayName, 'Display name'),
            _field(_email, 'Email address', keyboardType: TextInputType.emailAddress),
            _field(_password, 'Password', obscure: true),
            const Divider(),
            const Text('IMAP', style: TextStyle(fontWeight: FontWeight.bold)),
            _field(_imapHost, 'IMAP host'),
            _field(_imapPort, 'Port', keyboardType: TextInputType.number),
            SwitchListTile(
              title: const Text('SSL/TLS'),
              value: _imapSsl,
              onChanged: (v) => setState(() => _imapSsl = v),
            ),
            const Divider(),
            const Text('SMTP', style: TextStyle(fontWeight: FontWeight.bold)),
            _field(_smtpHost, 'SMTP host'),
            _field(_smtpPort, 'Port', keyboardType: TextInputType.number),
            SwitchListTile(
              title: const Text('SSL/TLS'),
              value: _smtpSsl,
              onChanged: (v) => setState(() => _smtpSsl = v),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController ctrl,
    String label, {
    bool obscure = false,
    TextInputType? keyboardType,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextFormField(
        controller: ctrl,
        obscureText: obscure,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
      ),
    );
  }
}
