import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sharedinbox/core/models/user_preferences.dart';
import 'package:sharedinbox/di.dart';

class UserPreferencesScreen extends ConsumerWidget {
  const UserPreferencesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefsAsync = ref.watch(userPreferencesProvider);

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
                    subtitle: Text(
                      'Show the back button in the top bar.',
                    ),
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
                    subtitle: Text(
                      'Show the next message in the mailbox.',
                    ),
                    value: AfterMailViewAction.nextMessage,
                  ),
                  RadioListTile<AfterMailViewAction>(
                    title: Text('Return to mailbox'),
                    subtitle: Text(
                      'Return to the message list.',
                    ),
                    value: AfterMailViewAction.showMailbox,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
