import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/outbox_screen.dart' show OutboxQueueTile;

/// Global view of every queued-but-not-yet-sent message across all accounts.
/// Columns: account, account type, receiver, date, start of subject. Rows reuse
/// the per-account [OutboxScreen]'s tile (via [OutboxQueueTile]) so the Retry /
/// Discard actions behave identically and users can act on rows without
/// navigating into the owning account first.
class SentQueueScreen extends ConsumerWidget {
  const SentQueueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rowsAsync = ref.watch(allOutboxProvider);
    final accountsAsync = ref.watch(allAccountsProvider);
    final repo = ref.watch(outboxRepositoryProvider);
    final syncNow = ref.read(syncNowProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Sent Queue')),
      body: rowsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (rows) {
          if (rows.isEmpty) {
            return const Center(child: Text('No messages waiting to be sent.'));
          }
          final accounts = accountsAsync.value ?? const <Account>[];
          final accountsById = {for (final a in accounts) a.id: a};
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (ctx, i) => OutboxQueueTile(
              message: rows[i],
              account: accountsById[rows[i].accountId],
              repo: repo,
              syncNow: syncNow,
              showAccountHeader: true,
            ),
          );
        },
      ),
    );
  }
}
