import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/repositories/sync_log_repository.dart';
import 'package:sharedinbox/core/sync/account_sync_manager.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';

/// Full-screen view driven by [AccountSyncManager.forceResync] (or, when
/// [mailboxPath] is set, [AccountSyncManager.forceResyncMailbox]). Streams
/// progress snapshots and shows per-mailbox counts, a running total, and any
/// errors that occurred. Cached email bodies/attachments are preserved by the
/// underlying resync so this screen never re-downloads them.
class ForceResyncScreen extends ConsumerStatefulWidget {
  const ForceResyncScreen({
    super.key,
    required this.accountId,
    this.mailboxPath,
  });

  final String accountId;

  /// When non-null, only this folder is cleared and re-synced. When null, the
  /// whole account is resynced.
  final String? mailboxPath;

  @override
  ConsumerState<ForceResyncScreen> createState() => _ForceResyncScreenState();
}

class _ForceResyncScreenState extends ConsumerState<ForceResyncScreen> {
  StreamSubscription<ForceResyncProgress>? _sub;
  ForceResyncProgress? _progress;

  @override
  void initState() {
    super.initState();
    final manager = ref.read(syncManagerProvider);
    final path = widget.mailboxPath;
    final stream = path == null
        ? manager.forceResync(widget.accountId)
        : manager.forceResyncMailbox(widget.accountId, path);
    _sub = stream.listen((p) => setState(() => _progress = p));
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _progress;
    final terminal = p?.isTerminal ?? false;

    return PopScope(
      // Block back navigation while the resync is running so the user
      // can't close the screen mid-flight.
      canPop: terminal,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            widget.mailboxPath == null
                ? 'Force full re-sync'
                : 'Re-sync folder',
          ),
          leading: terminal
              ? IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => context.pop(),
                )
              : null,
        ),
        body: p == null
            ? const Center(child: CircularProgressIndicator())
            : _ProgressBody(progress: p),
      ),
    );
  }
}

class _ProgressBody extends StatelessWidget {
  const _ProgressBody({required this.progress});

  final ForceResyncProgress progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        _PhaseHeader(progress: progress),
        const SizedBox(height: AppSpacing.lg),
        _Totals(progress: progress),
        if (progress.mailboxStats.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          Text('Mailboxes', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          for (final s in progress.mailboxStats) _MailboxRow(stats: s),
        ],
        if (progress.error != null) ...[
          const SizedBox(height: AppSpacing.lg),
          _ErrorPanel(message: progress.error!),
        ],
      ],
    );
  }
}

class _PhaseHeader extends StatelessWidget {
  const _PhaseHeader({required this.progress});

  final ForceResyncProgress progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, showSpinner) = switch (progress.phase) {
      ForceResyncPhase.clearing => (
          'Clearing local cache…',
          true,
        ),
      ForceResyncPhase.syncingMailboxes => (
          'Syncing mailbox list…',
          true,
        ),
      ForceResyncPhase.syncingEmails => (
          progress.currentMailboxName == null
              ? 'Syncing mailboxes…'
              : 'Syncing ${progress.currentMailboxName} '
                  '(${progress.currentMailboxIndex + 1} of '
                  '${progress.totalMailboxes})',
          true,
        ),
      ForceResyncPhase.complete => (
          'Re-sync complete',
          false,
        ),
      ForceResyncPhase.failed => (
          'Re-sync finished with errors',
          false,
        ),
    };

    return Row(
      children: [
        if (showSpinner)
          const SizedBox(
            width: AppIconSize.md,
            height: AppIconSize.md,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          Icon(
            progress.phase == ForceResyncPhase.complete
                ? Icons.check_circle
                : Icons.error_outline,
            color: progress.phase == ForceResyncPhase.complete
                ? Colors.green
                : theme.colorScheme.error,
          ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Text(label, style: theme.textTheme.titleMedium),
        ),
      ],
    );
  }
}

class _Totals extends StatelessWidget {
  const _Totals({required this.progress});

  final ForceResyncProgress progress;

  @override
  Widget build(BuildContext context) {
    final total = progress.totalMailboxes;
    final done = progress.mailboxStats.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (total > 0)
          LinearProgressIndicator(value: total == 0 ? null : done / total),
        const SizedBox(height: AppSpacing.md),
        Text('Mailboxes finished: $done of $total'),
        Text('Emails fetched: ${progress.totalFetched}'),
        Text('Emails already up-to-date: ${progress.totalSkipped}'),
      ],
    );
  }
}

class _MailboxRow extends StatelessWidget {
  const _MailboxRow({required this.stats});

  final MailboxSyncStats stats;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          Expanded(child: Text(stats.mailboxName ?? stats.mailboxPath)),
          const SizedBox(width: AppSpacing.sm),
          Text(
            'new ${stats.fetched} · skipped ${stats.skipped}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(AppSpacing.sm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.error_outline,
            color: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: SelectableText(
              message,
              style: TextStyle(color: theme.colorScheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}
