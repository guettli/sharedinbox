import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/di.dart';

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

    return ListTile(
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
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(sender, maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(
            '${action.type.name.toUpperCase()} from ${action.sourceMailboxPath} • ${_timeFmt.format(action.timestamp.toLocal())}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      trailing: TextButton(
        onPressed: () async {
          await ref
              .read(undoServiceProvider.notifier)
              .undo(actionId: action.id);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                duration: Duration(seconds: 5),
                content: Text('Action undone.'),
              ),
            );
          }
        },
        child: const Text('Undo'),
      ),
    );
  }
}
