import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:sharedinbox/core/encrypted_objects/pairing.dart';
import 'package:sharedinbox/core/encrypted_objects/passkey_slot.dart';
import 'package:sharedinbox/core/encrypted_objects/passphrase.dart';
import 'package:sharedinbox/core/encrypted_objects/recovery_key.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/user_preferences.dart';
import 'package:sharedinbox/core/services/encrypted_key_service.dart';
import 'package:sharedinbox/core/utils/format_utils.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';
import 'package:sharedinbox/ui/widgets/qr_scanner_view.dart';

/// Setup and unlock of the encrypted personal data of one account
/// (`ENCRYPTED-OBJECTS.md` 9), behind the "Personal data (beta)" switch.
class PersonalDataScreen extends ConsumerStatefulWidget {
  const PersonalDataScreen({super.key, required this.accountId});

  final String accountId;

  @override
  ConsumerState<PersonalDataScreen> createState() => _PersonalDataScreenState();
}

class _PersonalDataScreenState extends ConsumerState<PersonalDataScreen> {
  /// The key this device just created: shown until the user confirmed it.
  KeyCreated? _created;
  bool _busy = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountByIdProvider(widget.accountId)).value;
    final prefs =
        ref.watch(userPreferencesProvider).value ?? const UserPreferences();
    return Scaffold(
      appBar: AppBar(title: const Text('Personal data (beta)')),
      body: _body(context, account, prefs),
    );
  }

  Widget _body(BuildContext context, Account? account, UserPreferences prefs) {
    if (!prefs.personalDataBeta) {
      return const _Message(
        'Turn on "Personal data (beta)" in Preferences to use encrypted '
        'personal data.',
      );
    }
    if (account?.type == AccountType.jmap) {
      return const _Message(
        'Encrypted personal data is not supported for JMAP accounts yet.',
      );
    }
    final created = _created;
    if (created != null) {
      return _RecoveryKeyFlow(
        formatted: created.formatted,
        onDone: () => setState(() => _created = null),
      );
    }
    final status = ref.watch(personalDataStatusProvider(widget.accountId));
    return status.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _Message('Error: ${userErrorMessage(e)}'),
      data: (s) => switch (s) {
        PersonalDataStatus.notSetUp => _SetupIntro(
            busy: _busy,
            error: _error,
            onGenerate: _generate,
          ),
        PersonalDataStatus.setupInterrupted => _SetupIntro(
            busy: _busy,
            error: _error,
            interrupted: true,
            onGenerate: _generate,
          ),
        PersonalDataStatus.locked =>
          _UnlockView(accountId: widget.accountId, lostRace: false),
        PersonalDataStatus.lostRace =>
          _UnlockView(accountId: widget.accountId, lostRace: true),
        PersonalDataStatus.unlocked =>
          _UnlockedView(accountId: widget.accountId, foreign: false),
        PersonalDataStatus.foreignKeyWarning =>
          _UnlockedView(accountId: widget.accountId, foreign: true),
      },
    );
  }

  Future<void> _generate() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(encryptedKeyServiceProvider)
          .createKey(widget.accountId);
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (result is KeyCreated) _created = result;
      });
      if (result is KeyAlreadyExists) {
        context.showAppSnackBar(
          'Another device already set up encryption for this account — '
          'enter its recovery key.',
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not set up the key: ${userErrorMessage(e)}';
      });
    }
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Text(text, textAlign: TextAlign.center),
        ),
      );
}

class _ErrorText extends StatelessWidget {
  const _ErrorText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.sm),
        child: Text(
          text,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      );
}

/// Step 1 of the setup: what it means, then "Generate key".
class _SetupIntro extends StatelessWidget {
  const _SetupIntro({
    required this.busy,
    required this.error,
    required this.onGenerate,
    this.interrupted = false,
  });

  final bool busy;
  final String? error;
  final bool interrupted;
  final VoidCallback onGenerate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        Text('Encrypted personal data', style: theme.textTheme.titleLarge),
        const SizedBox(height: AppSpacing.sm),
        const Text(
          'Notes, todos and flash cards are stored on your own mail server, '
          'end-to-end encrypted: the server cannot read them.\n\n'
          'You get a recovery key to unlock them on other devices. If you '
          'lose every way to unlock them, the data is lost.',
        ),
        if (interrupted) ...[
          const SizedBox(height: AppSpacing.lg),
          const Text(
            'The setup on this device was interrupted. Continue it to check '
            'whether another device was first and to get a recovery key.',
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        FilledButton(
          key: const Key('personalDataGenerate'),
          onPressed: busy ? null : onGenerate,
          child: Text(interrupted ? 'Continue setup' : 'Generate key'),
        ),
        if (busy) ...[
          const SizedBox(height: AppSpacing.lg),
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: AppSpacing.sm),
          const Text(
            'Creating the key and checking that no other device was first…',
            textAlign: TextAlign.center,
          ),
        ],
        if (error != null) _ErrorText(error!),
      ],
    );
  }
}

