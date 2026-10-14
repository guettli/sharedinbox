import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/discovery_result.dart';
import 'package:sharedinbox/core/utils/host_utils.dart';
import 'package:sharedinbox/core/utils/logger.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/linkified_text.dart';
import 'package:sharedinbox/ui/widgets/try_connection_button.dart';

enum _Step { email, detecting, chooseType, jmapForm, imapForm, connecting }

class AddAccountScreen extends ConsumerStatefulWidget {
  const AddAccountScreen({super.key});

  @override
  ConsumerState<AddAccountScreen> createState() => _AddAccountScreenState();
}

class _AddAccountScreenState extends ConsumerState<AddAccountScreen> {
  var _step = _Step.email;
  String? _errorMessage;

  /// What auto-detection found, kept so switching protocol and back can
  /// restore the detected settings instead of discarding them — there is no
  /// way to re-run discovery without abandoning the whole flow.
  DiscoveryResult? _discovery;

  // -- controllers -----------------------------------------------------------
  final _emailCtrl = TextEditingController();
  final _displayNameCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _jmapApiUrlCtrl = TextEditingController();
  final _imapHostCtrl = TextEditingController();
  final _imapPortCtrl = TextEditingController(text: '993');
  final _smtpHostCtrl = TextEditingController();
  final _smtpPortCtrl = TextEditingController(text: '465');
  var _imapSsl = true;
  var _smtpSsl = true;

  // -- "Try connection" state ------------------------------------------------
  bool _tryTesting = false;
  String? _tryOk;
  String? _tryErr;

