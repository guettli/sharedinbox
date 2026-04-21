import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/repositories/sync_log_repository.dart';
import '../../di.dart';

final _timeFmt = DateFormat('MMM d, HH:mm:ss');

class SyncLogScreen extends ConsumerWidget {
  const SyncLogScreen({super.key, required this.accountId});

  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(syncLogRepositoryProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Sync log')),
      body: StreamBuilder<List<SyncLogEntry>>(
        stream: repo.observeSyncLogs(accountId),
        builder: (ctx, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final entries = snap.data!;
          if (entries.isEmpty) {
            return const Center(child: Text('No sync entries yet'));
          }
          return ListView.builder(
            itemCount: entries.length,
            itemBuilder: (ctx, i) {
              final e = entries[i];
              final ms = e.duration.inMilliseconds;
              final durationLabel =
                  ms < 1000 ? '${ms}ms' : '${(ms / 1000).toStringAsFixed(1)}s';
              return ListTile(
                leading: Icon(
                  e.isOk ? Icons.check_circle : Icons.error_outline,
                  color:
                      e.isOk ? Colors.green : Theme.of(ctx).colorScheme.error,
                ),
                title: Text(
                  e.isOk ? 'OK' : 'Error',
                  style: e.isOk
                      ? null
                      : TextStyle(color: Theme.of(ctx).colorScheme.error),
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_timeFmt.format(e.startedAt)),
                    Text('took $durationLabel'),
                    if (e.errorMessage != null)
                      Text(
                        e.errorMessage!,
                        style: TextStyle(
                          color: Theme.of(ctx).colorScheme.error,
                          fontSize: 12,
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
                isThreeLine: e.errorMessage != null,
              );
            },
          );
        },
      ),
    );
  }
}
