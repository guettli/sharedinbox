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

class UndoLogScreen extends ConsumerWidget {
  const UndoLogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(undoServiceProvider).reversed.toList();

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
              itemCount: history.length,
              itemBuilder: (ctx, i) => _UndoActionTile(action: history[i]),
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
