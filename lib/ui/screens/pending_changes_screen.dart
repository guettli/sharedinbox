import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/pending_change.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/utils/format_utils.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/outbox_screen.dart'
    show QueueRowActions, SyncNowFn, retryQueueRow;
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';

final _dateFmt = DateFormat('MMM d, HH:mm');

/// Global list of the outbound queue (`pending_changes`) across all accounts,
/// grouped by account. Each row shows the concrete mutation, the affected
/// email (subject and sender), age, attempt count, and last error. Tapping a
/// row opens a copyable detail view (all stored fields plus the decoded
/// payload) for filing bug reports. Actions:
///
///  * **Retry now** — for a failed change, queues it again at the end of the
///    queue (fresh attempt/error state) and shows its effect locally again;
///    for a change still queued, keeps its place. Either way asks the sync
///    manager to flush the account immediately.
///  * **Discard**  — drops the row from the queue. A failed change already
///    shows the server's state again; a change still queued (or not synced
///    yet) is first undone locally, like a failure, so the mail does not keep
///    a state the server never gets (SYNC.md §6).
///
/// A failed change (given up on, no longer flushed) is marked as such; one
/// with an error that is not failed yet is still being retried.
class PendingChangesScreen extends ConsumerWidget {
  const PendingChangesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rowsAsync = ref.watch(allPendingChangesProvider);
    final accountsAsync = ref.watch(allAccountsProvider);
    final repo = ref.watch(emailRepositoryProvider);
    final syncNow = ref.read(syncNowProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Pending Changes')),
      body: rowsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: ${userErrorMessage(e)}')),
        data: (rows) {
          if (rows.isEmpty) {
            return const Center(child: Text('No pending changes.'));
          }
          final accounts = accountsAsync.value ?? const <Account>[];
          final accountsById = {for (final a in accounts) a.id: a};
          final grouped = _groupByAccount(rows);
          return ListView(
            children: [
              for (final entry in grouped.entries)
                _AccountGroup(
                  account: accountsById[entry.key],
                  accountId: entry.key,
                  changes: entry.value,
                  repo: repo,
                  syncNow: syncNow,
                ),
            ],
          );
        },
      ),
    );
  }

  static Map<String, List<PendingChange>> _groupByAccount(
    List<PendingChange> rows,
  ) {
    final out = <String, List<PendingChange>>{};
    for (final r in rows) {
      out.putIfAbsent(r.accountId, () => []).add(r);
    }
    return out;
  }
}

class _AccountGroup extends StatelessWidget {
  const _AccountGroup({
    required this.account,
    required this.accountId,
    required this.changes,
    required this.repo,
    required this.syncNow,
  });

  final Account? account;
  final String accountId;
  final List<PendingChange> changes;
  final EmailRepository repo;
  final SyncNowFn syncNow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = account?.displayName.isNotEmpty ?? false
        ? account!.displayName
        : (account?.email ?? accountId);
    final type = (account?.type ?? AccountType.imap).name.toUpperCase();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: theme.colorScheme.surfaceContainerHighest,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '$label • $type',
                  style: theme.textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Badge(label: Text('${changes.length}')),
            ],
          ),
        ),
        for (final c in changes)
          PendingChangeTile(
            change: c,
            repo: repo,
            syncNow: syncNow,
          ),
        const Divider(height: 1),
      ],
    );
  }
}

/// Individual pending-change row. Extracted so widget tests can construct it
/// in isolation without a full router/scope.
class PendingChangeTile extends StatelessWidget {
  const PendingChangeTile({
    super.key,
    required this.change,
    required this.repo,
    required this.syncNow,
  });

