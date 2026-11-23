import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:sharedinbox/core/encrypted_objects/recovery_key.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/user_preferences.dart';
import 'package:sharedinbox/core/services/encrypted_key_service.dart';
import 'package:sharedinbox/core/utils/format_utils.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';

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
        PersonalDataStatus.unlocked => const _UnlockedView(foreign: false),
        PersonalDataStatus.foreignKeyWarning =>
          const _UnlockedView(foreign: true),
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

/// The text field of a step and its inline error.
mixin _TextInput<T extends StatefulWidget> on State<T> {
  final controller = TextEditingController();
  String? error;

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
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
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
        const SizedBox(height: AppSpacing.lg),
        TextField(
          key: const Key('recoveryKeyField'),
          controller: controller,
          autocorrect: false,
          enabled: !_busy,
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
          onPressed: _busy ? null : _unlock,
          child: const Text('Unlock'),
        ),
        if (_busy) ...[
          const SizedBox(height: AppSpacing.lg),
          const Center(child: CircularProgressIndicator()),
        ],
        const SizedBox(height: AppSpacing.xl),
        const OutlinedButton(
          onPressed: null,
          child: Text('Pair with another device (coming soon)'),
        ),
        const SizedBox(height: AppSpacing.sm),
        const OutlinedButton(
          onPressed: null,
          child: Text('Passphrase (coming soon)'),
        ),
      ],
    );
  }

  Future<void> _unlock() async {
    setState(() {
      _busy = true;
      error = null;
    });
    String? failure;
    try {
      await ref
          .read(encryptedKeyServiceProvider)
          .unlockWithRecoveryKey(widget.accountId, controller.text);
    } on UnlockFailed catch (e) {
      failure = switch (e.reason) {
        UnlockFailure.badFormat =>
          'This is not a recovery key: it has 32 characters in 8 groups '
              'of 4.',
        UnlockFailure.badChecksum =>
          'This recovery key has a typo. Check every group.',
        UnlockFailure.noSlotOpens =>
          'This recovery key does not unlock the data of this account.',
      };
    } catch (e) {
      failure = 'Could not unlock: ${userErrorMessage(e)}';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      error = failure;
    });
  }
}

class _UnlockedView extends StatelessWidget {
  const _UnlockedView({required this.foreign});

  final bool foreign;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        if (foreign)
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
      ],
    );
  }
}
