import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sharedinbox/core/models/mailbox_sync_state.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';

String _fmtBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Per-mailbox breakdown of offline availability for one account.
///
/// One mail is in exactly one bucket:
///   1. On server only – server has it, we don't (initial sync in progress)
///   2. Header-only    – headers cached, body not fetched
///   3. Partial        – body cached, some attachments still missing
///   4. Fully offline  – body + all attachments on disk (or no attachments)
class SyncStateScreen extends ConsumerWidget {
  const SyncStateScreen({super.key, required this.accountId});

  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(syncStateForAccountProvider(accountId));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync state'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () =>
                ref.invalidate(syncStateForAccountProvider(accountId)),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (states) {
          if (states.isEmpty) {
            return const Center(child: Text('No mailboxes synced yet'));
          }
          return RefreshIndicator(
            onRefresh: () async =>
                ref.invalidate(syncStateForAccountProvider(accountId)),
            child: ListView.builder(
              itemCount: states.length + 1,
              itemBuilder: (ctx, i) {
                if (i == 0) return _AccountSummaryCard(states: states);
                return _MailboxSyncStateTile(state: states[i - 1]);
              },
            ),
          );
        },
      ),
    );
  }
}

class _AccountSummaryCard extends StatelessWidget {
  const _AccountSummaryCard({required this.states});

  final List<MailboxSyncState> states;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    var fullyCount = 0;
    var fullyBytes = 0;
    var partialCount = 0;
    var partialBytes = 0;
    var headerCount = 0;
    var serverOnly = 0;
    for (final s in states) {
      fullyCount += s.fullyOfflineCount;
      fullyBytes += s.fullyOfflineBytes;
      partialCount += s.partialCount;
      partialBytes += s.partialBytes;
      headerCount += s.headerOnlyCount;
      serverOnly += s.serverOnlyCount;
    }
    final totalOnDisk = fullyBytes + partialBytes;

    return Card(
      margin: const EdgeInsets.all(AppSpacing.md),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Account totals', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            _statLine(
              context,
              icon: Icons.download_done,
              color: Colors.green,
              label: 'Fully offline',
              value: '$fullyCount mails · ${_fmtBytes(fullyBytes)}',
            ),
            _statLine(
              context,
              icon: Icons.downloading,
              color: Colors.amber.shade700,
              label: 'Partial',
              value: '$partialCount mails · ${_fmtBytes(partialBytes)}',
            ),
            _statLine(
              context,
              icon: Icons.subject,
              color: theme.colorScheme.onSurfaceVariant,
              label: 'Header-only',
              value: '$headerCount mails',
            ),
            _statLine(
              context,
              icon: Icons.cloud_off,
              color: theme.colorScheme.error,
              label: 'On server only',
              value: '$serverOnly mails',
            ),
            const Divider(height: AppSpacing.xl),
            Text(
              'Total on disk: ${_fmtBytes(totalOnDisk)}',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statLine(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String label,
    required String value,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(icon, size: AppIconSize.sm, color: color),
          const SizedBox(width: AppSpacing.sm),
          SizedBox(
            width: 140,
            child: Text(label, style: theme.textTheme.bodyMedium),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

class _MailboxSyncStateTile extends StatelessWidget {
  const _MailboxSyncStateTile({required this.state});

  final MailboxSyncState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = state.totalCount;
    final subtitleParts = <String>[
      if (state.fullyOfflineCount > 0)
        'Offline ${state.fullyOfflineCount}',
      if (state.partialCount > 0) 'Partial ${state.partialCount}',
      if (state.headerOnlyCount > 0)
        'Header-only ${state.headerOnlyCount}',
      if (state.serverOnlyCount > 0)
        'On server ${state.serverOnlyCount}',
    ];
    final subtitle = subtitleParts.isEmpty ? 'Empty' : subtitleParts.join(' · ');

    return ExpansionTile(
      leading: const Icon(Icons.folder_outlined),
      title: Text(state.displayName),
      subtitle: Text(subtitle, style: theme.textTheme.bodySmall),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            72,
            0,
            AppSpacing.lg,
            AppSpacing.md,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SyncStateBar(state: state),
              const SizedBox(height: AppSpacing.md),
              _row(
                context,
                Colors.green,
                'Fully offline',
                '${state.fullyOfflineCount} · '
                    '${_fmtBytes(state.fullyOfflineBytes)}',
              ),
              _row(
                context,
                Colors.amber.shade700,
                'Partial',
                '${state.partialCount} · ${_fmtBytes(state.partialBytes)}',
              ),
              _row(
                context,
                theme.colorScheme.onSurfaceVariant,
                'Header-only',
                '${state.headerOnlyCount}',
              ),
              _row(
                context,
                theme.colorScheme.error,
                'On server only',
                '${state.serverOnlyCount}',
              ),
              const Divider(),
              _row(context, null, 'Server total', '$total'),
              _row(
                context,
                null,
                'On disk',
                _fmtBytes(state.totalBytes),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(
    BuildContext context,
    Color? swatch,
    String label,
    String value,
  ) {
    final theme = Theme.of(context);
    final smallStyle = theme.textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          SizedBox(
            width: AppSpacing.md,
            child: swatch == null
                ? null
                : Container(
                    width: AppSpacing.sm,
                    height: AppSpacing.sm,
                    decoration: BoxDecoration(
                      color: swatch,
                      shape: BoxShape.circle,
                    ),
                  ),
          ),
          const SizedBox(width: AppSpacing.sm),
          SizedBox(
            width: 160,
            child: Text(
              label,
              style: smallStyle?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value, style: smallStyle)),
        ],
      ),
    );
  }
}

/// Stacked segment bar visualising the four buckets for one mailbox.
class _SyncStateBar extends StatelessWidget {
  const _SyncStateBar({required this.state});

  final MailboxSyncState state;

  @override
  Widget build(BuildContext context) {
    final total = state.totalCount;
    if (total <= 0) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final segments = <_Segment>[
      _Segment(state.fullyOfflineCount, Colors.green),
      _Segment(state.partialCount, Colors.amber.shade700),
      _Segment(state.headerOnlyCount, theme.colorScheme.onSurfaceVariant),
      _Segment(state.serverOnlyCount, theme.colorScheme.error),
    ].where((s) => s.value > 0).toList();

    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 8,
        child: Row(
          children: [
            for (final seg in segments)
              Expanded(
                flex: seg.value,
                child: Container(color: seg.color),
              ),
          ],
        ),
      ),
    );
  }
}

class _Segment {
  const _Segment(this.value, this.color);
  final int value;
  final Color color;
}
