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
            itemBuilder: (ctx, i) => _SyncLogTile(entry: entries[i]),
          );
        },
      ),
    );
  }
}

class _SyncLogTile extends StatelessWidget {
  const _SyncLogTile({required this.entry});

  final SyncLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final ms = entry.duration.inMilliseconds;
    final durationLabel =
        ms < 1000 ? '${ms}ms' : '${(ms / 1000).toStringAsFixed(1)}s';
    final proto =
        entry.protocol.isEmpty ? '' : ' · ${entry.protocol.toUpperCase()}';
    final theme = Theme.of(context);
    final errorColor = theme.colorScheme.error;

    return ExpansionTile(
      leading: Icon(
        entry.isOk ? Icons.check_circle : Icons.error_outline,
        color: entry.isOk ? Colors.green : errorColor,
      ),
      title: Text(
        '${_timeFmt.format(entry.startedAt)}$proto',
        style: entry.isOk ? null : TextStyle(color: errorColor),
      ),
      subtitle: Text(
        entry.isOk
            ? '${entry.emailsFetched} emails · ${entry.mailboxesSynced} mailboxes · took $durationLabel'
            : 'Error · took $durationLabel',
        style: TextStyle(
          fontSize: 12,
          color: entry.isOk ? null : errorColor,
        ),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(72, 0, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _row('Started', _timeFmt.format(entry.startedAt)),
              _row('Finished', _timeFmt.format(entry.finishedAt)),
              _row('Duration', durationLabel),
              if (entry.protocol.isNotEmpty)
                _row('Protocol', entry.protocol.toUpperCase()),
              _row('Emails fetched', '${entry.emailsFetched}'),
              _row('Mailboxes synced', '${entry.mailboxesSynced}'),
              _row('Pending changes flushed', '${entry.pendingFlushed}'),
              if (entry.errorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    entry.errorMessage!,
                    style: TextStyle(color: errorColor, fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          children: [
            SizedBox(
              width: 180,
              child: Text(
                label,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
            Expanded(
              child: Text(value, style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
      );
}