/// The text field of a step, its inline error and whether it is busy.
mixin _TextInput<T extends StatefulWidget> on State<T> {
  final controller = TextEditingController();
  String? error;
  bool busy = false;

  /// Runs [action] with the step busy and shows the error text it returns
  /// (null on success). Returns that text.
  Future<String?> runBusy(Future<String?> Function() action) async {
    setState(() {
      busy = true;
      error = null;
    });
    final failure = await action();
    if (mounted) {
      setState(() {
        busy = false;
        error = failure;
      });
    }
    return failure;
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }
}

/// Steps 2 and 3 of the setup: show the recovery key, then confirm it by
/// typing its last group.
class _RecoveryKeyFlow extends StatefulWidget {
  const _RecoveryKeyFlow({required this.formatted, required this.onDone});

  final String formatted;
  final VoidCallback onDone;

  @override
  State<_RecoveryKeyFlow> createState() => _RecoveryKeyFlowState();
}

class _RecoveryKeyFlowState extends State<_RecoveryKeyFlow> with _TextInput {
  bool _confirming = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_confirming) {
      return ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          Text(
            'Type the last group of the recovery key to confirm you saved it.',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.lg),
          TextField(
            key: const Key('recoveryKeyConfirmField'),
            controller: controller,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'Last group',
              errorText: error,
            ),
            onSubmitted: (_) => _confirm(),
          ),
          const SizedBox(height: AppSpacing.lg),
          FilledButton(
            key: const Key('recoveryKeyConfirm'),
            onPressed: _confirm,
            child: const Text('Done'),
          ),
          TextButton(
            onPressed: () => setState(() {
              _confirming = false;
              error = null;
            }),
            child: const Text('Show the recovery key again'),
          ),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        Text('Your recovery key', style: theme.textTheme.titleLarge),
        const SizedBox(height: AppSpacing.sm),
        const Text(
          'Write it down or print it and keep it safe. It is shown only now. '
          'You need it to unlock your data on another device.',
        ),
        const SizedBox(height: AppSpacing.lg),
        SelectableText(
          widget.formatted,
          key: const Key('recoveryKeyText'),
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium?.copyWith(
            fontFamily: 'monospace',
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Center(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.copy),
            label: const Text('Copy'),
            onPressed: () {
              unawaited(
                Clipboard.setData(ClipboardData(text: widget.formatted)),
              );
              context.showAppSnackBar('Recovery key copied to clipboard');
            },
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Center(
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.all(AppSpacing.sm),
            child: QrImageView(
              key: const Key('recoveryKeyQrCode'),
              data: widget.formatted,
              size: 200,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        FilledButton(
          key: const Key('recoveryKeySaved'),
          onPressed: () => setState(() => _confirming = true),
          child: const Text('I saved it'),
        ),
      ],
    );
  }

  void _confirm() {
    final lastGroup = widget.formatted.split('-').last;
    if (normalizeRecoveryInput(controller.text) != lastGroup) {
      setState(() => error = 'This does not match the last group.');
      return;
    }
    widget.onDone();
  }
}

/// "New device": unlock with the recovery key (4.2, section 9).
class _UnlockView extends ConsumerStatefulWidget {
  const _UnlockView({required this.accountId, required this.lostRace});

  final String accountId;
  final bool lostRace;

  @override
  ConsumerState<_UnlockView> createState() => _UnlockViewState();
}

class _UnlockViewState extends ConsumerState<_UnlockView> with _TextInput {
  bool _pairing = false;

  @override
  Widget build(BuildContext context) {
    if (_pairing) {
      return _PairReceiveView(
        accountId: widget.accountId,
        onCancel: () => setState(() => _pairing = false),
      );
    }
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        Text('Unlock', style: theme.textTheme.titleLarge),
        const SizedBox(height: AppSpacing.sm),
        Text(
          widget.lostRace
              ? 'Another device set up encryption first — enter its recovery '
                  'key.'
              : 'Encrypted personal data exists for this account. Enter the '
                  'recovery key to use it on this device.',
        ),
        _PasskeyUnlock(accountId: widget.accountId, enabled: !busy),
        const SizedBox(height: AppSpacing.lg),
        TextField(
          key: const Key('recoveryKeyField'),
          controller: controller,
          autocorrect: false,
          enabled: !busy,
          style: const TextStyle(fontFamily: 'monospace'),
          decoration: InputDecoration(
            labelText: 'Recovery key',
            hintText: 'XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX',
            errorText: error,
          ),
          onSubmitted: (_) => _unlock(),
        ),
        const SizedBox(height: AppSpacing.lg),
        FilledButton(
          key: const Key('recoveryKeyUnlock'),
          onPressed: busy ? null : _unlock,
          child: const Text('Unlock'),
        ),
        if (busy) ...[
          const SizedBox(height: AppSpacing.lg),
          const Center(child: CircularProgressIndicator()),
        ],
        const SizedBox(height: AppSpacing.xl),
        OutlinedButton(
          key: const Key('pairReceiveStart'),
          onPressed: busy ? null : () => setState(() => _pairing = true),
          child: const Text('Pair with another device'),
        ),
        _PassphraseUnlock(accountId: widget.accountId, enabled: !busy),
      ],
    );
  }

  Future<void> _unlock() async {
    await runBusy(() async {
      try {
        await ref
            .read(encryptedKeyServiceProvider)
            .unlockWithRecoveryKey(widget.accountId, controller.text);
        return null;
      } on UnlockFailed catch (e) {
        return switch (e.reason) {
          UnlockFailure.badFormat =>
            'This is not a recovery key: it has 32 characters in 8 groups '
                'of 4.',
          UnlockFailure.badChecksum =>
            'This recovery key has a typo. Check every group.',
          _ => 'This recovery key does not unlock the data of this account.',
        };
      } catch (e) {
        return 'Could not unlock: ${userErrorMessage(e)}';
      }
    });
  }
}

