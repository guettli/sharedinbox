import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/di.dart';

class AccountListScreen extends ConsumerWidget {
  const AccountListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SharedInbox'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search all accounts',
            onPressed: () => context.push('/search'),
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
    final health = ref.watch(syncHealthProvider(account.id));
    final typeLabel = account.type == AccountType.jmap ? 'JMAP' : 'IMAP';

    return ListTile(
      leading: const Icon(Icons.account_circle),
      title: Text(account.displayName),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${account.email}\n$typeLabel'),
          const SizedBox(height: 4),
          health.when(
            data: (h) {
              if (h == null) return const Text('Sync health: Not verified yet');
              final date = h.lastVerifiedAt.toLocal().toString().split('.')[0];
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Sync health: '),
                  Icon(
                    h.isHealthy ? Icons.verified : Icons.warning_amber,
                    size: 14,
                    color: h.isHealthy ? Colors.green : Colors.orange,
                  ),
                  const SizedBox(width: 4),
                  Text(h.isHealthy ? 'Healthy' : 'Discrepancies found'),
                  Text(' ($date)', style: const TextStyle(fontSize: 10)),
                ],
              );
            },
            loading: () => const Text('Sync health: checking...'),
            error: (e, _) => Text('Sync health error: $e'),
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
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: _AccountAction.syncLog,
                child: Text('Sync log'),
              ),
              const PopupMenuItem(
                value: _AccountAction.verifySync,
                child: Text('Verify sync health'),
              ),
              const PopupMenuItem(
                value: _AccountAction.edit,
                child: Text('Edit'),
              ),
              if (_sieveSupported(account))
                const PopupMenuItem(
                  value: _AccountAction.emailFilters,
                  child: Text('Email filters'),
                ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: _AccountAction.delete,
                child: Text('Delete'),
              ),
            ],
          ),
        ],
      ),
      onTap: () => context.push('/accounts/${account.id}/mailboxes'),
    );
  }

  Future<void> _onAction(BuildContext context, _AccountAction action) async {
    switch (action) {
      case _AccountAction.syncLog:
        await context.push('/accounts/${account.id}/sync-log');
        break;
      case _AccountAction.verifySync:
        unawaited(
          ProviderScope.containerOf(context)
              .read(reliabilityRunnerProvider)
              .checkNow(),
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Starting sync verification...')),
          );
        }
        break;
      case _AccountAction.edit:
        await context.push('/accounts/${account.id}/edit');
        break;
      case _AccountAction.emailFilters:
        await context.push('/accounts/${account.id}/sieve');
        break;
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

enum _AccountAction { syncLog, verifySync, edit, emailFilters, delete }

/// Whether to surface the "Email filters" (Sieve) entry for [account].
///
/// JMAP accounts always show it (Sieve over JMAP, no separate probe).
/// IMAP accounts hide it only when a previous ManageSieve probe failed
/// (manageSieveAvailable == false). Null means "not yet probed" — we
/// optimistically show it and let the menu disappear once the probe lands.
bool _sieveSupported(Account account) {
  if (account.type == AccountType.jmap) return true;
  return account.manageSieveAvailable != false;
}
