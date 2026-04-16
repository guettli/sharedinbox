import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(accountRepositoryProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: StreamBuilder(
        stream: repo.observeAccounts(),
        builder: (ctx, snap) {
          final accounts = snap.data ?? [];
          return ListView(
            children: [
              const ListTile(
                title: Text(
                  'Accounts',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              for (final a in accounts)
                ListTile(
                  leading: const Icon(Icons.account_circle),
                  title: Text(a.displayName),
                  subtitle: Text(a.email),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete),
                    onPressed: () async {
                      final confirm = await showDialog<bool>(
                        context: ctx,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Remove account?'),
                          content: Text(
                            'Remove ${a.displayName}? Local data will be deleted.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('Cancel'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('Remove'),
                            ),
                          ],
                        ),
                      );
                      if (confirm == true) {
                        await repo.removeAccount(a.id);
                      }
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
