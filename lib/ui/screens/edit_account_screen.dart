import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/utils/host_utils.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/linkified_text.dart';
import 'package:sharedinbox/ui/widgets/try_connection_button.dart';

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
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _imapHostCtrl = TextEditingController();
  final _imapPortCtrl = TextEditingController();
  final _smtpHostCtrl = TextEditingController();
  final _smtpPortCtrl = TextEditingController();
  var _smtpSsl = true;
  final _sieveHostCtrl = TextEditingController();
  final _sievePortCtrl = TextEditingController();
  var _sieveSsl = true;
  var _verbose = false;
  final _jmapUrlCtrl = TextEditingController();
  bool _hasStoredPassword = false;

  // -- "Try connection" state ------------------------------------------------
  bool _tryTesting = false;
  String? _tryOk;
  String? _tryErr;

  @override
  void initState() {
    super.initState();
    _smtpHostCtrl.addListener(_rebuild);
    _sieveHostCtrl.addListener(_rebuild);
    _imapHostCtrl.addListener(_rebuild);
    _passwordCtrl.addListener(_rebuild);
    unawaited(_load());
  }

  void _rebuild() => setState(() {});

  Future<void> _load() async {
    final repo = ref.read(accountRepositoryProvider);
    final account = await repo.getAccount(widget.accountId);
    if (!mounted) return;
    if (account == null) {
      context.pop();
      return;
    }
    try {
      await repo.getPassword(account.id);
      _hasStoredPassword = true;
    } catch (_) {
      // No stored password (or keystore miss): not surfaced to the user, so
      // nothing to log — the form simply prompts for one.
    }
    if (!mounted) return;
    _account = account;
    _displayNameCtrl.text = account.displayName;
    _usernameCtrl.text = account.username;
    _imapHostCtrl.text = account.imapHost;
    _imapPortCtrl.text = account.imapPort.toString();
    _smtpHostCtrl.text = account.smtpHost;
    _smtpPortCtrl.text = account.smtpPort.toString();
    _smtpSsl = account.smtpSsl;
    _sieveHostCtrl.text = account.manageSieveHost;
    _sievePortCtrl.text = account.manageSievePort.toString();
    _sieveSsl = account.manageSieveSsl;
    _verbose = account.verbose;
    _jmapUrlCtrl.text = account.jmapUrl ?? '';
    setState(() => _loading = false);
  }

  @override
  void dispose() {
    _smtpHostCtrl.removeListener(_rebuild);
    _sieveHostCtrl.removeListener(_rebuild);
    _imapHostCtrl.removeListener(_rebuild);
    _passwordCtrl.removeListener(_rebuild);
    for (final c in [
      _displayNameCtrl,
      _usernameCtrl,
      _passwordCtrl,
      _imapHostCtrl,
      _imapPortCtrl,
      _smtpHostCtrl,
      _smtpPortCtrl,
      _sieveHostCtrl,
      _sievePortCtrl,
      _jmapUrlCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Account _buildUpdated() {
    final account = _account!;
    final imapHost = _imapHostCtrl.text.trim();
    final sieveHost = _sieveHostCtrl.text.trim();
    final sievePort =
        int.tryParse(_sievePortCtrl.text) ?? account.manageSievePort;
    // Reset the cached probe result when any field that affects the probe
    // changed; the post-save probe will refill it.
    final sieveSettingsChanged = imapHost != account.imapHost ||
        sieveHost != account.manageSieveHost ||
        sievePort != account.manageSievePort ||
        _sieveSsl != account.manageSieveSsl;
    final smtpHost = _smtpHostCtrl.text.trim();
    final effectiveSieveHost = sieveHost.isNotEmpty ? sieveHost : imapHost;
    return Account(
      id: account.id,
      displayName: _displayNameCtrl.text.trim(),
      email: account.email,
      username: _usernameCtrl.text.trim(),
      type: account.type,
      imapHost: imapHost,
      imapPort: int.tryParse(_imapPortCtrl.text) ?? account.imapPort,
      imapSsl: isLocalhost(imapHost) ? account.imapSsl : true,
      smtpHost: smtpHost,
      smtpPort: int.tryParse(_smtpPortCtrl.text) ?? account.smtpPort,
      smtpSsl: isLocalhost(smtpHost) ? _smtpSsl : true,
      manageSieveHost: sieveHost,
      manageSievePort: sievePort,
      manageSieveSsl: isLocalhost(effectiveSieveHost) ? _sieveSsl : true,
      manageSieveAvailable:
          sieveSettingsChanged ? null : account.manageSieveAvailable,
      jmapUrl:
          _jmapUrlCtrl.text.trim().isEmpty ? null : _jmapUrlCtrl.text.trim(),
      verbose: _verbose,
    );
  }

  Future<void> _tryConnection() async {
    if (!_formKey.currentState!.validate()) return;
    final password = _passwordCtrl.text.isNotEmpty
        ? _passwordCtrl.text
        : await ref
            .read(accountRepositoryProvider)
            .getPassword(widget.accountId);
    setState(() {
      _tryTesting = true;
      _tryOk = null;
      _tryErr = null;
    });
    try {
      final result = await ref
          .read(connectionTestServiceProvider)
          .testConnection(_buildUpdated(), password);
      if (mounted) {
        setState(() {
          _tryTesting = false;
          _tryOk = result.identityWarning != null
              ? 'Connected as ${result.username}\n⚠ ${result.identityWarning}'
              : 'Connected as ${result.username}';
        });
      }
    } catch (e, stack) {
      unawaited(
        ref.read(appLoggerProvider).warn(
              'account.test_connection_failed',
              'Connection test failed',
              screen: 'EditAccountScreen',
              accountId: widget.accountId,
              error: e,
              stack: stack,
            ),
      );
      if (mounted) {
        setState(() {
          _tryTesting = false;
          _tryErr = e.toString();
        });
      }
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final password = _passwordCtrl.text.isNotEmpty ? _passwordCtrl.text : null;

    setState(() {
      _saving = true;
      _errorMessage = null;
    });

    try {
      Account updated = _buildUpdated();
      if (password != null) {
        final result = await ref
            .read(connectionTestServiceProvider)
            .testConnection(updated, password);
        if (result.identityWarning != null) {
          unawaited(
            ref.read(appLoggerProvider).warn(
                  'account.identity_warning',
                  result.identityWarning!,
                  screen: 'EditAccountScreen',
                  accountId: widget.accountId,
                ),
          );
        }
        // Persist the discovered effective username when none was explicit.
        if (updated.username.isEmpty) {
          updated = Account(
            id: updated.id,
            displayName: updated.displayName,
            email: updated.email,
            username: result.username,
            type: updated.type,
            imapHost: updated.imapHost,
            imapPort: updated.imapPort,
            smtpHost: updated.smtpHost,
            smtpPort: updated.smtpPort,
            smtpSsl: updated.smtpSsl,
            manageSieveHost: updated.manageSieveHost,
            manageSievePort: updated.manageSievePort,
            manageSieveSsl: updated.manageSieveSsl,
            manageSieveAvailable: updated.manageSieveAvailable,
            jmapUrl: updated.jmapUrl,
            verbose: updated.verbose,
          );
        }
      }
      await ref
          .read(accountRepositoryProvider)
          .updateAccount(updated, password: password);
      // Re-probe when the cached availability was cleared above.
      if (updated.type == AccountType.imap &&
          updated.manageSieveAvailable == null) {
        unawaited(ref.read(manageSieveProbeServiceProvider).probe(updated));
      }
      if (mounted) context.pop();
    } catch (e, stack) {
      unawaited(
        ref.read(appLoggerProvider).error(
              'account.save_failed',
              'Failed to save account',
              screen: 'EditAccountScreen',
              accountId: widget.accountId,
              error: e,
              stack: stack,
            ),
      );
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
      body: _loading || _saving
          ? const Center(child: CircularProgressIndicator())
          : _buildForm(),
    );
  }

  Widget _buildForm() {
    final account = _account!;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(account.email, style: Theme.of(context).textTheme.titleMedium),
            Text(
              account.type == AccountType.jmap ? 'JMAP' : 'IMAP',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.lg),
            if (_errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: LinkifiedText(
                  _errorMessage!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            _field(_displayNameCtrl, 'Display name'),
            _field(
              _usernameCtrl,
              'Username (leave blank to use email)',
              required: false,
            ),
            _field(
              _passwordCtrl,
              _hasStoredPassword
                  ? 'New password (leave blank to keep)'
                  : 'Password',
              key: const Key('editPasswordField'),
              obscure: true,
              required: !_hasStoredPassword,
            ),
            if (account.type == AccountType.jmap) ...[
              const Divider(height: 32),
              _field(
                _jmapUrlCtrl,
                'JMAP API URL',
                keyboardType: TextInputType.url,
              ),
            ],
            if (account.type == AccountType.imap) ...[
              const Divider(height: 32),
              Text(
                'IMAP (SSL/TLS)',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              _field(_imapHostCtrl, 'Host', validator: validateHostname),
              _field(_imapPortCtrl, 'Port', keyboardType: TextInputType.number),
              const Divider(height: 32),
              Text('SMTP', style: Theme.of(context).textTheme.titleSmall),
              _field(_smtpHostCtrl, 'Host', validator: validateHostname),
              _field(_smtpPortCtrl, 'Port', keyboardType: TextInputType.number),
              if (isLocalhost(_smtpHostCtrl.text.trim()))
                SwitchListTile(
                  title: const Text('SSL/TLS'),
                  value: _smtpSsl,
                  onChanged: (v) => setState(() => _smtpSsl = v),
                ),
              const Divider(height: 32),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(
                  'ManageSieve (email filters)',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                children: [
                  _field(
                    _sieveHostCtrl,
                    'Host (leave blank to use IMAP host)',
                    required: false,
                    validator: validateOptionalHostname,
                  ),
                  _field(
                    _sievePortCtrl,
                    'Port',
                    keyboardType: TextInputType.number,
                  ),
                  if (isLocalhost(
                    _sieveHostCtrl.text.trim().isNotEmpty
                        ? _sieveHostCtrl.text.trim()
                        : _imapHostCtrl.text.trim(),
                  ))
                    SwitchListTile(
                      title: const Text('SSL/TLS'),
                      value: _sieveSsl,
                      onChanged: (v) => setState(() => _sieveSsl = v),
                    ),
                ],
              ),
            ],
            const Divider(height: 32),
            SwitchListTile(
              title: const Text('Verbose protocol logging'),
              subtitle: const Text(
                'Writes raw protocol traffic to the sync log. '
                'Disable when not debugging.',
              ),
              value: _verbose,
              onChanged: (v) => setState(() => _verbose = v),
            ),
            TryConnectionButton(
              buttonKey: const Key('editTryConnectionButton'),
              testing: _tryTesting,
              okMessage: _tryOk,
              errorMessage: _tryErr,
              onPressed: _hasStoredPassword || _passwordCtrl.text.isNotEmpty
                  ? _tryConnection
                  : null,
            ),
            const SizedBox(height: AppSpacing.sm),
            FilledButton(
              onPressed: _hasStoredPassword || _passwordCtrl.text.isNotEmpty
                  ? _save
                  : null,
              child: const Text('Save'),
            ),
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
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: TextFormField(
        key: key,
        controller: ctrl,
        obscureText: obscure,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        validator: validator ??
            (required
                ? (v) => (v == null || v.trim().isEmpty) ? 'Required' : null
                : null),
      ),
    );
  }
}
