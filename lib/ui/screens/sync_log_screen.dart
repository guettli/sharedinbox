import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/repositories/sync_log_repository.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/utils/about_markdown.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';

final _timeFmt = DateFormat('MMM d, HH:mm:ss');

String _fmtDuration(Duration d) {
  final ms = d.inMilliseconds;
  return ms < 1000 ? '${ms}ms' : '${(ms / 1000).toStringAsFixed(1)}s';
}

String _fmtBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Renders a shareable Markdown summary of a sync-log [entry]. Public so the
/// "copy sync entry" output — the exact text users paste into bug reports —
/// can be covered by tests.
String buildSyncEntryMarkdown(SyncLogEntry entry) {
  final buf = StringBuffer();
  buf.writeln('## Sync Entry');
  buf.writeln();
  buf.writeln('| Property | Value |');
  buf.writeln('|----------|-------|');
  buf.writeln('| Started | ${_timeFmt.format(entry.startedAt)} |');
  buf.writeln('| Finished | ${_timeFmt.format(entry.finishedAt)} |');
  buf.writeln('| Duration | ${_fmtDuration(entry.duration)} |');
  if (entry.protocol.isNotEmpty) {
    buf.writeln('| Protocol | ${entry.protocol.toUpperCase()} |');
  }
  final statusLabel = entry.isOk
      ? 'OK'
      : entry.isPermanent
          ? 'Error (permanent)'
          : 'Error';
  buf.writeln('| Status | $statusLabel |');
  buf.writeln('| Emails fetched | ${entry.emailsFetched} |');
  buf.writeln('| Emails up-to-date | ${entry.emailsSkipped} |');
  buf.writeln('| Mailboxes synced | ${entry.mailboxesSynced} |');
  buf.writeln('| Pending changes flushed | ${entry.pendingFlushed} |');
  buf.writeln('| Data transferred | ${_fmtBytes(entry.bytesTransferred)} |');
  if (entry.mailboxStats.isNotEmpty) {
    buf.writeln();
    buf.writeln('### Per mailbox');
    buf.writeln();
    buf.writeln('| Mailbox | Fetched | Up-to-date | Duration |');
    buf.writeln('|---------|---------|------------|----------|');
    for (final m in entry.mailboxStats) {
      final dur = m.duration != null ? _fmtDuration(m.duration!) : '-';
      final label = m.mailboxName ?? m.mailboxPath;
      buf.writeln('| $label | ${m.fetched} | ${m.skipped} | $dur |');
    }
  }
  if (entry.errorMessage != null) {
    buf.writeln();
    buf.writeln('**Error:**');
    buf.writeln();
    buf.writeln(entry.errorMessage);
  }
  if (entry.stackTrace != null) {
    buf.writeln();
    buf.writeln('**Stack trace:**');
    buf.writeln();
    buf.writeln('```');
    buf.write(entry.stackTrace);
    buf.writeln('```');
  }
  if (entry.protocolLog != null) {
    buf.writeln();
    buf.writeln('**Protocol log:**');
    buf.writeln();
    buf.writeln('```');
    buf.write(entry.protocolLog);
    buf.writeln('```');
  }
  return buf.toString();
}

class SyncLogScreen extends ConsumerStatefulWidget {
  const SyncLogScreen({super.key, required this.accountId});

  final String accountId;

  @override
  ConsumerState<SyncLogScreen> createState() => _SyncLogScreenState();
}

class _SyncLogScreenState extends ConsumerState<SyncLogScreen> {
  List<SyncLogEntry> _entries = [];
  bool _syncing = false;
  int? _presynCount;
  StreamSubscription<List<SyncLogEntry>>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = ref
        .read(syncLogRepositoryProvider)
        .observeSyncLogs(widget.accountId)
        .listen((entries) {
      setState(() {
        if (_syncing &&
            _presynCount != null &&
            entries.length > _presynCount!) {
          _syncing = false;
          _presynCount = null;
        }
        _entries = entries;
      });
    });
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  void _syncNow() {
    setState(() {
      _syncing = true;
      _presynCount = _entries.length;
    });
    ref.read(syncManagerProvider).syncNow(widget.accountId);
  }

