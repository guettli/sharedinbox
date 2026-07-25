import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/outbox_message.dart';
import 'package:sharedinbox/core/repositories/outbox_repository.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/outbox_screen.dart'
    show QueueRowActions, SyncNowFn, retryQueueRow, showOutboxErrorDetails;
import 'package:sharedinbox/ui/theme/spacing.dart';

final _dateFmt = DateFormat('MMM d, HH:mm');

const _subjectPreviewLength = 60;

/// Global view of every queued-but-not-yet-sent message across all accounts.
/// Columns: account, account type, receiver, date, start of subject. Actions
/// (Retry / Discard) mirror the per-account [OutboxScreen] so users can act
/// on rows without navigating into the owning account first.
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
            return const Center(
              child: Text('No messages waiting to be sent.'),
            );
          }
          final accounts = accountsAsync.value ?? const <Account>[];
          final accountsById = {for (final a in accounts) a.id: a};
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (ctx, i) => SentQueueTile(
              message: rows[i],
              account: accountsById[rows[i].accountId],
              repo: repo,
              syncNow: syncNow,
            ),
          );
        },
      ),
    );
  }
}

class SentQueueTile extends StatelessWidget {
  const SentQueueTile({
    super.key,
    required this.message,
    required this.account,
    required this.repo,
    required this.syncNow,
  });

  final OutboxMessage message;
  final Account? account;
  final OutboxRepository repo;
  final SyncNowFn syncNow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accountLabel = account?.displayName.isNotEmpty ?? false
        ? account!.displayName
        : (account?.email ?? message.accountId);
    final accountType = (account?.type ?? AccountType.imap).name.toUpperCase();
    final receiver = message.to.isNotEmpty
        ? message.to.join(', ')
        : (message.cc.isNotEmpty ? message.cc.join(', ') : '(no recipient)');
    final date = _dateFmt.format(message.createdAt.toLocal());
    final rawSubject =
        message.subject.isEmpty ? '(no subject)' : message.subject;
    final subject = rawSubject.length > _subjectPreviewLength
        ? '${rawSubject.substring(0, _subjectPreviewLength)}…'
        : rawSubject;

    return ListTile(
      leading: Icon(
        message.isFailed ? Icons.error : Icons.outbox,
        color: message.isFailed ? theme.colorScheme.error : null,
      ),
      title: Text(
        subject,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$accountLabel • $accountType',
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            'To: $receiver',
            overflow: TextOverflow.ellipsis,
          ),
          Text(date, style: theme.textTheme.bodySmall),
          if (message.lastError != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: InkWell(
                onTap: () => showOutboxErrorDetails(context, message),
                child: Text(
                  '${message.isFailed ? 'Failed' : 'Pending'}'
                  ' (attempts: ${message.attempts}): ${message.lastError} '
                  '(tap for details)',
                  style: TextStyle(color: theme.colorScheme.error),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
        ],
      ),
      trailing: QueueRowActions(
        onRetry: () => _retry(context),
        onDiscard: () => unawaited(repo.discard(message.id)),
      ),
    );
  }

  Future<void> _retry(BuildContext context) => retryQueueRow(
        context: context,
        accountId: message.accountId,
        retry: () => repo.retry(message.id),
        syncNow: syncNow,
        runningMessage: 'Retrying send…',
        notRunningMessage: 'Sync is not running for this account. '
            'Enable it to send the queued message.',
      );
}