const _noPrf = 'Your password manager does not support passkey encryption '
    '(PRF). Use the recovery key. You can delete the passkey that was just '
    'created in your password manager.';

/// Locked device: unlock with a passkey, shown only where there are
/// passkeys and the account has a passkey slot.
class _PasskeyUnlock extends ConsumerStatefulWidget {
  const _PasskeyUnlock({required this.accountId, required this.enabled});

  final String accountId;
  final bool enabled;

  @override
  ConsumerState<_PasskeyUnlock> createState() => _PasskeyUnlockState();
}

class _PasskeyUnlockState extends ConsumerState<_PasskeyUnlock> {
  late final Future<bool> _hasSlot = _loadHasSlot();
  bool _busy = false;
  String? _error;

  EncryptedKeyService get _service => ref.read(encryptedKeyServiceProvider);

  Future<bool> _loadHasSlot() async {
    if (!_service.passkeysAvailable) return false;
    return (await _service.passkeySlots(widget.accountId)).isNotEmpty;
  }

  Future<void> _unlock() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    String? failure;
    try {
      await _service.unlockWithPasskey(widget.accountId);
    } on UnlockFailed catch (e) {
      failure = switch (e.reason) {
        UnlockFailure.passkeyCancelled => 'Cancelled.',
        UnlockFailure.passkeyUnsupported =>
          'Your password manager does not support passkey encryption (PRF). '
              'Use the recovery key.',
        UnlockFailure.noPasskeySlot =>
          'This account has no passkey. Use the recovery key.',
        _ => 'None of your passkeys unlocks the data of this account. If you '
            'deleted the passkey, use the recovery key.',
      };
    } catch (e) {
      failure = 'Could not unlock: ${userErrorMessage(e)}';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = failure;
    });
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
        future: _hasSlot,
        builder: (context, snapshot) {
          if (snapshot.data != true) return const SizedBox.shrink();
          final error = _error;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: AppSpacing.lg),
              FilledButton.icon(
                key: const Key('passkeyUnlock'),
                icon: const Icon(Icons.key),
                label: const Text('Unlock with passkey'),
                onPressed: widget.enabled && !_busy ? _unlock : null,
              ),
              if (_busy) ...[
                const SizedBox(height: AppSpacing.lg),
                const Center(child: CircularProgressIndicator()),
              ],
              if (error != null) _ErrorText(error),
            ],
          );
        },
      );
}

/// The text of a passphrase [checkPassphraseStrength] refused.
String _weaknessText(PassphraseWeakness weakness) => switch (weakness) {
      PassphraseWeakness.tooShort =>
        'Use at least $minPassphraseLength characters.',
      PassphraseWeakness.common => 'This is a common password.',
      PassphraseWeakness.repetitive =>
        'Avoid repeats and sequences like 1234 or qwerty.',
      PassphraseWeakness.containsAccountName =>
        'Do not use your email address or username.',
    };

const _needsConnection =
    'Changing the passphrase needs a connection to the mail server.';

/// Locked device: unlock with the passphrase, shown only if the account
/// has a passphrase slot.
class _PassphraseUnlock extends ConsumerStatefulWidget {
  const _PassphraseUnlock({required this.accountId, required this.enabled});

  final String accountId;
  final bool enabled;

  @override
  ConsumerState<_PassphraseUnlock> createState() => _PassphraseUnlockState();
}

