import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/pending_change.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/outbox_screen.dart' show SyncNowFn;
import 'package:sharedinbox/ui/theme/spacing.dart';

final _dateFmt = DateFormat('MMM d, HH:mm');

/// Global list of the outbound queue (`pending_changes`) across all accounts,
/// grouped by account. Each row shows the change kind, target, age, attempt
/// count, and last error. Actions:
///
///  * **Retry now** — resets the row's attempt/error state and asks the sync
///    manager to flush the account immediately.
///  * **Discard**  — drops the row from the queue. Local state stays as it is
///    (the optimistic local mutation is not undone).
class PendingChangesScreen extends ConsumerWidget {
  const PendingChangesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rowsAsync = ref.watch(allPendingChangesProvider);
    final accountsAsync = ref.watch(allAccountsProvider);
    final repo = ref.watch(emailRepositoryProvider);
    final syncNow = ref.read(syncNowProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Pending Changes')),
      body: rowsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (rows) {
          if (rows.isEmpty) {
            return const Center(child: Text('No pending changes.'));
          }
          final accounts = accountsAsync.value ?? const <Account>[];
          final accountsById = {for (final a in accounts) a.id: a};
          final grouped = _groupByAccount(rows);
          return ListView(
            children: [
              for (final entry in grouped.entries)
                _AccountGroup(
                  account: accountsById[entry.key],
                  accountId: entry.key,
                  changes: entry.value,
                  repo: repo,
                  syncNow: syncNow,
                ),
            ],
          );
        },
      ),
    );
  }

  static Map<String, List<PendingChange>> _groupByAccount(
    List<PendingChange> rows,
  ) {
    final out = <String, List<PendingChange>>{};
    for (final r in rows) {
      out.putIfAbsent(r.accountId, () => []).add(r);
    }
    return out;
  }
}

class _AccountGroup extends StatelessWidget {
  const _AccountGroup({
    required this.account,
    required this.accountId,
    required this.changes,
    required this.repo,
    required this.syncNow,
  });

  final Account? account;
  final String accountId;
  final List<PendingChange> changes;
  final EmailRepository repo;
  final SyncNowFn syncNow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = account?.displayName.isNotEmpty ?? false
        ? account!.displayName
        : (account?.email ?? accountId);
    final type = (account?.type ?? AccountType.imap).name.toUpperCase();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: theme.colorScheme.surfaceContainerHighest,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '$label • $type',
                  style: theme.textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Badge(label: Text('${changes.length}')),
            ],
          ),
        ),
        for (final c in changes)
          PendingChangeTile(
            change: c,
            repo: repo,
            syncNow: syncNow,
          ),
        const Divider(height: 1),
      ],
    );
  }
}

/// Individual pending-change row. Extracted so widget tests can construct it
/// in isolation without a full router/scope.
class PendingChangeTile extends StatelessWidget {
  const PendingChangeTile({
    super.key,
    required this.change,
    required this.repo,
    required this.syncNow,
  });

  final PendingChange change;
  final EmailRepository repo;
  final SyncNowFn syncNow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(
        change.hasError ? Icons.error : Icons.sync,
        color: change.hasError ? theme.colorScheme.error : null,
      ),
      title: Text(kindLabel(change.kind)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Target: ${describeTarget(change)}',
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            'Queued: ${_dateFmt.format(change.createdAt.toLocal())}'
            ' • age ${_formatAge(DateTime.now().difference(change.createdAt))}'
            ' • attempts ${change.attempts}',
            style: theme.textTheme.bodySmall,
          ),
          if (change.lastError != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                'Last error: ${change.lastError}',
                style: TextStyle(color: theme.colorScheme.error),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Retry now',
            onPressed: () => _retry(context),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Discard',
            onPressed: () => unawaited(repo.discardMutation(change.id)),
          ),
        ],
      ),
    );
  }

  Future<void> _retry(BuildContext context) async {
    // Capture the messenger BEFORE the async gap so a mid-await rebuild
    // (queue row disappears once the flush succeeds) does not invalidate the
    // context we're about to show the snackbar from.
    final messenger = ScaffoldMessenger.of(context);
    await repo.retryMutation(change.id);
    final kicked = syncNow(change.accountId);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          kicked
              ? 'Retrying change…'
              : 'Sync is not running for this account. '
                  'Enable it so the change can be applied.',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }
}

/// Human-readable label for the `change_type` column stored in the DB.
String kindLabel(String kind) {
  return switch (kind) {
    'flag_seen' => 'Mark read/unread',
    'flag_flagged' => 'Toggle flag',
    'move' => 'Move',
    'delete' => 'Delete',
    'append' => 'Append',
    _ => kind,
  };
}

/// Renders the mutation target as `email {id} → {mailbox}` for moves, or the
/// plain `email {id}` for flag/delete operations. Falls back gracefully when
/// the payload is missing or the JSON can't be parsed.
String describeTarget(PendingChange change) {
  final dest = _destinationFromPayload(change.payload);
  final subject = change.resourceType == 'Email'
      ? 'email ${change.resourceId}'
      : '${change.resourceType} ${change.resourceId}';
  if (dest != null) return '$subject → $dest';
  return subject;
}

String? _destinationFromPayload(String payload) {
  if (payload.isEmpty) return null;
  try {
    final decoded = jsonDecode(payload);
    if (decoded is Map<String, dynamic>) {
      final dest = decoded['dest'] ?? decoded['mailboxPath'];
      if (dest is String && dest.isNotEmpty) return dest;
    }
  } catch (_) {
    // Ignore — payloads are protocol-specific; the DB-level shape isn't
    // guaranteed here and this string is only for display.
  }
  return null;
}

String _formatAge(Duration age) {
  if (age.inDays >= 1) return '${age.inDays}d';
  if (age.inHours >= 1) return '${age.inHours}h';
  if (age.inMinutes >= 1) return '${age.inMinutes}m';
  if (age.inSeconds >= 1) return '${age.inSeconds}s';
  return 'just now';
}
