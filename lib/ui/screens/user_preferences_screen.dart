import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/user_preferences.dart';
import 'package:sharedinbox/core/sync/background_sync.dart';
import 'package:sharedinbox/di.dart';

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
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    const Text('Cache size limit:'),
                    const SizedBox(width: 16),
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
              const SizedBox(height: 8),
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
