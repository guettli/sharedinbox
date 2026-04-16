import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../di.dart';

class AccountListScreen extends ConsumerWidget {
  const AccountListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountsAsync = ref.watch(
      accountRepositoryProvider.select(
        (r) => r.observeAccounts(),
      ).stream,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('SharedInbox'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: StreamBuilder(
        stream: ref.watch(accountRepositoryProvider).observeAccounts(),
        builder: (ctx, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final accounts = snap.data!;
          if (accounts.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('No accounts yet.'),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: () => context.push('/accounts/add'),
                    icon: const Icon(Icons.add),
                    label: const Text('Add account'),
                  ),
                ],
              ),
            );
          }
          return ListView.builder(
            itemCount: accounts.length,
            itemBuilder: (ctx, i) {
              final a = accounts[i];
              return ListTile(
                leading: const Icon(Icons.account_circle),
                title: Text(a.displayName),
                subtitle: Text(a.email),
                onTap: () =>
                    context.push('/accounts/${a.id}/mailboxes'),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push('/accounts/add'),
        child: const Icon(Icons.add),
      ),
    );
  }
}
