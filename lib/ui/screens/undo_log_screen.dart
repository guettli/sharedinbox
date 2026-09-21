import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';

final _timeFmt = DateFormat('HH:mm:ss');
final _dayFmt = DateFormat.yMMMEd();

/// A day header string ("Today", "Yesterday" or an absolute date) so a long
/// log spanning several days can be told apart at a glance.
String _dayLabel(DateTime day, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  return _dayFmt.format(day);
}

/// Splits [history] (newest first) into a flat list of day-header strings and
/// the actions that fall under each local calendar day, preserving order.
List<Object> _groupByDay(List<UndoAction> history, DateTime now) {
  final items = <Object>[];
  DateTime? currentDay;
  for (final action in history) {
    final local = action.timestamp.toLocal();
    final day = DateTime(local.year, local.month, local.day);
    if (currentDay == null || day != currentDay) {
      currentDay = day;
      items.add(_dayLabel(day, now));
    }
    items.add(action);
  }
  return items;
}

class UndoLogScreen extends ConsumerWidget {
  const UndoLogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(undoServiceProvider).reversed.toList();
    final items = _groupByDay(history, DateTime.now());

    return Scaffold(
      appBar: AppBar(
        title: const Text('Undo Log'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: 'Clear history',
            onPressed: history.isEmpty
                ? null
                : () =>
                    unawaited(ref.read(undoServiceProvider.notifier).clear()),
          ),
        ],
      ),
      body: history.isEmpty
          ? const Center(child: Text('No undoable actions in history'))
          : ListView.builder(
              itemCount: items.length,
              itemBuilder: (ctx, i) {
                final item = items[i];
                return item is String
                    ? _DayHeader(label: item)
                    : _UndoActionTile(action: item as UndoAction);
              },
            ),
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        label,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _UndoActionTile extends ConsumerWidget {
  const _UndoActionTile({required this.action});

  final UndoAction action;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final firstEmail = action.originalEmails.firstOrNull;
    final subject = firstEmail?.subject ?? '(No Subject)';
    final sender = firstEmail != null && firstEmail.from.isNotEmpty
        ? (firstEmail.from.first.name ?? firstEmail.from.first.email)
        : '(Unknown Sender)';
    final count = action.emailIds.length;
    final extraCount = count > 1 ? ' (+${count - 1} more)' : '';
    final account = ref.watch(accountByIdProvider(action.accountId)).value;

    return ListTile(
      onTap: () => context.go(
        '/accounts/undo-log/${action.id}',
        extra: action,
      ),
      leading: Icon(
        action.type == UndoType.delete
            ? Icons.delete_outline
            : (action.type == UndoType.snooze
                ? Icons.access_time
                : Icons.move_to_inbox),
        color: action.type == UndoType.delete
            ? Colors.redAccent
            : (action.type == UndoType.snooze
                ? Colors.orangeAccent
                : Colors.blueAccent),
      ),
      title: Text('$subject$extraCount'),
      subtitle: StreamBuilder<List<Mailbox>>(
        stream: ref
            .watch(mailboxRepositoryProvider)
            .observeMailboxes(action.accountId),
        builder: (ctx, snap) {
          final mailboxes = snap.data ?? const <Mailbox>[];
          // Move shows the destination (what the user just chose); delete /
          // snooze have no destination and keep the source for context.
          final label = action.type == UndoType.move &&
                  action.destinationMailboxPath != null
              ? 'MOVE to ${resolveMailboxDisplayPath(mailboxes, action.destinationMailboxPath!)}'
              : '${action.type.name.toUpperCase()} from ${resolveMailboxDisplayPath(mailboxes, action.sourceMailboxPath)}';
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(sender, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(
                '$label • ${_timeFmt.format(action.timestamp.toLocal())}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Text(
                accountDisplayLabel(account, action.accountId),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          );
        },
      ),
      trailing: TextButton(
        onPressed: () async {
          await ref
              .read(undoServiceProvider.notifier)
              .undo(actionId: action.id);
          if (context.mounted) {
            context.showAppSnackBar(
              'Action undone.',
              duration: const Duration(seconds: 5),
            );
          }
        },
        child: const Text('Undo'),
      ),
    );
  }
}
