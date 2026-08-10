import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/user_preferences.dart';
import 'package:sharedinbox/core/storage/db_encryption.dart';
import 'package:sharedinbox/core/sync/background_sync.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';

class UserPreferencesScreen extends ConsumerWidget {
  const UserPreferencesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefsAsync = ref.watch(userPreferencesProvider);
    final trustedSendersAsync = ref.watch(trustedImageSendersProvider);
    final trustedCount = trustedSendersAsync.value?.length ?? 0;

    return Scaffold(
      appBar: AppBar(title: const Text('Preferences')),
      body: prefsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) =>
            const Center(child: Text('Error loading preferences')),
        data: (prefs) => ListView(
          children: [
            ListTile(
              title: Text(
                'Menu bar position',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              subtitle: const Text(
                'Where the folder navigation menu is shown in the mailbox view.',
              ),
            ),
            RadioGroup<MenuPosition>(
              groupValue: prefs.menuPosition,
              onChanged: (value) {
                if (value == null) return;
                unawaited(
                  ref
                      .read(userPreferencesRepositoryProvider)
                      .updateMenuPosition(value),
                );
              },
              child: const Column(
                children: [
                  RadioListTile<MenuPosition>(
                    title: Text('Bottom (default)'),
                    subtitle: Text(
                      'Open folder navigation from a button at the bottom of the screen.',
                    ),
                    value: MenuPosition.bottom,
                  ),
                  RadioListTile<MenuPosition>(
                    title: Text('Top'),
                    subtitle: Text(
                      'Open folder navigation from the hamburger icon in the top bar.',
                    ),
                    value: MenuPosition.top,
                  ),
                ],
              ),
            ),
            const Divider(),
            ListTile(
              title: Text(
                'Single mail view button position',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              subtitle: const Text(
                'Where the back button is shown in the single mail view.',
              ),
            ),
            RadioGroup<MenuPosition>(
              groupValue: prefs.mailViewButtonPosition,
              onChanged: (value) {
                if (value == null) return;
                unawaited(
                  ref
                      .read(userPreferencesRepositoryProvider)
                      .updateMailViewButtonPosition(value),
                );
              },
              child: const Column(
                children: [
                  RadioListTile<MenuPosition>(
                    title: Text('Bottom (default)'),
                    subtitle: Text(
                      'Show the back button at the bottom of the screen.',
                    ),
                    value: MenuPosition.bottom,
                  ),
                  RadioListTile<MenuPosition>(
                    title: Text('Top'),
                    subtitle: Text('Show the back button in the top bar.'),
                    value: MenuPosition.top,
                  ),
                ],
              ),
            ),
            const Divider(),
            ListTile(
              title: Text(
                'After mail action',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              subtitle: const Text(
                'What to show after deleting, archiving, or otherwise handling a message.',
              ),
            ),
            RadioGroup<AfterMailViewAction>(
              groupValue: prefs.afterMailViewAction,
              onChanged: (value) {
                if (value == null) return;
                unawaited(
                  ref
                      .read(userPreferencesRepositoryProvider)
                      .updateAfterMailViewAction(value),
                );
              },
              child: const Column(
                children: [
                  RadioListTile<AfterMailViewAction>(
                    title: Text('Next message (default)'),
                    subtitle: Text('Show the next message in the mailbox.'),
                    value: AfterMailViewAction.nextMessage,
                  ),
                  RadioListTile<AfterMailViewAction>(
                    title: Text('Return to mailbox'),
                    subtitle: Text('Return to the message list.'),
                    value: AfterMailViewAction.showMailbox,
                  ),
                ],
              ),
            ),
            const Divider(),
            ListTile(
              title: Text(
                'Offline email cache',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              subtitle: const Text(
                'Pre-fetch email bodies in the background so they are available offline.',
              ),
            ),
            RadioGroup<PrefetchMode>(
              groupValue: prefs.prefetchMode,
              onChanged: (value) {
                if (value == null) return;
                unawaited(
                  ref
                      .read(userPreferencesRepositoryProvider)
                      .updatePrefetchMode(value),
                );
                unawaited(registerBodyPrefetchTask(value));
              },
              child: const Column(
                children: [
                  RadioListTile<PrefetchMode>(
                    title: Text('Wi-Fi only (default)'),
                    subtitle: Text(
                      'Pre-fetch bodies in the background when connected to Wi-Fi.',
                    ),
                    value: PrefetchMode.wifiOnly,
                  ),
                  RadioListTile<PrefetchMode>(
                    title: Text('Any network'),
                    subtitle: Text(
                      'Pre-fetch bodies on Wi-Fi and mobile data.',
                    ),
                    value: PrefetchMode.always,
                  ),
                  RadioListTile<PrefetchMode>(
                    title: Text('Disabled'),
                    subtitle: Text(
                      'Do not pre-fetch email bodies in the background.',
                    ),
                    value: PrefetchMode.disabled,
                  ),
                ],
              ),
            ),
            if (prefs.prefetchMode != PrefetchMode.disabled) ...[
              const SizedBox(height: AppSpacing.xs),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                child: Row(
                  children: [
                    const Text('Cache size limit:'),
                    const SizedBox(width: AppSpacing.lg),
                    DropdownButton<int>(
                      value: _nearestCacheOption(prefs.bodyCacheLimitMb),
                      items: const [
                        DropdownMenuItem(value: 50, child: Text('50 MB')),
                        DropdownMenuItem(value: 100, child: Text('100 MB')),
                        DropdownMenuItem(value: 200, child: Text('200 MB')),
                        DropdownMenuItem(value: 500, child: Text('500 MB')),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        unawaited(
                          ref
                              .read(userPreferencesRepositoryProvider)
                              .updateBodyCacheLimitMb(value),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
            const Divider(),
            ListTile(
              title: Text(
                'Allowed addresses for images',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              subtitle: Text(
                trustedCount == 0
                    ? 'No addresses added yet.'
                    : '$trustedCount address${trustedCount == 1 ? '' : 'es'}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/accounts/trusted-senders'),
            ),
            const Divider(),
            ListTile(
              title: Text(
                'UnifiedPush',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              subtitle: const Text(
                'Real-time push notifications via a distributor app — no '
                'reliance on Google or Apple push services.',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/accounts/push'),
            ),
            const Divider(),
            _EncryptionSection(),
          ],
        ),
      ),
    );
  }

  int _nearestCacheOption(int mb) {
    const options = [50, 100, 200, 500];
    return options.reduce(
      (a, b) => (a - mb).abs() <= (b - mb).abs() ? a : b,
    );
  }
}

/// Local-storage encryption toggle (issue #330).
///
/// Conversion between plaintext and SQLCipher requires exclusive access to
/// the DB, so flipping the switch only stages a pending change — the actual
/// migration runs on the next app start in [initDatabasePath].
class _EncryptionSection extends ConsumerStatefulWidget {
  @override
  ConsumerState<_EncryptionSection> createState() => _EncryptionSectionState();
}

class _EncryptionSectionState extends ConsumerState<_EncryptionSection> {
  @override
  Widget build(BuildContext context) {
    final service = ref.read(dbEncryptionServiceProvider);
    final status = service.status();
    final effectiveValue = switch (status.pendingChange) {
      PendingEncryptionChange.enable => true,
      PendingEncryptionChange.disable => false,
      null => status.isEncrypted,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          title: Text(
            'Encrypt local storage',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          subtitle: const Text(
            'Encrypt the cached email database at rest with SQLCipher. '
            'The encryption key is stored in your device keystore. '
            'Toggling on or off requires an app restart and rewrites the '
            'database file.',
          ),
        ),
        SwitchListTile(
          title: Text(effectiveValue ? 'Enabled' : 'Disabled'),
          value: effectiveValue,
          onChanged: (value) {
            setState(() {
              if (value) {
                service.scheduleEnable();
              } else {
                service.scheduleDisable();
              }
            });
            if (service.status().hasPendingChange) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Restart the app to apply the new encryption setting.',
                  ),
                ),
              );
            }
          },
        ),
        if (status.hasPendingChange)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              0,
              AppSpacing.lg,
              AppSpacing.lg,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    status.pendingChange == PendingEncryptionChange.enable
                        ? 'Encryption will be enabled on next app start.'
                        : 'Encryption will be disabled on next app start.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                TextButton(
                  onPressed: () => setState(service.cancelPendingChange),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
