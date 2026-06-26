import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/sync/account_comparison_provider.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/account_actions.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/app_drawer.dart';

/// Landing page for a single account, reachable from the unified burger menu
/// or by tapping an account row in the drawer. Hosts the same per-account
/// actions that the long-press menu on [AccountListScreen] surfaces.
class AccountHomeScreen extends ConsumerWidget {
  const AccountHomeScreen({super.key, required this.accountId});

  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountAsync = ref.watch(accountByIdProvider(accountId));
    return Scaffold(
      appBar: AppBar(
        title: accountAsync.maybeWhen(
          data: (a) => Text(a?.displayName ?? 'Account'),
          orElse: () => const Text('Account'),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search',
            onPressed: () => context.push('/accounts/$accountId/search'),
          ),
        ],
      ),
      drawer: AppDrawer(current: AppDrawerSelection.account(accountId)),
      body: accountAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (account) {
          if (account == null) {
            return const Center(child: Text('Account not found'));
          }
          return _AccountHomeBody(account: account);
        },
      ),
    );
  }
}

class _AccountHomeBody extends ConsumerWidget {
  const _AccountHomeBody({required this.account});

  final Account account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final counterparts =
        ref.watch(comparableCounterpartsProvider(account.id)).value ??
            const <Account>[];
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                account.displayName,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                account.email,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                account.type == AccountType.jmap ? 'JMAP' : 'IMAP',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.folder_open),
          title: const Text('Folders'),
          subtitle: const Text('Browse all mailboxes for this account'),
          onTap: () => context.push('/accounts/${account.id}/mailboxes'),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.receipt_long),
          title: const Text('Sync log'),
          onTap: () =>
              runAccountAction(context, ref, account, AccountAction.syncLog),
        ),
        ListTile(
          leading: const Icon(Icons.verified),
          title: const Text('Verify sync health'),
          onTap: () =>
              runAccountAction(context, ref, account, AccountAction.verifySync),
        ),
        ListTile(
          leading: const Icon(Icons.sync),
          title: const Text('Force full sync'),
          onTap: () =>
              runAccountAction(context, ref, account, AccountAction.forceSync),
        ),
        ListTile(
          leading: const Icon(Icons.edit),
          title: const Text('Edit'),
          onTap: () =>
              runAccountAction(context, ref, account, AccountAction.edit),
        ),
        if (sieveSupported(account))
          ListTile(
            leading: const Icon(Icons.dns),
            title: const Text('Server email filters'),
            onTap: () => runAccountAction(
              context,
              ref,
              account,
              AccountAction.emailFiltersRemote,
            ),
          ),
        ListTile(
          leading: const Icon(Icons.phone_android),
          title: const Text('Local email filters'),
          onTap: () => runAccountAction(
            context,
            ref,
            account,
            AccountAction.emailFiltersLocal,
          ),
        ),
        ListTile(
          leading: const Icon(Icons.send),
          title: const Text('Send accounts'),
          onTap: () =>
              runAccountAction(context, ref, account, AccountAction.send),
        ),
        for (final other in counterparts)
          ListTile(
            leading: const Icon(Icons.compare_arrows),
            title: Text(
              'Compare to ${other.displayName} '
              '(${other.type == AccountType.jmap ? 'JMAP' : 'IMAP'})',
            ),
            onTap: () => openAccountCompare(context, account.id, other.id),
          ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.delete, color: Colors.red),
          title: const Text(
            'Delete account',
            style: TextStyle(color: Colors.red),
          ),
          onTap: () =>
              runAccountAction(context, ref, account, AccountAction.delete),
        ),
      ],
    );
  }
}
