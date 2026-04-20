import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/account.dart';
import '../../di.dart';

class AccountListScreen extends ConsumerWidget {
  const AccountListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
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
            itemBuilder: (ctx, i) => _AccountTile(account: accounts[i]),
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

class _AccountTile extends ConsumerWidget {
  const _AccountTile({required this.account});

  final Account account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(accountConnectionStatusProvider(account.id));
    final typeLabel = account.type == AccountType.jmap ? 'JMAP' : 'IMAP';

    return ListTile(
      leading: const Icon(Icons.account_circle),
      title: Text(account.displayName),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(account.email),
          Text(
            typeLabel,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
      isThreeLine: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          status.when(
            loading: () => const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            data: (_) => const Icon(Icons.check_circle, color: Colors.green),
            error: (e, _) => Tooltip(
              message: e.toString(),
              child: const Icon(Icons.error_outline, color: Colors.red),
            ),
          ),
          PopupMenuButton<_AccountAction>(
            onSelected: (action) => _onAction(context, action),
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: _AccountAction.allMailboxes,
                child: Text('All mailboxes'),
              ),
              PopupMenuItem(
                value: _AccountAction.edit,
                child: Text('Edit'),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: _AccountAction.delete,
                child: Text('Delete'),
              ),
            ],
          ),
        ],
      ),
      onTap: () => context.push(
        '/accounts/${account.id}/mailboxes/${Uri.encodeComponent('INBOX')}/emails',
      ),
    );
  }

  Future<void> _onAction(BuildContext context, _AccountAction action) async {
    switch (action) {
      case _AccountAction.allMailboxes:
        await context.push('/accounts/${account.id}/mailboxes');
      case _AccountAction.edit:
        await context.push('/accounts/${account.id}/edit');
      case _AccountAction.delete:
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Delete account'),
            content: Text(
              'Remove "${account.displayName}" (${account.email})? This cannot be undone.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if ((confirmed ?? false) && context.mounted) {
          await ProviderScope.containerOf(context)
              .read(accountRepositoryProvider)
              .removeAccount(account.id);
        }
    }
  }
}

enum _AccountAction { allMailboxes, edit, delete }
