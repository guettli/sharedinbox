import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:sharedinbox/core/models/outbox_message.dart';
import 'package:sharedinbox/core/repositories/outbox_repository.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';

/// Kicks the sync loop for [accountId] so the next flush attempt runs
/// immediately. Returns `true` when a loop was actually notified — see
/// [AccountSyncManager.syncNow]. Callback-shape so the queued-message tiles
/// stay decoupled from the concrete sync manager (and testable without one).
typedef SyncNowFn = bool Function(String accountId);

final _dateFmt = DateFormat('MMM d, HH:mm');

/// One-line explanation of why a queued message is still waiting, for rows that
/// have not recorded an error yet. Without this a fresh or backing-off row
/// showed only its subject/recipient and looked stuck for no reason (#501).
/// Rows that already have a `lastError` render the richer error line instead.
String pendingOutboxStatus(OutboxMessage message, {DateTime? now}) {
  final next = message.nextAttemptAt;
  if (next != null && next.isAfter(now ?? DateTime.now())) {
    return 'Waiting to retry — next attempt ${_dateFmt.format(next.toLocal())}';
  }
  return 'Queued — will send on the next sync';
}

/// Lists messages queued in the offline send queue for [accountId].
/// Each row offers Retry (resets the backoff and kicks the account sync loop
/// so the next attempt runs immediately, then reports the outcome via a
/// SnackBar) and Discard (drops the message from the queue).
class OutboxScreen extends ConsumerWidget {
  const OutboxScreen({super.key, required this.accountId});

  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(outboxRepositoryProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Outbox')),
      body: StreamBuilder<List<OutboxMessage>>(
        stream: repo.observeOutbox(accountId),
        builder: (ctx, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final rows = snap.data!;
          if (rows.isEmpty) {
            return const Center(child: Text('Outbox is empty'));
          }
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (ctx, i) => OutboxTile(
              message: rows[i],
              repo: repo,
              syncNow: ref.read(syncNowProvider),
            ),
          );
        },
      ),
    );
  }
}

/// Individual queued-message row. Extracted so widget tests can construct one
/// in isolation without needing to pump a full [Scaffold] + Riverpod scope.
class OutboxTile extends StatelessWidget {
  const OutboxTile({
    super.key,
    required this.message,
    required this.repo,
    required this.syncNow,
  });

  final OutboxMessage message;
  final OutboxRepository repo;
  final SyncNowFn syncNow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(
        message.isFailed ? Icons.error : Icons.outbox,
        color: message.isFailed ? theme.colorScheme.error : null,
      ),
      title: Text(
        message.subject.isEmpty ? '(no subject)' : message.subject,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'To: ${message.to.join(', ')}',
            overflow: TextOverflow.ellipsis,
          ),
          if (message.lastError != null)
            _LastErrorLine(
              message: message,
              onTap: () => showOutboxErrorDetails(context, message),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                pendingOutboxStatus(message),
                style: theme.textTheme.bodySmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
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
        notRunningMessage: 'Sync for this account is stopped, so the message '
            'cannot be sent. Check the account credentials.',
      );
}

class _LastErrorLine extends StatelessWidget {
  const _LastErrorLine({required this.message, required this.onTap});

  final OutboxMessage message;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: InkWell(
        onTap: onTap,
        child: Text(
          '${message.isFailed ? 'Failed' : 'Pending'}'
          ' (attempts: ${message.attempts}): ${message.lastError} '
          '(tap for details)',
          style: TextStyle(color: theme.colorScheme.error),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

/// The trailing Row of Retry/Discard IconButtons used by every queue-row
/// tile (Outbox, Sent Queue, Pending Changes). Extracted so the three
/// screens share the same tooltips, icons, and layout without copy-paste.
class QueueRowActions extends StatelessWidget {
  const QueueRowActions({
    super.key,
    required this.onRetry,
    required this.onDiscard,
  });

  final VoidCallback onRetry;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Retry now',
          onPressed: onRetry,
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Discard',
          onPressed: onDiscard,
        ),
      ],
    );
  }
}

/// Runs [retry] (usually resetting a queue row on the DB), then kicks the
/// sync loop for [accountId] via [syncNow] and reports the outcome via a
/// [SnackBar] on the enclosing [Scaffold]. Extracted so both the outbound
/// send queue (per-account Outbox / global Sent Queue) and the pending
/// mutation queue (Pending Changes) use identical retry semantics.
///
/// [runningMessage] is shown when the sync loop was actually kicked;
/// [notRunningMessage] is shown when the loop is not currently active (e.g.
/// bad credentials, account paused).
Future<void> retryQueueRow({
  required BuildContext context,
  required String accountId,
  required Future<void> Function() retry,
  required SyncNowFn syncNow,
  required String runningMessage,
  required String notRunningMessage,
}) async {
  // Capture the messenger BEFORE the async gap so a mid-await rebuild (queue
  // row disappears once the flush succeeds) does not invalidate the context
  // we're about to show the snackbar from.
  final messenger = ScaffoldMessenger.of(context);
  await retry();
  final kicked = syncNow(accountId);
  messenger.showSnackBar(
    SnackBar(
      content: Text(kicked ? runningMessage : notRunningMessage),
      duration: const Duration(seconds: 3),
    ),
  );
}

/// Shows the full last-error text alongside a "View in application log"
/// button. Extracted so the same dialog can be launched from both the
/// per-account Outbox screen and the global Sent Queue screen.
Future<void> showOutboxErrorDetails(
  BuildContext context,
  OutboxMessage message,
) {
  final theme = Theme.of(context);
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(message.isFailed ? 'Send failed' : 'Send pending retry'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Attempts: ${message.attempts}',
              style: theme.textTheme.bodyMedium,
            ),
            if (message.nextAttemptAt != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Next attempt: '
                '${_dateFmt.format(message.nextAttemptAt!.toLocal())}',
                style: theme.textTheme.bodyMedium,
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            SelectableText(
              message.lastError ?? '(no error recorded)',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(ctx).pop();
            unawaited(
              context.push(
                '/accounts/app-log?accountId='
                '${Uri.encodeComponent(message.accountId)}',
              ),
            );
          },
          child: const Text('View in application log'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
