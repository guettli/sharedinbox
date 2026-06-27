import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';

final _timeFmt = DateFormat('MMM d, HH:mm:ss');

class AppLogScreen extends ConsumerStatefulWidget {
  const AppLogScreen({
    super.key,
    this.initialSyncLogId,
    this.initialAccountId,
  });

  /// When set, the screen opens pre-filtered to this sync cycle.
  final int? initialSyncLogId;

  /// When set, the screen opens pre-filtered to this account.
  final String? initialAccountId;

  @override
  ConsumerState<AppLogScreen> createState() => _AppLogScreenState();
}

class _AppLogScreenState extends ConsumerState<AppLogScreen> {
  final _searchCtrl = TextEditingController();
  late AppLogFilter _filter;

  @override
  void initState() {
    super.initState();
    _filter = AppLogFilter(
      syncLogId: widget.initialSyncLogId,
      accountId: widget.initialAccountId,
    );
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _updateFilter(AppLogFilter next) {
    setState(() => _filter = next);
  }

  Future<void> _confirmClear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear application log?'),
        content: const Text('This permanently deletes every log entry.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(appLogRepositoryProvider).clearAll();
    }
  }

  @override
  Widget build(BuildContext context) {
    final entriesAsync = ref.watch(appLogEntriesProvider(_filter));
    final accountsAsync = ref.watch(allAccountsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Application log'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear log',
            onPressed: () => _confirmClear(context),
          ),
        ],
      ),
      body: Column(
        children: [
          _FilterBar(
            filter: _filter,
            accounts: accountsAsync.value ?? const [],
            searchCtrl: _searchCtrl,
            onChanged: _updateFilter,
          ),
          const Divider(height: 1),
          Expanded(
            child: entriesAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Error: $e')),
              data: (entries) {
                if (entries.isEmpty) {
                  return const Center(child: Text('No log entries'));
                }
                return ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (ctx, i) => _AppLogTile(entry: entries[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.filter,
    required this.accounts,
    required this.searchCtrl,
    required this.onChanged,
  });

  final AppLogFilter filter;
  final List<Account> accounts;
  final TextEditingController searchCtrl;
  final ValueChanged<AppLogFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final level in AppLogLevel.values)
                FilterChip(
                  label: Text(level.wireName),
                  selected: filter.levels.contains(level),
                  onSelected: (on) {
                    final next = Set<AppLogLevel>.of(filter.levels);
                    on ? next.add(level) : next.remove(level);
                    onChanged(filter.copyWith(levels: next));
                  },
                ),
              if (accounts.length > 1)
                DropdownButton<String?>(
                  value: filter.accountId,
                  hint: const Text('All accounts'),
                  items: [
                    const DropdownMenuItem<String?>(
                      child: Text('All accounts'),
                    ),
                    for (final a in accounts)
                      DropdownMenuItem<String?>(
                        value: a.id,
                        child: Text(a.email),
                      ),
                  ],
                  onChanged: (value) {
                    onChanged(
                      value == null
                          ? filter.copyWith(clearAccountId: true)
                          : filter.copyWith(accountId: value),
                    );
                  },
                ),
              if (filter.syncLogId != null)
                InputChip(
                  label: Text('sync #${filter.syncLogId}'),
                  onDeleted: () =>
                      onChanged(filter.copyWith(clearSyncLogId: true)),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: TextField(
              controller: searchCtrl,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Search event or message',
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: searchCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          searchCtrl.clear();
                          onChanged(filter.copyWith(clearSearch: true));
                        },
                      ),
              ),
              onChanged: (value) {
                final trimmed = value.trim();
                onChanged(
                  trimmed.isEmpty
                      ? filter.copyWith(clearSearch: true)
                      : filter.copyWith(search: trimmed),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _AppLogTile extends StatelessWidget {
  const _AppLogTile({required this.entry});

  final AppLogEntry entry;

  IconData get _icon => switch (entry.level) {
        AppLogLevel.debug => Icons.bug_report_outlined,
        AppLogLevel.info => Icons.info_outline,
        AppLogLevel.warn => Icons.warning_amber_outlined,
        AppLogLevel.error => Icons.error_outline,
      };

  Color _color(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return switch (entry.level) {
      AppLogLevel.debug => cs.onSurfaceVariant,
      AppLogLevel.info => cs.primary,
      AppLogLevel.warn => Colors.orange,
      AppLogLevel.error => cs.error,
    };
  }

  String? get _prettyData {
    final raw = entry.dataJson;
    if (raw == null || raw.isEmpty) return null;
    try {
      final parsed = jsonDecode(raw);
      return const JsonEncoder.withIndent('  ').convert(parsed);
    } catch (_) {
      return raw;
    }
  }

  String _buildMarkdown() {
    final buf = StringBuffer()
      ..writeln('## ${entry.level.wireName.toUpperCase()} · ${entry.event}')
      ..writeln()
      ..writeln('| Property | Value |')
      ..writeln('|----------|-------|')
      ..writeln('| Time | ${_timeFmt.format(entry.createdAt)} |')
      ..writeln('| Message | ${entry.message} |');
    if (entry.screen != null) buf.writeln('| Screen | ${entry.screen} |');
    if (entry.accountId != null) {
      buf.writeln('| Account | ${entry.accountId} |');
    }
    if (entry.mailboxPath != null) {
      buf.writeln('| Mailbox | ${entry.mailboxPath} |');
    }
    if (entry.emailId != null) buf.writeln('| Email | ${entry.emailId} |');
    if (entry.syncLogId != null) {
      buf.writeln('| Sync log | ${entry.syncLogId} |');
    }
    final data = _prettyData;
    if (data != null) {
      buf
        ..writeln()
        ..writeln('```json')
        ..writeln(data)
        ..writeln('```');
    }
    return buf.toString();
  }

  @override
  Widget build(BuildContext context) {
    final color = _color(context);
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final muted = small?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final badges = <String>[
      if (entry.screen != null) 'screen=${entry.screen}',
      if (entry.accountId != null) 'account=${entry.accountId}',
      if (entry.mailboxPath != null) 'mailbox=${entry.mailboxPath}',
      if (entry.emailId != null) 'email=${entry.emailId}',
      if (entry.syncLogId != null) 'sync=${entry.syncLogId}',
    ];
    final data = _prettyData;

    return ExpansionTile(
      leading: Icon(_icon, color: color),
      title: Text(
        '${_timeFmt.format(entry.createdAt)} · ${entry.event}',
        style: TextStyle(color: color),
      ),
      subtitle: Text(
        entry.message,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: small,
      ),
      childrenPadding:
          const EdgeInsets.fromLTRB(72, 0, AppSpacing.lg, AppSpacing.md),
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (badges.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                child: Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xs,
                  children: [
                    for (final b in badges)
                      Chip(
                        label: Text(b, style: small),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: Text(entry.message, style: small),
            ),
            if (data != null) ...[
              Padding(
                padding: const EdgeInsets.only(
                  top: AppSpacing.xs,
                  bottom: AppSpacing.xs,
                ),
                child: Text('Data', style: muted),
              ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppSpacing.sm),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  data,
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: Colors.greenAccent,
                  ),
                ),
              ),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.copy, size: AppIconSize.sm),
                label: const Text('Copy'),
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: _buildMarkdown()),
                  );
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      duration: Duration(seconds: 2),
                      content: Text('Copied to clipboard'),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}
