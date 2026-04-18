import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/account.dart';
import '../../core/models/discovery_result.dart';
import '../../di.dart';

enum _Step { email, detecting, chooseType, jmapForm, imapForm, connecting }

class AddAccountScreen extends ConsumerStatefulWidget {
  const AddAccountScreen({super.key});

  @override
  ConsumerState<AddAccountScreen> createState() => _AddAccountScreenState();
}

class _AddAccountScreenState extends ConsumerState<AddAccountScreen> {
  var _step = _Step.email;
  String? _errorMessage;

  // -- controllers -----------------------------------------------------------
  final _emailCtrl = TextEditingController();
  final _displayNameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _jmapApiUrlCtrl = TextEditingController();
  final _imapHostCtrl = TextEditingController();
  final _imapPortCtrl = TextEditingController(text: '993');
  var _imapSsl = true;
  final _smtpHostCtrl = TextEditingController();
  final _smtpPortCtrl = TextEditingController(text: '587');
  var _smtpSsl = false;

  // -- form keys -------------------------------------------------------------
  final _emailFormKey = GlobalKey<FormState>();
  final _jmapFormKey = GlobalKey<FormState>();
  final _imapFormKey = GlobalKey<FormState>();

  @override
  void dispose() {
    for (final c in [
      _emailCtrl,
      _displayNameCtrl,
      _passwordCtrl,
      _jmapApiUrlCtrl,
      _imapHostCtrl,
      _imapPortCtrl,
      _smtpHostCtrl,
      _smtpPortCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  // -- actions ---------------------------------------------------------------

  Future<void> _detectAccount() async {
    if (!_emailFormKey.currentState!.validate()) return;
    setState(() {
      _step = _Step.detecting;
      _errorMessage = null;
    });
    try {
      final result = await ref
          .read(accountDiscoveryServiceProvider)
          .discover(_emailCtrl.text.trim());
      if (!mounted) return;
      switch (result) {
        case JmapDiscovery(:final apiUrl):
          _jmapApiUrlCtrl.text = apiUrl;
          setState(() => _step = _Step.jmapForm);
        case ImapSmtpDiscovery(
            :final imapHost,
            :final imapPort,
            :final imapSsl,
            :final smtpHost,
            :final smtpPort,
            :final smtpSsl,
          ):
          _imapHostCtrl.text = imapHost;
          _imapPortCtrl.text = imapPort.toString();
          _imapSsl = imapSsl;
          _smtpHostCtrl.text = smtpHost;
          _smtpPortCtrl.text = smtpPort.toString();
          _smtpSsl = smtpSsl;
          setState(() => _step = _Step.imapForm);
        case UnknownDiscovery():
          setState(() => _step = _Step.chooseType);
      }
    } catch (_) {
      if (mounted) setState(() => _step = _Step.chooseType);
    }
  }

  Future<void> _saveJmap() async {
    if (!_jmapFormKey.currentState!.validate()) return;
    setState(() {
      _step = _Step.connecting;
      _errorMessage = null;
    });
    try {
      final account = Account(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        displayName: _displayNameCtrl.text.trim(),
        email: _emailCtrl.text.trim(),
        type: AccountType.jmap,
        jmapUrl: _jmapApiUrlCtrl.text.trim(),
      );
      await ref
          .read(connectionTestServiceProvider)
          .testConnection(account, _passwordCtrl.text);
      await ref
          .read(accountRepositoryProvider)
          .addAccount(account, _passwordCtrl.text);
      if (mounted) context.pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _step = _Step.jmapForm;
          _errorMessage = 'Connection failed: $e';
        });
      }
    }
  }

  Future<void> _saveImap() async {
    if (!_imapFormKey.currentState!.validate()) return;
    setState(() {
      _step = _Step.connecting;
      _errorMessage = null;
    });
    try {
      final account = Account(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        displayName: _displayNameCtrl.text.trim(),
        email: _emailCtrl.text.trim(),
        imapHost: _imapHostCtrl.text.trim(),
        imapPort: int.parse(_imapPortCtrl.text),
        imapSsl: _imapSsl,
        smtpHost: _smtpHostCtrl.text.trim(),
        smtpPort: int.parse(_smtpPortCtrl.text),
        smtpSsl: _smtpSsl,
      );
      await ref
          .read(connectionTestServiceProvider)
          .testConnection(account, _passwordCtrl.text);
      await ref
          .read(accountRepositoryProvider)
          .addAccount(account, _passwordCtrl.text);
      if (mounted) context.pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _step = _Step.imapForm;
          _errorMessage = 'Connection failed: $e';
        });
      }
    }
  }

  // -- build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add account')),
      body: switch (_step) {
        _Step.email => _buildEmailStep(),
        _Step.detecting =>
          _buildSpinner('Detecting account settings\u2026'),
        _Step.chooseType => _buildChooseTypeStep(),
        _Step.jmapForm => _buildJmapForm(),
        _Step.imapForm => _buildImapForm(),
        _Step.connecting => _buildSpinner('Connecting\u2026'),
      },
    );
  }

  // -- step widgets ----------------------------------------------------------

  Widget _buildEmailStep() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Form(
        key: _emailFormKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              key: const Key('emailField'),
              controller: _emailCtrl,
              keyboardType: TextInputType.emailAddress,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Email address',
                border: OutlineInputBorder(),
              ),
              validator: (v) {
                if (v == null || v.trim().isEmpty) return 'Required';
                if (!v.contains('@')) return 'Enter a valid email address';
                return null;
              },
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _detectAccount,
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSpinner(String label) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(label),
        ],
      ),
    );
  }

  Widget _buildChooseTypeStep() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Could not auto-detect settings for '
            '${_emailCtrl.text.trim()}.\n'
            'Choose account type:',
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () => setState(() {
              _jmapApiUrlCtrl.clear();
              _step = _Step.jmapForm;
            }),
            child: const Text('JMAP'),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => setState(() {
              _imapHostCtrl.clear();
              _imapPortCtrl.text = '993';
              _imapSsl = true;
              _smtpHostCtrl.clear();
              _smtpPortCtrl.text = '587';
              _smtpSsl = false;
              _step = _Step.imapForm;
            }),
            child: const Text('IMAP / SMTP'),
          ),
        ],
      ),
    );
  }

  Widget _buildJmapForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Form(
        key: _jmapFormKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _emailHeader('JMAP'),
            if (_errorMessage != null) _errorBanner(),
            _field(_displayNameCtrl, 'Display name'),
            _field(_jmapApiUrlCtrl, 'JMAP API URL',
                keyboardType: TextInputType.url),
            _field(_passwordCtrl, 'Password', obscure: true),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saveJmap,
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImapForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Form(
        key: _imapFormKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _emailHeader('IMAP / SMTP'),
            if (_errorMessage != null) _errorBanner(),
            _field(_displayNameCtrl, 'Display name'),
            _field(_passwordCtrl, 'Password', obscure: true),
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
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saveImap,
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  // -- small helpers ---------------------------------------------------------

  Widget _emailHeader(String accountTypeLabel) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _emailCtrl.text.trim(),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text(
            accountTypeLabel,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _errorBanner() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        _errorMessage!,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
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
        validator: (v) =>
            (v == null || v.trim().isEmpty) ? 'Required' : null,
      ),
    );
  }
}
