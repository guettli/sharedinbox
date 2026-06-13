import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/services/update_service.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
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
            DrawerHeader(
              decoration: const BoxDecoration(color: Colors.blueGrey),
              child: Text(
                'sharedinbox.de',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(color: Colors.white),
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
            ListTile(
              leading: const Icon(Icons.settings),
              title: const Text('Preferences'),
              onTap: () {
                Navigator.pop(context); // Close drawer
                unawaited(context.push('/accounts/preferences'));
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: const Icon(Icons.account_circle),
          title: Text(account.displayName),
          subtitle: Text('${account.email}\n$typeLabel'),
          isThreeLine: true,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              status.when(
                loading: () => const SizedBox(
                  width: AppIconSize.md,
                  height: AppIconSize.md,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                data: (_) =>
                    const Icon(Icons.check_circle, color: Colors.green),
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
        ),
        Padding(
          // 72 aligns with the ListTile leading indent so the health row
          // lines up with the title above.
          padding:
              const EdgeInsets.fromLTRB(72, 0, AppSpacing.lg, AppSpacing.sm),
          child: health.when(
            data: (h) {
              if (h == null) return const Text('Sync health: Not verified yet');
              final date = h.lastVerifiedAt.toLocal().toString().split('.')[0];
              return Row(
                children: [
                  const Text('Sync health: '),
                  Icon(
                    h.isHealthy ? Icons.verified : Icons.warning_amber,
                    size: AppIconSize.sm,
                    color: h.isHealthy ? Colors.green : Colors.orange,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: Text(
                      h.isHealthy
                          ? 'Healthy'
                          : _formatDiscrepancies(h.discrepancySummary),
                    ),
                  ),
                  Text(
                    ' ($date)',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              );
            },
            loading: () => const Text('Sync health: checking...'),
            error: (e, _) => Text('Sync health error: $e'),
          ),
        ),
      ],
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

String _formatDiscrepancies(String? summary) {
  if (summary == null) return 'Discrepancies found';
  try {
    final decoded = jsonDecode(summary) as Map<String, dynamic>;
    var missingLocally = 0;
    var missingOnServer = 0;
    var flagMismatches = 0;
    for (final v in decoded.values) {
      final m = v as Map<String, dynamic>;
      missingLocally += (m['missingLocally'] as int? ?? 0);
      missingOnServer += (m['missingOnServer'] as int? ?? 0);
      flagMismatches += (m['flagMismatches'] as int? ?? 0);
    }
    final parts = <String>[];
    if (missingLocally > 0) parts.add('missing locally: $missingLocally');
    if (missingOnServer > 0) parts.add('missing on server: $missingOnServer');
    if (flagMismatches > 0) parts.add('flag mismatches: $flagMismatches');
    if (parts.isEmpty) return 'Discrepancies found';
    return 'Discrepancies found (${parts.join(', ')})';
  } catch (_) {
    return 'Discrepancies found';
  }
}

class _OnboardingView extends StatelessWidget {
  const _OnboardingView();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.mail_outline,
              size: AppIconSize.hero,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Welcome to sharedinbox.de',
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Get started in three steps:',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xl),
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
            const SizedBox(height: AppSpacing.xxl),
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
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: AppSpacing.lg,
            backgroundColor: theme.colorScheme.primaryContainer,
            child: Text(
              number,
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.lg),
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