  final PendingChange change;
  final EmailRepository repo;
  final SyncNowFn syncNow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      onTap: () => _showChangeDetails(context, change),
      leading: Icon(
        _statusIcon(change),
        color: change.hasError ? theme.colorScheme.error : null,
      ),
      title: Text(describeChange(change)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _EmailIdentity(change: change, repo: repo),
          Text(
            'Queued: ${_dateFmt.format(change.createdAt.toLocal())}'
            ' • age ${_formatAge(DateTime.now().difference(change.createdAt))}'
            ' • ${attemptsLabel(change)}',
            style: theme.textTheme.bodySmall,
          ),
          if (change.lastError != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: InkWell(
                onTap: () => _showChangeDetails(context, change),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Last error: ${change.lastError}',
                      style: TextStyle(color: theme.colorScheme.error),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      'Tap for details',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
      // A change being sent can be neither retried nor discarded: it may be
      // reaching the server right now.
      trailing: change.sending
          ? null
          : QueueRowActions(
              onRetry: () => retryQueueRow(
                context: context,
                accountId: change.accountId,
                retry: () => repo.retryMutation(change.id),
                syncNow: syncNow,
                runningMessage: 'Retrying change…',
                notRunningMessage: 'Sync is not running for this account. '
                    'Enable it so the change can be applied.',
              ),
              onDiscard: () => unawaited(repo.discardMutation(change.id)),
            ),
    );
  }
}

IconData _statusIcon(PendingChange change) {
  if (change.failed) return Icons.error;
  if (change.hasError) return Icons.sync_problem;
  return Icons.sync;
}

/// Where [change] stands: given up on, still retrying after an error, or
/// queued.
String attemptsLabel(PendingChange change) {
  final n = change.attempts;
  if (change.failed && n < maxPendingChangeAttempts) {
    // Given up on before the retry limit: refused, or nothing to act on.
    return 'rejected by the server';
  }
  if (change.failed) return 'failed after $n attempts';
  if (change.sending) return 'sending…';
  if (change.parked) return 'waiting for the server copy of this mail';
  if (change.waitingForFolder case final folder?) {
    return 'waiting for folder "$folder" to be created';
  }
  if (change.stuck) {
    final next = change.nextTry?.toLocal();
    if (next == null) return 'not synced yet';
    final hhmm = '${next.hour.toString().padLeft(2, '0')}:'
        '${next.minute.toString().padLeft(2, '0')}';
    return 'not synced yet – next try $hhmm';
  }
  if (change.hasError) {
    return '$n of $maxPendingChangeAttempts attempts failed – retrying';
  }
  return 'attempts $n';
}

/// Opens a dialog with the full technical detail of [change] — every field the
/// sync layer stores, the pretty-printed protocol payload, and the complete
/// last error. The text is selectable and a single **Copy** action yields a
/// ready-to-paste block for a bug report (issue #746).
Future<void> _showChangeDetails(BuildContext context, PendingChange change) {
  final report = changeReport(change);
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Change details'),
      content: SingleChildScrollView(
        child: SelectableText(
          report,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: report));
            if (dialogContext.mounted) {
              dialogContext.showAppSnackBar('Copied to clipboard');
            }
          },
          child: const Text('Copy'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

/// Builds the plain-text detail block shown by [_showChangeDetails] and copied
/// into bug reports. Pure (no `BuildContext`) so it can be unit-tested and so
/// the exact wording stays stable for the people pasting it into issues.
String changeReport(PendingChange change) {
  return (StringBuffer()
        ..writeln('Pending change #${change.id}')
        ..writeln('Account:    ${change.accountId}')
        ..writeln('Kind:       ${change.kind} (${kindLabel(change.kind)})')
        ..writeln('Summary:    ${describeChange(change)}')
        ..writeln('Resource:   ${change.resourceType} ${change.resourceId}')
        ..writeln('Queued:     ${change.createdAt.toUtc().toIso8601String()}')
        ..writeln('Attempts:   ${change.attempts}')
        ..writeln(
          'State:      '
          '${change.failed ? 'failed' : change.sending ? 'inflight' : change.stuck ? 'stuck' : change.parked ? 'parked' : 'pending'}',
        )
        ..writeln('Payload:    ${_prettyPayload(change.payload)}')
        ..write('Last error: ${change.lastError ?? '(none)'}'))
      .toString();
}

/// Pretty-prints the protocol-specific JSON [payload] for the detail view.
/// Falls back to the raw string when it isn't valid JSON.
String _prettyPayload(String payload) {
  if (payload.isEmpty) return '(empty)';
  try {
    return const JsonEncoder.withIndent('  ').convert(jsonDecode(payload));
  } catch (_) {
    return payload;
  }
}

/// Human-readable label for the `change_type` column stored in the DB.
String kindLabel(String kind) {
  return switch (kind) {
    'flag_seen' => 'Mark read/unread',
    'flag_flagged' => 'Toggle flag',
    'add_keywords' => 'Add keywords',
    'move' => 'Move',
    'delete' => 'Delete',
    'append' => 'Append',
    'clear_snooze' => 'Clear snooze',
    'create_mailbox' => 'Create folder',
    'rename_mailbox' => 'Rename folder',
    'move_mailbox' => 'Move folder',
    'delete_mailbox' => 'Delete folder',
    _ => kind,
  };
}

/// Describes the concrete mutation a change will apply, decoded from its
/// protocol-specific JSON `payload`: the new read/flag state for flag changes,
/// or the `src → dest` mailbox move for move/delete operations. Falls back to
/// the plain [kindLabel] when the payload is missing or can't be parsed.
String describeChange(PendingChange change) {
  final payload = _decodePayload(change.payload);
  switch (change.kind) {
    case 'flag_seen':
      final seen = payload['seen'];
      if (seen is bool) return seen ? 'Mark as read' : 'Mark as unread';
      return 'Mark read/unread';
    case 'flag_flagged':
      final flagged = payload['flagged'];
      if (flagged is bool) return flagged ? 'Add flag' : 'Remove flag';
      return 'Toggle flag';
    case 'add_keywords':
      final keywords = payload['keywords'];
      if (keywords is List && keywords.isNotEmpty) {
        return 'Add keywords: ${keywords.join(', ')}';
      }
      return 'Add keywords';
    case 'move':
      final src = _folder(change, payload['src']);
      final dest = _folder(change, payload['dest']);
      if (src != null && dest != null) return 'Move: $src → $dest';
      if (dest != null) return 'Move to $dest';
      return 'Move';
    case 'delete':
      final from = _folder(change, payload['mailboxPath']);
      return from != null ? 'Delete from $from' : 'Delete';
    case 'create_mailbox':
      final name = _string(payload['name']);
      return name != null ? 'Create folder "$name"' : 'Create folder';
    case 'rename_mailbox':
      final name = _string(payload['name']);
      return name != null ? 'Rename folder to "$name"' : 'Rename folder';
    case 'move_mailbox':
      // The parent is a folder path (on JMAP an opaque id): shown only to
      // tell the top level apart.
      return payload.containsKey('parent') && payload['parent'] == null
          ? 'Move folder to the top level'
          : 'Move folder';
    case 'delete_mailbox':
      return payload['removeEmails'] == true
          ? 'Delete folder and its mail'
          : 'Delete folder';
    default:
      return kindLabel(change.kind);
  }
}

Map<String, dynamic> _decodePayload(String payload) {
  if (payload.isEmpty) return const {};
  try {
    final decoded = jsonDecode(payload);
    if (decoded is Map<String, dynamic>) return decoded;
  } catch (_) {
    // Ignore — payloads are protocol-specific; the DB-level shape isn't
    // guaranteed here and this string is only for display.
  }
  return const {};
}

String? _string(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

/// The folder at path [value] of [change]'s payload, by the name the folder
/// list shows: a folder created offline and renamed before it reached the
/// server still has the path it was created with (#1335).
String? _folder(PendingChange change, Object? value) {
  final path = _string(value);
  if (path == null) return null;
  return change.folderNames[path] ?? path;
}

/// Resolves the pending change's email into a human-readable `subject · sender`
/// line. Falls back to the change's [PendingChange.subject] while the lookup
/// is in flight or when the referenced email is not shown (or no longer
/// stored locally), and to the raw resource id without one.
class _EmailIdentity extends StatelessWidget {
  const _EmailIdentity({required this.change, required this.repo});

  final PendingChange change;
  final EmailRepository repo;

  // The mail is not shown (gone on the server, waiting for its changes to
  // settle, or removed): its subject still names it (#1327).
  String get _fallback => switch (change.resourceType) {
        'Email' when change.subject != null => change.subject!,
        'Email' => 'email ${change.resourceId}',
        'Mailbox' when change.folderName != null =>
          'folder "${change.folderName}"',
        'Mailbox' => 'folder',
        _ => '${change.resourceType} ${change.resourceId}',
      };

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Email?>(
      future: repo.getEmail(change.resourceId),
      builder: (context, snapshot) {
        final email = snapshot.data;
        if (email == null) {
          // The email is no longer stored locally (or the lookup is still in
          // flight), so there is no mailbox to build a message URL from.
          return Text(
            _fallback,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
        }
        final theme = Theme.of(context);
        return InkWell(
          onTap: () => context.push(
            '/accounts/${email.accountId}/mailboxes'
            '/${Uri.encodeComponent(email.mailboxPath)}'
            '/emails/${Uri.encodeComponent(email.id)}',
          ),
          child: Text(
            _describeEmail(email),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: theme.colorScheme.primary,
              decoration: TextDecoration.underline,
            ),
          ),
        );
      },
    );
  }

  static String _describeEmail(Email email) {
    final subject = email.subject ?? '(no subject)';
    final sender = email.from.isNotEmpty
        ? (email.from.first.name ?? email.from.first.email)
        : null;
    return sender == null ? subject : '$subject · $sender';
  }
}

String _formatAge(Duration age) {
  if (age.inDays >= 1) return '${age.inDays}d';
  if (age.inHours >= 1) return '${age.inHours}h';
  if (age.inMinutes >= 1) return '${age.inMinutes}m';
  if (age.inSeconds >= 1) return '${age.inSeconds}s';
  return 'just now';
}