  Future<void> _copyEntry(SyncLogEntry entry, BuildContext context) async {
    final accounts =
        await ref.read(accountRepositoryProvider).observeAccounts().first;
    final imapCount = accounts.where((a) => a.type == AccountType.imap).length;
    final jmapCount = accounts.where((a) => a.type == AccountType.jmap).length;

    PackageInfo? pkg;
    try {
      pkg = await PackageInfo.fromPlatform();
    } catch (_) {}

    final deviceModel = await getDeviceModel();

    if (!context.mounted) return;

    final syncMd = buildSyncEntryMarkdown(entry);
    final aboutMd = buildAboutMarkdown(
      context: context,
      pkg: pkg,
      imapCount: imapCount,
      jmapCount: jmapCount,
      deviceModel: deviceModel,
    );
    await Clipboard.setData(ClipboardData(text: '$syncMd\n$aboutMd'));

    if (context.mounted) {
      context.showAppSnackBar(
        'Copied to clipboard',
        duration: const Duration(seconds: 3),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync log'),
        actions: [
          if (_syncing)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: SizedBox(
                width: AppIconSize.lg,
                height: AppIconSize.lg,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.sync),
              tooltip: 'Sync now',
              onPressed: _syncNow,
            ),
        ],
      ),
      body: _entries.isEmpty
          ? const Center(child: Text('No sync entries yet'))
          : ListView.builder(
              itemCount: _entries.length,
              itemBuilder: (ctx, i) => _SyncLogTile(
                entry: _entries[i],
                onCopy: () => _copyEntry(_entries[i], ctx),
              ),
            ),
    );
  }
}

class _SyncLogTile extends StatelessWidget {
  const _SyncLogTile({required this.entry, required this.onCopy});

  final SyncLogEntry entry;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final durationLabel = _fmtDuration(entry.duration);
    final proto =
        entry.protocol.isEmpty ? '' : ' · ${entry.protocol.toUpperCase()}';
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final errorColor = cs.error;
    final smallStyle = theme.textTheme.bodySmall;
    final mutedSmallStyle = smallStyle?.copyWith(color: cs.onSurfaceVariant);

    final subtitleText = entry.isOk
        ? '${entry.emailsFetched} new · ${entry.emailsSkipped} up-to-date · took $durationLabel'
        : entry.isPermanent
            ? 'Error (permanent) · took $durationLabel'
            : 'Error · took $durationLabel';

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
        subtitleText,
        style: smallStyle?.copyWith(color: entry.isOk ? null : errorColor),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.list_alt, size: AppIconSize.sm),
            tooltip: 'View related app log entries',
            onPressed: () => context.push(
              '/accounts/app-log?syncLogId=${entry.id}',
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: AppIconSize.sm),
            tooltip: 'Copy as markdown',
            onPressed: onCopy,
          ),
          const Icon(Icons.expand_more),
        ],
      ),
      children: [
        Padding(
          // 72 aligns with the ListTile leading indent so children line up
          // with the title text.
          padding:
              const EdgeInsets.fromLTRB(72, 0, AppSpacing.lg, AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _row(context, 'Started', _timeFmt.format(entry.startedAt)),
              _row(context, 'Finished', _timeFmt.format(entry.finishedAt)),
              _row(context, 'Duration', durationLabel),
              if (entry.protocol.isNotEmpty)
                _row(context, 'Protocol', entry.protocol.toUpperCase()),
              _row(context, 'Emails fetched', '${entry.emailsFetched}'),
              _row(context, 'Emails up-to-date', '${entry.emailsSkipped}'),
              _row(context, 'Mailboxes synced', '${entry.mailboxesSynced}'),
              _row(
                context,
                'Pending changes flushed',
                '${entry.pendingFlushed}',
              ),
              _row(
                context,
                'Data transferred',
                _fmtBytes(entry.bytesTransferred),
              ),
              if (entry.mailboxStats.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.only(
                    top: AppSpacing.sm,
                    bottom: AppSpacing.xs,
                  ),
                  child: Text('Per mailbox', style: mutedSmallStyle),
                ),
                for (final m in entry.mailboxStats)
                  _row(
                    context,
                    '  ${m.mailboxName ?? m.mailboxPath}',
                    [
                      '${m.fetched} new · ${m.skipped} up-to-date',
                      if (m.duration != null) _fmtDuration(m.duration!),
                    ].join(' · '),
                  ),
              ],
              if (entry.errorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: Text(
                    entry.errorMessage!,
                    style: smallStyle?.copyWith(color: errorColor),
                  ),
                ),
              if (entry.stackTrace != null) ...[
                Padding(
                  padding: const EdgeInsets.only(
                    top: AppSpacing.sm,
                    bottom: AppSpacing.xs,
                  ),
                  child: Text('Stack trace', style: mutedSmallStyle),
                ),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    entry.stackTrace!,
                    style: TextStyle(
                      fontSize: 10,
                      fontFamily: 'monospace',
                      color: Colors.red[300],
                    ),
                  ),
                ),
              ],
              if (entry.protocolLog != null) ...[
                Padding(
                  padding: const EdgeInsets.only(
                    top: AppSpacing.sm,
                    bottom: AppSpacing.xs,
                  ),
                  child: Text('Protocol log', style: mutedSmallStyle),
                ),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    entry.protocolLog!,
                    style: const TextStyle(
                      fontSize: 10,
                      fontFamily: 'monospace',
                      color: Colors.greenAccent,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    final smallStyle = theme.textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          SizedBox(
            width: 180,
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
