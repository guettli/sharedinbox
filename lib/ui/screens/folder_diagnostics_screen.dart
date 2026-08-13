import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';

/// Runs [EmailRepository.diagnoseMailbox] for one folder. Keyed by
/// `(accountId, mailboxPath)` and auto-disposed so leaving the screen (or
/// pull-to-refresh via `ref.invalidate`) re-runs the live server check.
final folderDiagnosticsProvider = FutureProvider.autoDispose
    .family<MailboxDiagnostics, (String, String)>((ref, key) {
  final (accountId, mailboxPath) = key;
  final repo = ref.watch(emailRepositoryProvider);
  return repo.diagnoseMailbox(accountId, mailboxPath);
});

/// On-demand diagnostic for a single folder (long-press a folder → "Diagnose").
///
/// Lines up the cached folder count, the local cache and the server's live
/// view so the #511 symptom — a folder showing 0 while it actually holds mail —
/// is explained instead of silent.
class FolderDiagnosticsScreen extends ConsumerWidget {
  const FolderDiagnosticsScreen({
    super.key,
    required this.accountId,
    required this.mailboxPath,
  });

  final String accountId;
  final String mailboxPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (accountId, mailboxPath);
    final async = ref.watch(folderDiagnosticsProvider(key));
    final mailbox =
        ref.watch(mailboxByPathProvider((accountId, mailboxPath))).value;
    final title = mailbox?.displayPath ?? mailboxPath;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Folder diagnostics'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Run again',
            onPressed: () => ref.invalidate(folderDiagnosticsProvider(key)),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: AppSpacing.md),
              Text('Checking with the server…'),
            ],
          ),
        ),
        error: (e, _) => Center(child: Text('Diagnostic failed: $e')),
        data: (d) => _DiagnosticsBody(
          diagnostics: d,
          folderTitle: title,
          onRefetchCounts: () async {
            final messenger = ScaffoldMessenger.of(context);
            final repo = ref.read(mailboxRepositoryProvider);
            try {
              await repo.syncMailboxes(accountId);
            } catch (e) {
              messenger.showSnackBar(
                SnackBar(content: Text('Could not re-fetch counts: $e')),
              );
              return;
            }
            ref.invalidate(folderDiagnosticsProvider(key));
          },
          onForceResync: () => context.push(
            '/accounts/$accountId/mailboxes/'
            '${Uri.encodeComponent(mailboxPath)}/force-resync',
          ),
        ),
      ),
    );
  }
}

class _DiagnosticsBody extends StatelessWidget {
  const _DiagnosticsBody({
    required this.diagnostics,
    required this.folderTitle,
    required this.onRefetchCounts,
    required this.onForceResync,
  });

  final MailboxDiagnostics diagnostics;
  final String folderTitle;
  final VoidCallback onRefetchCounts;
  final VoidCallback onForceResync;

  String _cell(int? value) => value?.toString() ?? '—';

  String _plainReport() {
    final d = diagnostics;
    final buffer = StringBuffer()
      ..writeln('Folder diagnostics — $folderTitle (${d.protocol})')
      ..writeln('Path: ${d.mailboxPath}')
      ..writeln(
        'Cached count:  total ${d.cachedTotal}, unread ${d.cachedUnread}',
      )
      ..writeln(
        'Local cache:   ${d.localEmailRows} email(s), '
        '${d.localThreadRows} thread(s)',
      )
      ..writeln(
        'Server:        total ${_cell(d.serverTotal)}, '
        'unread ${_cell(d.serverUnread)}, '
        'lists ${_cell(d.serverMessageCount)} message(s)',
      )
      ..writeln('Missing locally: ${d.missingLocally.length}')
      ..writeln('Missing on server: ${d.missingOnServer.length}');
    if (d.error != null) buffer.writeln('Server error: ${d.error}');
    buffer.writeln();
    for (final c in d.conclusions) {
      buffer.writeln('• $c');
    }
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = diagnostics;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        Text(folderTitle, style: theme.textTheme.titleLarge),
        Text(
          '${d.protocol} · ${d.mailboxPath}',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: AppSpacing.lg),
        if (d.error != null) ...[
          Card(
            color: theme.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                children: [
                  Icon(
                    Icons.cloud_off,
                    color: theme.colorScheme.onErrorContainer,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      'Could not reach the server: ${d.error}',
                      style: TextStyle(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
        ],
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final c in d.conclusions) ...[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('•  '),
                      Expanded(child: Text(c)),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xs),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Table(
          border: TableBorder.all(color: theme.dividerColor),
          columnWidths: const {0: FlexColumnWidth(2)},
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            _row(theme, 'Source', 'Total', 'Unread', header: true),
            _row(theme, 'Cached', '${d.cachedTotal}', '${d.cachedUnread}'),
            _row(theme, 'Local cache', '${d.localEmailRows}', '—'),
            _row(theme, 'Server', _cell(d.serverTotal), _cell(d.serverUnread)),
            _row(theme, 'Server lists', _cell(d.serverMessageCount), '—'),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          'Local threads: ${d.localThreadRows} · '
          'Missing locally: ${d.missingLocally.length} · '
          'Missing on server: ${d.missingOnServer.length}',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: AppSpacing.lg),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            FilledButton.tonalIcon(
              onPressed: onRefetchCounts,
              icon: const Icon(Icons.sync),
              label: const Text('Re-fetch counts'),
            ),
            OutlinedButton.icon(
              onPressed: onForceResync,
              icon: const Icon(Icons.restart_alt),
              label: const Text('Resync this folder'),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _plainReport()));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Report copied')),
                  );
                }
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copy report'),
            ),
          ],
        ),
      ],
    );
  }

  TableRow _row(
    ThemeData theme,
    String source,
    String total,
    String unread, {
    bool header = false,
  }) {
    final style =
        header ? theme.textTheme.labelLarge : theme.textTheme.bodyMedium;
    return TableRow(
      decoration: header
          ? BoxDecoration(color: theme.colorScheme.surfaceContainerHighest)
          : null,
      children: [
        for (final cell in [source, total, unread])
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.xs,
            ),
            child: Text(cell, style: style),
          ),
      ],
    );
  }
}
