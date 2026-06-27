import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sharedinbox/core/models/outbox_message.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';

/// Lists messages queued in the offline send queue for [accountId].
/// Each row offers Retry (resets the backoff so the next sync picks it up
/// immediately) and Discard (drops the message from the queue).
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
            itemBuilder: (ctx, i) {
              final r = rows[i];
              return ListTile(
                leading: Icon(
                  r.isFailed ? Icons.error : Icons.outbox,
                  color:
                      r.isFailed ? Theme.of(context).colorScheme.error : null,
                ),
                title: Text(
                  r.subject.isEmpty ? '(no subject)' : r.subject,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'To: ${r.to.join(', ')}',
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (r.lastError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.xs),
                        child: Text(
                          '${r.isFailed ? 'Failed' : 'Pending'}'
                          ' (attempts: ${r.attempts}): ${r.lastError}',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
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
                      onPressed: () => unawaited(repo.retry(r.id)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Discard',
                      onPressed: () => unawaited(repo.discard(r.id)),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
