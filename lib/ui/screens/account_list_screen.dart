import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/services/update_service.dart';
import 'package:sharedinbox/di.dart';
import 'package:url_launcher/url_launcher.dart';

class AccountListScreen extends ConsumerWidget {
  const AccountListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('sharedinbox.de'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search all accounts',
            onPressed: () => context.push('/search'),
          ),
        ],
      ),
      drawer: Drawer(
        child: ListView(
          children: [
            const DrawerHeader(
              decoration: BoxDecoration(color: Colors.blueGrey),
              child: Text(
                'sharedinbox.de',
                style: TextStyle(color: Colors.white, fontSize: 24),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.qr_code_scanner),
              title: const Text('Receive accounts'),
              onTap: () {
                Navigator.pop(context);
                unawaited(context.push('/accounts/receive'));
              },
            ),
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('Undo Log'),
              onTap: () {
                Navigator.pop(context); // Close drawer
                unawaited(context.push('/accounts/undo-log'));
              },
            ),
            ListTile(
              leading: const Icon(Icons.update),
              title: const Text('ChangeLog'),
              onTap: () {
                Navigator.pop(context); // Close drawer
                unawaited(context.push('/accounts/changelog'));
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('About'),
              onTap: () {
                Navigator.pop(context); // Close drawer
                unawaited(context.push('/accounts/about'));
              },
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          const _UpdateBanner(),
          Expanded(
            child: StreamBuilder(
              stream: ref.watch(accountRepositoryProvider).observeAccounts(),
              builder: (ctx, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final accounts = snap.data!;
                if (accounts.isEmpty) {
                  return const _OnboardingView();
                }
                return ListView.builder(
                  itemCount: accounts.length,
                  itemBuilder: (ctx, i) => _AccountTile(account: accounts[i]),
                );
              },
            ),
          ),
        ],
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
                value: _AccountAction.forceSync,
                child: Text('Force full sync'),
              ),
              const PopupMenuItem(
                value: _AccountAction.edit,
                child: Text('Edit'),
              ),
              if (_sieveSupported(account))
                const PopupMenuItem(
                  value: _AccountAction.emailFiltersRemote,
                  child: Text('Server email filters'),
                ),
              const PopupMenuItem(
                value: _AccountAction.emailFiltersLocal,
                child: Text('Local email filters'),
              ),
              const PopupMenuItem(
                value: _AccountAction.send,
                child: Text('Send accounts'),
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
          ProviderScope.containerOf(
            context,
          ).read(reliabilityRunnerProvider).checkNow(),
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              duration: Duration(seconds: 5),
              content: Text('Starting sync verification...'),
            ),
          );
        }
        break;
      case _AccountAction.forceSync:
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Force full sync?'),
            content: const Text(
              'This clears all locally-cached emails and mailboxes for this '
              'account and immediately re-downloads everything from the server. '
              'Previously viewed email content will not need to be re-downloaded.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Force sync'),
              ),
            ],
          ),
        );
        if (confirmed == true && context.mounted) {
          await ProviderScope.containerOf(
            context,
          ).read(syncManagerProvider).forceResync(account.id);
        }
        break;
      case _AccountAction.edit:
        await context.push('/accounts/${account.id}/edit');
        break;
      case _AccountAction.emailFiltersRemote:
        await context.push('/accounts/${account.id}/sieve');
        break;
      case _AccountAction.emailFiltersLocal:
        await context.push('/accounts/${account.id}/sieve/local');
        break;
      case _AccountAction.send:
        await context.push('/accounts/send');
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
          await ProviderScope.containerOf(
            context,
          ).read(accountRepositoryProvider).removeAccount(account.id);
        }
    }
  }
}

class _OnboardingView extends StatelessWidget {
  const _OnboardingView();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.mail_outline,
              size: 64,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              'Welcome to sharedinbox.de',
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Get started in three steps:',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            const _Step(
              number: '1',
              title: 'Add an account',
              description: 'Connect your IMAP or JMAP email account.',
            ),
            const _Step(
              number: '2',
              title: 'Wait for sync',
              description:
                  'sharedinbox.de downloads your messages in the background.',
            ),
            const _Step(
              number: '3',
              title: 'Open your inbox',
              description:
                  'Tap the account to browse mailboxes and read emails.',
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: () => context.push('/accounts/add'),
              icon: const Icon(Icons.add),
              label: const Text('Add account'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.number,
    required this.title,
    required this.description,
  });

  final String number;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: theme.colorScheme.primaryContainer,
            child: Text(
              number,
              style: TextStyle(
                color: theme.colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                Text(description, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum _AccountAction {
  syncLog,
  verifySync,
  forceSync,
  edit,
  emailFiltersRemote,
  emailFiltersLocal,
  send,
  delete,
}

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

/// Shown on Linux desktop when a newer build is available on the server.
class _UpdateBanner extends ConsumerWidget {
  const _UpdateBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final update = ref.watch(updateInfoProvider);
    return update.when(
      data: (info) {
        if (info == null) return const SizedBox.shrink();
        return MaterialBanner(
          content: Text('Update available: ${info.latestVersion}'),
          leading: const Icon(Icons.system_update),
          actions: [
            TextButton(
              onPressed: () =>
                  unawaited(launchUrl(Uri.parse(info.downloadUrl))),
              child: const Text('Download'),
            ),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}