  // -- form keys -------------------------------------------------------------
  final _emailFormKey = GlobalKey<FormState>();
  final _jmapFormKey = GlobalKey<FormState>();
  final _imapFormKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _imapHostCtrl.addListener(_rebuild);
    _smtpHostCtrl.addListener(_rebuild);
  }

  void _rebuild() => setState(() {});

  @override
  void dispose() {
    _imapHostCtrl.removeListener(_rebuild);
    _smtpHostCtrl.removeListener(_rebuild);
    for (final c in [
      _emailCtrl,
      _displayNameCtrl,
      _usernameCtrl,
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
      _discovery = result;
      switch (result) {
        case JmapDiscovery(:final sessionUrl):
          _jmapApiUrlCtrl.text = sessionUrl;
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
        case UnsupportedDiscovery(:final message):
          setState(() {
            _errorMessage = message;
            _step = _Step.chooseType;
          });
        case UnknownDiscovery():
          setState(() => _step = _Step.chooseType);
      }
    } catch (e) {
      log('Account discovery failed: $e');
      if (mounted) setState(() => _step = _Step.chooseType);
    }
  }

  Account _buildJmapAccount() => Account(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        displayName: _displayNameCtrl.text.trim(),
        email: _emailCtrl.text.trim(),
        username: _usernameCtrl.text.trim(),
        type: AccountType.jmap,
        jmapUrl: _jmapApiUrlCtrl.text.trim(),
      );

  Account _buildImapAccount() {
    final imapHost = _imapHostCtrl.text.trim();
    final smtpHost = _smtpHostCtrl.text.trim();
    return Account(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      displayName: _displayNameCtrl.text.trim(),
      email: _emailCtrl.text.trim(),
      username: _usernameCtrl.text.trim(),
      imapHost: imapHost,
      imapPort: int.parse(_imapPortCtrl.text),
      imapSsl: _imapSsl,
      smtpHost: smtpHost,
      smtpPort: int.parse(_smtpPortCtrl.text),
      smtpSsl: _smtpSsl,
    );
  }

  Future<void> _tryConnection(
    GlobalKey<FormState> formKey,
    Account Function() buildAccount,
  ) async {
    if (!formKey.currentState!.validate()) return;
    setState(() {
      _tryTesting = true;
      _tryOk = null;
      _tryErr = null;
    });
    try {
      final account = buildAccount();
      final result = await ref
          .read(connectionTestServiceProvider)
          .testConnection(account, _passwordCtrl.text);
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
              screen: 'AddAccountScreen',
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

  Future<void> _saveJmap() async {
    if (!_jmapFormKey.currentState!.validate()) return;
    setState(() {
      _step = _Step.connecting;
      _errorMessage = null;
    });
    try {
      final account = _buildJmapAccount();
      final result = await ref
          .read(connectionTestServiceProvider)
          .testConnection(account, _passwordCtrl.text);
      if (result.identityWarning != null) {
        unawaited(
          ref.read(appLoggerProvider).warn(
                'account.identity_warning',
                result.identityWarning!,
                screen: 'AddAccountScreen',
              ),
        );
      }
      // Only the username may differ from the built account -- say exactly
      // that, rather than re-listing every field (which is how imapSsl once
      // went missing on the IMAP path, see #936).
      final accountToSave = account.username.isEmpty
          ? account.copyWith(username: result.username)
          : account;
      await ref
          .read(accountRepositoryProvider)
          .addAccount(accountToSave, _passwordCtrl.text);
      if (mounted) context.pop();
    } catch (e, stack) {
      unawaited(
        ref.read(appLoggerProvider).error(
              'account.add_failed',
              'Failed to add JMAP account',
              screen: 'AddAccountScreen',
              error: e,
              stack: stack,
            ),
      );
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
      final account = _buildImapAccount();
      final result = await ref
          .read(connectionTestServiceProvider)
          .testConnection(account, _passwordCtrl.text);
      // Only the username may differ from the built account. Listing the
      // fields by hand dropped imapSsl silently (#936).
      final accountToSave = account.username.isEmpty
          ? account.copyWith(username: result.username)
          : account;
      await ref
          .read(accountRepositoryProvider)
          .addAccount(accountToSave, _passwordCtrl.text);
      // Probe ManageSieve in the background; the menu starts visible (null)
      // and disappears on probe failure via the observeAccounts stream.
      unawaited(ref.read(manageSieveProbeServiceProvider).probe(accountToSave));
      if (mounted) context.pop();
    } catch (e, stack) {
      unawaited(
        ref.read(appLoggerProvider).error(
              'account.add_failed',
              'Failed to add IMAP account',
              screen: 'AddAccountScreen',
              error: e,
              stack: stack,
            ),
      );
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
        _Step.detecting => _buildSpinner('Detecting account settings\u2026'),
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
      padding: const EdgeInsets.all(AppSpacing.lg),
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
            const SizedBox(height: AppSpacing.lg),
            FilledButton(
              onPressed: _detectAccount,
              child: const Text('Continue'),
            ),
            const SizedBox(height: AppSpacing.sm),
            OutlinedButton.icon(
              key: const Key('importAccountButton'),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Receive account'),
              onPressed: () => context.push('/accounts/receive'),
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
          const SizedBox(height: AppSpacing.lg),
          Text(label),
        ],
      ),
    );
  }

  Widget _buildChooseTypeStep() {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Could not auto-detect settings for '
            '${_emailCtrl.text.trim()}.\n'
            'Choose account type:',
          ),
          const SizedBox(height: AppSpacing.xl),
          if (_errorMessage != null) _errorBanner(),
          FilledButton(
            onPressed: _useJmap,
            child: const Text('JMAP'),
          ),
          const SizedBox(height: AppSpacing.md),
          OutlinedButton(
            onPressed: _useImap,
            child: const Text('IMAP / SMTP'),
          ),
        ],
      ),
    );
  }

  /// Clears the Try-connection banner.
  ///
  /// It renders from the same three fields on both forms, directly above Save,
  /// so without this a green "Connected as …" from a JMAP test stays on screen
  /// above an empty IMAP form — a success message for a connection that was
  /// never made with the settings shown.
  void _resetTryState() {
    _tryTesting = false;
    _tryOk = null;
    _tryErr = null;
  }

  /// Switches to the JMAP form, re-seeding the detected session URL when
  /// discovery found one and clearing it otherwise.
  ///
  /// Shared by the account-type chooser and the "use JMAP instead" link so the
  /// two entry points cannot drift apart.
  void _useJmap() {
    setState(() {
      final discovery = _discovery;
      _jmapApiUrlCtrl.text =
          discovery is JmapDiscovery ? discovery.sessionUrl : '';
      _resetTryState();
      _errorMessage = null;
      _step = _Step.jmapForm;
    });
  }

  /// Switches to the IMAP/SMTP form, re-seeding the detected servers when
  /// discovery found them and falling back to the implicit-TLS defaults.
  void _useImap() {
    setState(() {
      _seedImapFields();
      _resetTryState();
      _errorMessage = null;
      _step = _Step.imapForm;
    });
  }

  void _seedImapFields() {
    final discovery = _discovery;
    if (discovery is! ImapSmtpDiscovery) {
      _imapHostCtrl.clear();
      _imapPortCtrl.text = '993';
      _imapSsl = true;
      _smtpHostCtrl.clear();
      _smtpPortCtrl.text = '465';
      _smtpSsl = true;
      return;
    }
    _imapHostCtrl.text = discovery.imapHost;
    _imapPortCtrl.text = discovery.imapPort.toString();
    _imapSsl = discovery.imapSsl;
    _smtpHostCtrl.text = discovery.smtpHost;
    _smtpPortCtrl.text = discovery.smtpPort.toString();
    _smtpSsl = discovery.smtpSsl;
  }

  Widget _buildJmapForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Form(
        key: _jmapFormKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _emailHeader(
              'JMAP',
              switchLabel: 'Use IMAP / SMTP instead',
              onSwitch: _useImap,
              switchKey: const Key('switchToImapButton'),
            ),
            if (_errorMessage != null) _errorBanner(),
            _field(_displayNameCtrl, 'Display name'),
            _field(
              _jmapApiUrlCtrl,
              'JMAP API URL',
              keyboardType: TextInputType.url,
              validator: validateJmapUrl,
            ),
            _field(
              _usernameCtrl,
              'Username (leave blank to use email)',
              required: false,
            ),
            _field(_passwordCtrl, 'Password', obscure: true),
            TryConnectionButton(
              buttonKey: const Key('tryConnectionButton'),
              testing: _tryTesting,
              okMessage: _tryOk,
              errorMessage: _tryErr,
              onPressed: () => _tryConnection(_jmapFormKey, _buildJmapAccount),
            ),
            const SizedBox(height: AppSpacing.sm),
            FilledButton(onPressed: _saveJmap, child: const Text('Save')),
          ],
        ),
      ),
    );
  }

  Widget _buildImapForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Form(
        key: _imapFormKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _emailHeader(
              'IMAP / SMTP',
              switchLabel: 'Use JMAP instead',
              onSwitch: _useJmap,
              switchKey: const Key('switchToJmapButton'),
            ),
            if (_errorMessage != null) _errorBanner(),
            _field(_displayNameCtrl, 'Display name'),
            _field(
              _usernameCtrl,
              'Username (leave blank to use email)',
              required: false,
            ),
            _field(_passwordCtrl, 'Password', obscure: true),
            const Divider(height: 32),
            Text('IMAP', style: Theme.of(context).textTheme.titleSmall),
            _field(_imapHostCtrl, 'Host', validator: validateHostname),
            _field(_imapPortCtrl, 'Port', keyboardType: TextInputType.number),
            SwitchListTile(
              key: const Key('imapSslSwitch'),
              title: const Text('SSL/TLS'),
              subtitle: const Text('Off: upgrade with STARTTLS (IMAP 143)'),
              value: _imapSsl,
              onChanged: (v) => setState(() => _imapSsl = v),
            ),
            const Divider(height: 32),
            Text('SMTP', style: Theme.of(context).textTheme.titleSmall),
            _field(_smtpHostCtrl, 'Host', validator: validateHostname),
            _field(_smtpPortCtrl, 'Port', keyboardType: TextInputType.number),
            SwitchListTile(
              key: const Key('smtpSslSwitch'),
              title: const Text('SSL/TLS'),
              subtitle: const Text('Off: upgrade with STARTTLS (SMTP 587)'),
              value: _smtpSsl,
              onChanged: (v) => setState(() => _smtpSsl = v),
            ),
            TryConnectionButton(
              buttonKey: const Key('tryConnectionButton'),
              testing: _tryTesting,
              okMessage: _tryOk,
              errorMessage: _tryErr,
              onPressed: () => _tryConnection(_imapFormKey, _buildImapAccount),
            ),
            const SizedBox(height: AppSpacing.sm),
            FilledButton(onPressed: _saveImap, child: const Text('Save')),
          ],
        ),
      ),
    );
  }

  // -- small helpers ---------------------------------------------------------

  /// Header for both protocol forms, carrying the escape hatch from whichever
  /// protocol auto-detection chose.
  ///
  /// The link lives here, beside the protocol name it contradicts, rather than
  /// under Save: both forms scroll, and on a narrow screen at a large text
  /// scale the bottom of the IMAP form sits far below the fold, which would
  /// reintroduce the discoverability problem this exists to solve.
  Widget _emailHeader(
    String accountTypeLabel, {
    String? switchLabel,
    VoidCallback? onSwitch,
    Key? switchKey,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _emailCtrl.text.trim(),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Row(
            children: [
              Flexible(
                child: Text(
                  accountTypeLabel,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (switchLabel != null)
                Flexible(
                  child: TextButton(
                    key: switchKey,
                    // Disabled mid-test: _tryConnection captures its form and
                    // builder at call time, so a result landing after a switch
                    // would report on settings that are no longer shown.
                    onPressed: _tryTesting ? null : onSwitch,
                    child: Text(switchLabel),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _errorBanner() {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: LinkifiedText(
        _errorMessage!,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
    );
  }

  Widget _field(
    TextEditingController ctrl,
    String label, {
    bool obscure = false,
    bool required = true,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: TextFormField(
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