class _PassphraseUnlockState extends ConsumerState<_PassphraseUnlock>
    with _TextInput {
  late final Future<bool> _hasSlot =
      ref.read(encryptedKeyServiceProvider).hasPassphraseSlot(widget.accountId);

  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
        future: _hasSlot,
        builder: (context, snapshot) {
          if (snapshot.data != true) return const SizedBox.shrink();
          final enabled = widget.enabled && !busy;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: AppSpacing.xl),
              TextField(
                key: const Key('passphraseField'),
                controller: controller,
                autocorrect: false,
                enableSuggestions: false,
                obscureText: true,
                enabled: enabled,
                decoration: InputDecoration(
                  labelText: 'Passphrase',
                  errorText: error,
                ),
                onSubmitted: (_) => _unlock(),
              ),
              const SizedBox(height: AppSpacing.sm),
              OutlinedButton(
                key: const Key('passphraseUnlock'),
                onPressed: enabled ? _unlock : null,
                child: const Text('Unlock with passphrase'),
              ),
              if (busy) ...[
                const SizedBox(height: AppSpacing.lg),
                const Center(child: CircularProgressIndicator()),
              ],
            ],
          );
        },
      );

  Future<void> _unlock() async {
    await runBusy(() async {
      try {
        await ref
            .read(encryptedKeyServiceProvider)
            .unlockWithPassphrase(widget.accountId, controller.text);
        return null;
      } on UnlockFailed {
        return 'This passphrase does not unlock the data of this account.';
      } catch (e) {
        return 'Could not unlock: ${userErrorMessage(e)}';
      }
    });
  }
}

class _UnlockedView extends ConsumerStatefulWidget {
  const _UnlockedView({required this.accountId, required this.foreign});

  final String accountId;
  final bool foreign;

  @override
  ConsumerState<_UnlockedView> createState() => _UnlockedViewState();
}

class _UnlockedViewState extends ConsumerState<_UnlockedView> {
  bool _sending = false;
  late Future<bool> _hasPassphrase = _loadHasPassphrase();

  EncryptedKeyService get _service => ref.read(encryptedKeyServiceProvider);

  late Future<List<PasskeySlotInfo>> _passkeys = _loadPasskeys();

  Future<bool> _loadHasPassphrase() =>
      _service.hasPassphraseSlot(widget.accountId);

  Future<List<PasskeySlotInfo>> _loadPasskeys() async {
    if (!_service.passkeysAvailable) return const [];
    return _service.passkeySlots(widget.accountId);
  }

  void _reload() {
    final hasPassphrase = _loadHasPassphrase();
    final passkeys = _loadPasskeys();
    setState(() {
      _hasPassphrase = hasPassphrase;
      _passkeys = passkeys;
    });
  }

