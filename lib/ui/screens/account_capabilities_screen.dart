import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/services/server_capabilities_service.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';

/// Lists what the mail server behind one account supports.
///
/// For IMAP accounts this is the server's `CAPABILITY` tokens; for JMAP the
/// Session capability URNs. Probed live each time the screen opens (pull to
/// refresh or the refresh action re-runs the probe).
class AccountCapabilitiesScreen extends ConsumerWidget {
  const AccountCapabilitiesScreen({super.key, required this.accountId});

  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountByIdProvider(accountId)).value;
    final async = ref.watch(serverCapabilitiesProvider(accountId));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Server capabilities'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () =>
                ref.invalidate(serverCapabilitiesProvider(accountId)),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorView(accountId: accountId, error: e),
        data: (caps) => _CapabilitiesList(account: account, caps: caps),
      ),
    );
  }
}

class _CapabilitiesList extends StatelessWidget {
  const _CapabilitiesList({required this.account, required this.caps});

  final Account? account;
  final ServerCapabilities caps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = caps.capabilities;
    return ListView.builder(
      itemCount: tokens.length + 1,
      itemBuilder: (ctx, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (account != null)
                  Text(
                    account!.displayName,
                    style: theme.textTheme.titleLarge,
                  ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '${caps.type == AccountType.jmap ? 'JMAP' : 'IMAP'} · '
                  '${tokens.length} '
                  '${tokens.length == 1 ? 'capability' : 'capabilities'}',
                  style: theme.textTheme.bodySmall,
                ),
                if (tokens.isEmpty) ...[
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    'The server did not advertise any capabilities.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
                const Divider(),
              ],
            ),
          );
        }
        final token = tokens[i - 1];
        final description = capabilityDescription(token);
        return ListTile(
          dense: true,
          leading: const Icon(Icons.check_circle_outline),
          title: Text(token, style: const TextStyle(fontFamily: 'monospace')),
          subtitle: description == null ? null : Text(description),
        );
      },
    );
  }
}

class _ErrorView extends ConsumerWidget {
  const _ErrorView({required this.accountId, required this.error});

  final String accountId;
  final Object error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, color: theme.colorScheme.error, size: 48),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Could not reach the server',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text('$error', textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.lg),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
              onPressed: () =>
                  ref.invalidate(serverCapabilitiesProvider(accountId)),
            ),
          ],
        ),
      ),
    );
  }
}
