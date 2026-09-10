import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';

final _timeFmt = DateFormat('MMM d, HH:mm:ss');

class AppLogScreen extends ConsumerStatefulWidget {
  const AppLogScreen({
    super.key,
    this.initialSyncLogId,
    this.initialAccountId,
    this.initialEmailId,
  });

  /// When set, the screen opens pre-filtered to this sync cycle.
  final int? initialSyncLogId;

  /// When set, the screen opens pre-filtered to this account.
  final String? initialAccountId;

  /// When set, the screen opens pre-filtered to a single message — used by the
  /// "Show Logs" action on the email detail screen.
  final String? initialEmailId;

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
      emailId: widget.initialEmailId,
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
                        child: Text(
                          a.displayName.isNotEmpty
                              ? '${a.displayName} <${a.email}>'
                              : a.email,
                        ),
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
              if (filter.emailId != null)
                InputChip(
                  label: Text('email=${filter.emailId}'),
                  onDeleted: () =>
                      onChanged(filter.copyWith(clearEmailId: true)),
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

class _AppLogTile extends ConsumerWidget {
  const _AppLogTile({required this.entry});

  final AppLogEntry entry;

  /// Resolves [AppLogEntry.emailId] to its message and deep-links to it. The
  /// stored entry only carries the email id, so the account + mailbox needed
  /// to build the route are looked up at tap time; if the message has since
  /// been deleted or moved the lookup returns null and we say so.
  Future<void> _openEmail(BuildContext context, WidgetRef ref) async {
    final emailId = entry.emailId;
    if (emailId == null) return;
    final email = await ref.read(emailRepositoryProvider).getEmail(emailId);
    if (!context.mounted) return;
    if (email == null) {
      context.showAppSnackBar(
        'Message no longer available',
        level: AppLogLevel.warn,
        event: 'app_log.open_email_missing',
        emailId: emailId,
      );
      return;
    }
    await context.push(
      '/accounts/${email.accountId}/mailboxes'
      '/${Uri.encodeComponent(email.mailboxPath)}'
      '/emails/${Uri.encodeComponent(email.id)}',
    );
  }

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

  /// Splits [AppLogEntry.dataJson] into the stack trace (surfaced as its own
  /// section) and the remaining structured fields (the "Data" blob), so a trace
  /// is readable rather than buried inside one JSON string. Both are null when
  /// absent.
  ({String? stack, String? data}) get _parsedData {
    final raw = entry.dataJson;
    if (raw == null || raw.isEmpty) return (stack: null, data: null);
    try {
      final parsed = jsonDecode(raw);
      if (parsed is Map<String, dynamic>) {
        final stack = parsed.remove('stack')?.toString();
        final data = parsed.isEmpty
            ? null
            : const JsonEncoder.withIndent('  ').convert(parsed);
        return (stack: stack, data: data);
      }
      return (
        stack: null,
        data: const JsonEncoder.withIndent('  ').convert(parsed),
      );
    } catch (_) {
      return (stack: null, data: raw);
    }
  }

  /// Resolves [AppLogEntry.mailboxPath] to its hierarchical display path for the
  /// account, so JMAP opaque ids (e.g. "a") render as "Archive/2026". Falls
  /// back to the raw path when the mailbox is not in the local cache.
  String? _mailboxLabel(WidgetRef ref) {
    final rawPath = entry.mailboxPath;
    final accountId = entry.accountId;
    if (rawPath == null) return null;
    if (accountId == null) return rawPath;
    final mailbox =
        ref.watch(mailboxByPathProvider((accountId, rawPath))).valueOrNull;
    return mailbox?.displayPath ?? rawPath;
  }

  String _buildMarkdown(String? mailboxLabel) {
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
    if (mailboxLabel != null) {
      buf.writeln('| Mailbox | $mailboxLabel |');
    }
    if (entry.emailId != null) buf.writeln('| Email | ${entry.emailId} |');
    if (entry.syncLogId != null) {
      buf.writeln('| Sync log | ${entry.syncLogId} |');
    }
    final parsed = _parsedData;
    if (parsed.data != null) {
      buf
        ..writeln()
        ..writeln('```json')
        ..writeln(parsed.data)
        ..writeln('```');
    }
    if (parsed.stack != null) {
      buf
        ..writeln()
        ..writeln('### Stack trace')
        ..writeln()
        ..writeln('```')
        ..writeln(parsed.stack)
        ..writeln('```');
    }
    return buf.toString();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = _color(context);
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final muted = small?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final mailboxLabel = _mailboxLabel(ref);
    final badges = <String>[
      if (entry.screen != null) 'screen=${entry.screen}',
      if (entry.accountId != null) 'account=${entry.accountId}',
      if (mailboxLabel != null) 'mailbox=$mailboxLabel',
      if (entry.syncLogId != null) 'sync=${entry.syncLogId}',
    ];
    final parsed = _parsedData;

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
            if (badges.isNotEmpty || entry.emailId != null)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                child: Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final b in badges)
                      Chip(
                        label: Text(b, style: small),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    // Entries tied to one email link straight to that message.
                    if (entry.emailId != null)
                      ActionChip(
                        avatar: Icon(
                          Icons.open_in_new,
                          size: AppIconSize.sm,
                          color: theme.colorScheme.primary,
                        ),
                        label: Text('email=${entry.emailId}', style: small),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onPressed: () => unawaited(_openEmail(context, ref)),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: Text(entry.message, style: small),
            ),
            if (parsed.data != null) ...[
              Padding(
                padding: const EdgeInsets.only(
                  top: AppSpacing.xs,
                  bottom: AppSpacing.xs,
                ),
                child: Text('Data', style: muted),
              ),
              _MonoBlock(text: parsed.data!),
            ],
            if (parsed.stack != null) ...[
              Padding(
                padding: const EdgeInsets.only(
                  top: AppSpacing.xs,
                  bottom: AppSpacing.xs,
                ),
                child: Row(
                  children: [
                    Text('Stack trace', style: muted),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.copy, size: AppIconSize.sm),
                      tooltip: 'Copy stack trace',
                      visualDensity: VisualDensity.compact,
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: parsed.stack!),
                        );
                        if (!context.mounted) return;
                        context.showAppSnackBar(
                          'Stack trace copied',
                          event: 'app_log.stack_copied',
                          duration: const Duration(seconds: 2),
                        );
                      },
                    ),
                  ],
                ),
              ),
              _MonoBlock(text: parsed.stack!),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.copy, size: AppIconSize.sm),
                label: const Text('Copy'),
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: _buildMarkdown(mailboxLabel)),
                  );
                  if (!context.mounted) return;
                  context.showAppSnackBar(
                    'Copied to clipboard',
                    event: 'app_log.entry_copied',
                    duration: const Duration(seconds: 2),
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

/// A full-width monospace block on a dark background, used to render the JSON
/// "Data" payload and the stack trace of a log entry.
class _MonoBlock extends StatelessWidget {
  const _MonoBlock({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          fontFamily: 'monospace',
          color: Colors.greenAccent,
        ),
      ),
    );
  }
}