  Future<void> _addPasskey() async {
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => _PasskeyDialog(accountId: widget.accountId),
    );
    if (!mounted || done != true) return;
    _reload();
    context.showAppSnackBar('Passkey added');
  }

  Future<void> _removePasskey(PasskeySlotInfo passkey) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this passkey?'),
        content: const Text(
          'It no longer unlocks the data. This device and the recovery key '
          'keep working. Removing does not revoke it: old copies of the key '
          'mail may stay on the server or in backups and still open with the '
          'passkey. You can also delete it in your password manager.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('passkeyRemoveConfirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _service.removePasskeySlot(widget.accountId, passkey.slotIdB64);
      if (!mounted) return;
      _reload();
      context.showAppSnackBar('Passkey removed');
    } on KeyMailOfflineException {
      if (!mounted) return;
      context.showAppSnackBar(_passkeyNeedsConnection);
    } catch (e) {
      if (!mounted) return;
      context.showAppSnackBar(
        'Could not remove the passkey: ${userErrorMessage(e)}',
      );
    }
  }

  Widget _passkeySection(BuildContext context) =>
      FutureBuilder<List<PasskeySlotInfo>>(
        future: _passkeys,
        builder: (context, snapshot) {
          final passkeys = snapshot.data;
          if (passkeys == null) return const SizedBox.shrink();
          return Column(
            key: const Key('passkeySection'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const ListTile(
                leading: Icon(Icons.key),
                title: Text('Passkeys'),
                subtitle: Text(
                  'Deleting this passkey from your password manager removes '
                  'this way to unlock. Keep your recovery key.',
                ),
              ),
              for (final p in passkeys)
                ListTile(
                  key: Key('passkeySlot-${p.slotIdB64}'),
                  title: Text(p.label.isEmpty ? 'Passkey' : p.label),
                  trailing: IconButton(
                    key: Key('passkeyRemove-${p.slotIdB64}'),
                    tooltip: 'Remove',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _removePasskey(p),
                  ),
                ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const Key('passkeyAdd'),
                  onPressed: _addPasskey,
                  child: const Text('Add passkey'),
                ),
              ),
            ],
          );
        },
      );

  Future<void> _setPassphrase({required bool change}) async {
    final account = ref.read(accountByIdProvider(widget.accountId)).value;
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => _PassphraseDialog(
        accountId: widget.accountId,
        change: change,
        accountNames: account == null ? const [] : passphraseContext(account),
      ),
    );
    if (!mounted || done != true) return;
    _reload();
    context.showAppSnackBar(change ? 'Passphrase changed' : 'Passphrase added');
  }

  Future<void> _removePassphrase() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove the passphrase?'),
        content: const Text(
          'This device and the recovery key keep working. Removing the '
          'passphrase does not revoke it: old copies of the key mail may '
          'stay on the server or in backups and still open with it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('passphraseRemoveConfirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _service.removePassphraseSlot(widget.accountId);
      if (!mounted) return;
      _reload();
      context.showAppSnackBar('Passphrase removed');
    } on KeyMailOfflineException {
      if (!mounted) return;
      context.showAppSnackBar(_needsConnection);
    } catch (e) {
      if (!mounted) return;
      context.showAppSnackBar(
        'Could not remove the passphrase: ${userErrorMessage(e)}',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_sending) {
      return _PairSendView(
        accountId: widget.accountId,
        onDone: () => setState(() => _sending = false),
      );
    }
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        if (widget.foreign)
          MaterialBanner(
            key: const Key('foreignKeyWarning'),
            leading: Icon(
              Icons.warning_amber_rounded,
              color: theme.colorScheme.error,
            ),
            content: const Text(
              'The server has a key of another setup for this account. This '
              'device keeps using its own key. If you did not set up '
              'encryption on another device, someone may have tampered with '
              'the server.',
            ),
            actions: const [SizedBox.shrink()],
          ),
        const ListTile(
          leading: Icon(Icons.lock_open),
          title: Text('Unlocked on this device'),
          subtitle: Text(
            'Encrypted personal data of this account can be read and written '
            'here.',
          ),
        ),
        ListTile(
          key: const Key('entriesTile'),
          leading: const Icon(Icons.notes),
          title: const Text('Entries'),
          subtitle: const Text('Notes, todos and journal'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/accounts/${widget.accountId}/entries'),
        ),
        _LegacyNotesCard(accountId: widget.accountId),
        const SizedBox(height: AppSpacing.lg),
        OutlinedButton.icon(
          key: const Key('pairSendStart'),
          icon: const Icon(Icons.devices),
          label: const Text('Pair a new device'),
          onPressed: () => setState(() => _sending = true),
        ),
        const SizedBox(height: AppSpacing.lg),
        FutureBuilder<bool>(
          future: _hasPassphrase,
          builder: (context, snapshot) {
            final has = snapshot.data;
            if (has == null) return const SizedBox.shrink();
            return ListTile(
              key: const Key('passphraseTile'),
              leading: const Icon(Icons.password),
              title: const Text('Passphrase'),
              subtitle: Text(
                has
                    ? 'Other devices can unlock with the passphrase.'
                    : 'Optional: unlock other devices with a passphrase.',
              ),
              trailing: has
                  ? Wrap(
                      children: [
                        TextButton(
                          key: const Key('passphraseChange'),
                          onPressed: () => _setPassphrase(change: true),
                          child: const Text('Change'),
                        ),
                        TextButton(
                          key: const Key('passphraseRemove'),
                          onPressed: _removePassphrase,
                          child: const Text('Remove'),
                        ),
                      ],
                    )
                  : TextButton(
                      key: const Key('passphraseAdd'),
                      onPressed: () => _setPassphrase(change: false),
                      child: const Text('Add a passphrase'),
                    ),
            );
          },
        ),
        if (_service.passkeysAvailable) _passkeySection(context),
      ],
    );
  }
}

/// Offers to move the account's plaintext email notes into encrypted
/// entries, once the user read the warning (ENCRYPTED-OBJECTS.md 9,
/// #1375). Shown while synced legacy notes wait for that confirmation.
class _LegacyNotesCard extends ConsumerWidget {
  const _LegacyNotesCard({required this.accountId});

  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n =
        ref.watch(legacyNotesAwaitingConfirmationProvider(accountId)).value ??
            0;
    if (n == 0) return const SizedBox.shrink();
    return Card(
      key: const Key('legacyNotesCard'),
      child: ListTile(
        leading: const Icon(Icons.sticky_note_2_outlined),
        title: Text(
          'Move $n email ${n == 1 ? 'note' : 'notes'} into encrypted entries',
        ),
        subtitle: const Text(
          'Notes on mails are stored unencrypted in the "Notes" folder.',
        ),
        trailing: TextButton(
          key: const Key('legacyNotesMove'),
          onPressed: () => unawaited(_confirm(context, ref)),
          child: const Text('Move'),
        ),
      ),
    );
  }

  Future<void> _confirm(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Encrypt email notes?'),
        content: const Text(
          'Each note becomes an encrypted entry linked to its mail, and the '
          'unencrypted copy is deleted from the server.\n\n'
          '• Older SharedInbox versions on other devices will no longer see '
          'these notes.\n'
          '• Your mail provider may keep copies of the deleted notes for a '
          'while (e.g. Gmail "All Mail" and Trash, Exchange "Recoverable '
          'Items").\n'
          '• The "Notes" folder and other mail in it (e.g. Apple Notes) are '
          'left alone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('legacyNotesConfirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Move notes'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(legacyNoteMigrationProvider).confirm(accountId);
    ref.read(syncNowProvider)(accountId);
  }
}

const _passkeyNeedsConnection =
    'Changing the passkeys needs a connection to the mail server.';

/// Add a passkey slot: an optional label, then the password manager's
/// dialogs (create, then use the new passkey once).
class _PasskeyDialog extends ConsumerStatefulWidget {
  const _PasskeyDialog({required this.accountId});

  final String accountId;

  @override
  ConsumerState<_PasskeyDialog> createState() => _PasskeyDialogState();
}

class _PasskeyDialogState extends ConsumerState<_PasskeyDialog>
    with _TextInput {
  Future<void> _save() async {
    final failure = await runBusy(() async {
      try {
        await ref
            .read(encryptedKeyServiceProvider)
            .addPasskeySlot(widget.accountId, label: controller.text);
        return null;
      } on PrfUnsupported {
        return _noPrf;
      } on PrfCancelled {
        return 'Cancelled. Nothing was saved. If a passkey was created, you '
            'can delete it in your password manager.';
      } on KeyMailOfflineException {
        return _passkeyNeedsConnection;
      } catch (e) {
        return 'Could not add the passkey: ${userErrorMessage(e)}';
      }
    });
    if (failure != null || !mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Add passkey'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Other devices with this password manager can then unlock '
                'with the passkey. Your password manager asks you twice: to '
                'create the passkey and to check that it works.',
              ),
              const SizedBox(height: AppSpacing.lg),
              TextField(
                key: const Key('passkeyLabelField'),
                controller: controller,
                enabled: !busy,
                decoration: const InputDecoration(
                  labelText: 'Name (optional)',
                  hintText: 'e.g. Google Password Manager',
                ),
                onSubmitted: (_) => busy ? null : _save(),
              ),
              if (busy) ...[
                const SizedBox(height: AppSpacing.lg),
                const Center(child: CircularProgressIndicator()),
              ],
              if (error != null) _ErrorText(error!),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('passkeySave'),
            onPressed: busy ? null : _save,
            child: const Text('Add passkey'),
          ),
        ],
      );
}

/// Add or change the passphrase slot: the brute-force warning, the
/// strength check and a confirm field.
class _PassphraseDialog extends ConsumerStatefulWidget {
  const _PassphraseDialog({
    required this.accountId,
    required this.change,
    required this.accountNames,
  });

  final String accountId;
  final bool change;

  /// What the passphrase must not contain ([passphraseContext]).
  final List<String> accountNames;

  @override
  ConsumerState<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends ConsumerState<_PassphraseDialog>
    with _TextInput {
  final _confirm = TextEditingController();

  @override
  void dispose() {
    _confirm.dispose();
    super.dispose();
  }

  PassphraseWeakness? get _weakness =>
      checkPassphraseStrength(controller.text, context: widget.accountNames);

  bool get _matches => controller.text == _confirm.text;

  Future<void> _save() async {
    final failure = await runBusy(() async {
      try {
        await ref
            .read(encryptedKeyServiceProvider)
            .addPassphraseSlot(widget.accountId, controller.text);
        return null;
      } on WeakPassphrase catch (e) {
        return _weaknessText(e.weakness);
      } on KeyMailOfflineException {
        return _needsConnection;
      } catch (e) {
        return 'Could not save the passphrase: ${userErrorMessage(e)}';
      }
    });
    if (failure != null || !mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final weakness = controller.text.isEmpty ? null : _weakness;
    final mismatch = _confirm.text.isNotEmpty && !_matches;
    final canSave =
        !busy && controller.text.isNotEmpty && _weakness == null && _matches;
    return AlertDialog(
      title: Text(widget.change ? 'Change the passphrase' : 'Add a passphrase'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              key: const Key('passphraseBruteForceWarning'),
              padding: const EdgeInsets.all(AppSpacing.sm),
              color: theme.colorScheme.errorContainer,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    color: theme.colorScheme.onErrorContainer,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      'Your mail provider stores this slot and can try '
                      'passphrases offline without limit. Use a long, unique '
                      'passphrase — 4 or more random words. The recovery key '
                      'stays the safer way.',
                      style: TextStyle(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            TextField(
              key: const Key('passphraseNewField'),
              controller: controller,
              autocorrect: false,
              enableSuggestions: false,
              obscureText: true,
              enabled: !busy,
              decoration: InputDecoration(
                labelText: 'Passphrase',
                errorText: weakness == null ? null : _weaknessText(weakness),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              key: const Key('passphraseConfirmField'),
              controller: _confirm,
              autocorrect: false,
              enableSuggestions: false,
              obscureText: true,
              enabled: !busy,
              decoration: InputDecoration(
                labelText: 'Repeat the passphrase',
                errorText: mismatch ? 'The passphrases differ.' : null,
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => canSave ? _save() : null,
            ),
            if (busy) ...[
              const SizedBox(height: AppSpacing.lg),
              const Center(child: CircularProgressIndicator()),
              const SizedBox(height: AppSpacing.sm),
              const Text(
                'Deriving the key from the passphrase…',
                textAlign: TextAlign.center,
              ),
            ],
            if (error != null) _ErrorText(error!),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('passphraseSave'),
          onPressed: canSave ? _save : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// The text of a rejected pairing request or code.
String _pairingError(PairingRejection reason) => switch (reason) {
      PairingRejection.badFormat => 'This is not a pairing code.',
      PairingRejection.unknownOrExpiredKey =>
        'This code belongs to another or an expired pairing request. Show a '
            'new code and send again.',
      PairingRejection.tampered =>
        'This code could not be decrypted. Copy it again, completely.',
      PairingRejection.expired =>
        'This code expired. Send the key again from the other device.',
      PairingRejection.wrongAccount =>
        'This code is for another account. Nothing was sent or used.',
      PairingRejection.keyMismatch =>
        'This key does not match the encrypted data of this account.',
    };

/// Monospace text with a copy button and a QR code of the same [data].
class _CodeBlock extends StatelessWidget {
  const _CodeBlock({
    required this.data,
    required this.textKey,
    required this.qrKey,
  });

  final String data;
  final Key textKey;
  final Key qrKey;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: QrImageView(key: qrKey, data: data, size: 240),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          SelectableText(
            data,
            key: textKey,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          Center(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('Copy'),
              onPressed: () {
                unawaited(Clipboard.setData(ClipboardData(text: data)));
                context.showAppSnackBar('Code copied to clipboard');
              },
            ),
          ),
        ],
      );
}

/// New device: shows the pairing request (4.2) and waits for the key — as
/// a pairing mail, checked every ~10 s, or as a pasted code.
class _PairReceiveView extends ConsumerStatefulWidget {
  const _PairReceiveView({required this.accountId, required this.onCancel});

  final String accountId;
  final VoidCallback onCancel;

  @override
  ConsumerState<_PairReceiveView> createState() => _PairReceiveViewState();
}

class _PairReceiveViewState extends ConsumerState<_PairReceiveView>
    with _TextInput {
  /// Seconds between two checks of the keys folder.
  static const _pollEvery = 10;

  PairingStart? _start;
  String? _startError;
  Timer? _tick;
  int _ticks = 0;

  EncryptedKeyService get _service => ref.read(encryptedKeyServiceProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_newCode());
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _newCode() async {
    try {
      final start = await _service.startPairing(widget.accountId);
      if (!mounted) return;
      setState(() => _start = start);
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _startError = 'Could not start pairing: ${userErrorMessage(e)}',
      );
    }
  }

  void _restart() {
    setState(() {
      _start = null;
      _startError = null;
    });
    unawaited(_newCode());
  }

  static bool _expired(PairingStart start) =>
      !start.expiresAt.isAfter(DateTime.now());

  void _onTick() {
    final start = _start;
    if (start == null) return;
    // The countdown.
    setState(() {});
    if (_expired(start) || ++_ticks % _pollEvery != 0) return;
    unawaited(_poll());
  }

  Future<void> _poll() async {
    try {
      await _service.checkPairing(widget.accountId);
    } catch (_) {
      // The next tick tries again; the status stream shows an unlock.
    }
  }

  Future<void> _accept() async {
    await runBusy(() async {
      try {
        await _service.acceptPairingCode(widget.accountId, controller.text);
        return null;
      } on PairingRejected catch (e) {
        return _pairingError(e.reason);
      } catch (e) {
        return 'Could not unlock: ${userErrorMessage(e)}';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final start = _start;
    final startError = _startError;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        Text('Pair with another device', style: theme.textTheme.titleLarge),
        const SizedBox(height: AppSpacing.sm),
        const Text(
          'On a device that is already unlocked, open "Personal data (beta)" '
          'of this account, tap "Pair a new device" and scan or paste this '
          'code. This device unlocks by itself when the key arrives.',
        ),
        const SizedBox(height: AppSpacing.lg),
        if (startError != null)
          _ErrorText(startError)
        else if (start == null)
          const Center(child: CircularProgressIndicator())
        else if (_expired(start)) ...[
          const Text('This code expired.', textAlign: TextAlign.center),
          const SizedBox(height: AppSpacing.sm),
          FilledButton(
            key: const Key('pairNewCode'),
            onPressed: _restart,
            child: const Text('New code'),
          ),
        ] else ...[
          _CodeBlock(
            data: start.request,
            textKey: const Key('pairRequestText'),
            qrKey: const Key('pairRequestQrCode'),
          ),
          Text(
            'Valid for ${_remaining(start)}',
            key: const Key('pairCountdown'),
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        const Text(
          'Or paste the code the other device shows after sending:',
        ),
        TextField(
          key: const Key('pairingCodeField'),
          controller: controller,
          autocorrect: false,
          enabled: !busy,
          style: const TextStyle(fontFamily: 'monospace'),
          decoration: InputDecoration(
            labelText: 'Pairing code',
            errorText: error,
          ),
          onSubmitted: (_) => _accept(),
        ),
        const SizedBox(height: AppSpacing.lg),
        FilledButton(
          key: const Key('pairingCodeAccept'),
          onPressed: busy ? null : _accept,
          child: const Text('Unlock'),
        ),
        TextButton(onPressed: widget.onCancel, child: const Text('Back')),
      ],
    );
  }

  static String _remaining(PairingStart start) {
    final left = start.expiresAt.difference(DateTime.now());
    final seconds = left.inSeconds % 60;
    return '${left.inMinutes}:${seconds.toString().padLeft(2, '0')}';
  }
}

/// Unlocked device: scans (Android/iOS) or takes a pasted pairing request
/// and sends the account key (4.2).
class _PairSendView extends ConsumerStatefulWidget {
  const _PairSendView({required this.accountId, required this.onDone});

  final String accountId;
  final VoidCallback onDone;

  @override
  ConsumerState<_PairSendView> createState() => _PairSendViewState();
}

class _PairSendViewState extends ConsumerState<_PairSendView> with _TextInput {
  bool _paste = false;
  String? _sentCode;

  /// Returns whether [request] was sent; a failure shows the paste form
  /// with the reason.
  Future<bool> _send(String request) async {
    String? code;
    final failure = await runBusy(() async {
      try {
        code = await ref
            .read(encryptedKeyServiceProvider)
            .sendPairing(widget.accountId, request);
        return null;
      } on PairingRejected catch (e) {
        return _pairingError(e.reason);
      } catch (e) {
        return 'Could not send the key: ${userErrorMessage(e)}';
      }
    });
    if (!mounted) return true;
    setState(() {
      _sentCode = code;
      if (failure != null) _paste = true;
    });
    return failure == null;
  }

  @override
  Widget build(BuildContext context) {
    final code = _sentCode;
    if (code != null) return _sent(context, code);
    if (_paste) return _pasteForm(context);
    return QrScannerView(
      onDetect: _send,
      fallbackBuilder: _pasteForm,
      logEvent: 'mos.pairing_scanner_failed',
      screen: 'PersonalDataScreen',
      overlayBuilder: (context) => QrScanHint(
        'Point the camera at the code the new device shows',
        action: TextButton(
          onPressed: () => setState(() => _paste = true),
          child: const Text('Paste instead'),
        ),
      ),
    );
  }

  Widget _pasteForm(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        Text('Pair a new device', style: theme.textTheme.titleLarge),
        const SizedBox(height: AppSpacing.sm),
        const Text(
          'On the new device, open "Personal data (beta)" of this account and '
          'tap "Pair with another device". Paste the code it shows here.',
        ),
        const SizedBox(height: AppSpacing.lg),
        TextField(
          key: const Key('pairingRequestField'),
          controller: controller,
          autocorrect: false,
          enabled: !busy,
          style: const TextStyle(fontFamily: 'monospace'),
          decoration: InputDecoration(
            labelText: 'Code of the new device',
            errorText: error,
          ),
          onSubmitted: (_) => _send(controller.text),
        ),
        const SizedBox(height: AppSpacing.lg),
        FilledButton(
          key: const Key('pairingSend'),
          onPressed: busy ? null : () => _send(controller.text),
          child: const Text('Send the key'),
        ),
        if (busy) ...[
          const SizedBox(height: AppSpacing.lg),
          const Center(child: CircularProgressIndicator()),
        ],
        TextButton(onPressed: widget.onDone, child: const Text('Back')),
      ],
    );
  }

  Widget _sent(BuildContext context, String code) => ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          const ListTile(
            key: Key('pairingSent'),
            leading: Icon(Icons.check_circle_outline),
            title: Text('Sent — the new device unlocks on its next sync'),
          ),
          const SizedBox(height: AppSpacing.sm),
          const Text(
            'If it does not, paste this code into "Pair with another device" '
            'on the new device. It is valid for 20 minutes.',
          ),
          const SizedBox(height: AppSpacing.lg),
          _CodeBlock(
            data: code,
            textKey: const Key('pairingCodeText'),
            qrKey: const Key('pairingCodeQrCode'),
          ),
          const SizedBox(height: AppSpacing.lg),
          FilledButton(onPressed: widget.onDone, child: const Text('Done')),
        ],
      );
}
