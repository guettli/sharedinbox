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
                : () => ref.read(undoServiceProvider.notifier).clear(),
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
    return ListTile(
      leading: Icon(
        action.type == UndoType.delete
            ? Icons.delete_outline
            : Icons.move_to_inbox,
        color: action.type == UndoType.delete
            ? Colors.redAccent
            : Colors.blueAccent,
      ),
      title: Text(action.description),
      subtitle: Text(_timeFmt.format(action.timestamp.toLocal())),
      trailing: TextButton(
        onPressed: () async {
          // In a real log, "undoing" an old action might be complex
          // if subsequent actions conflict. For now, we only support
          // undoing the LATEST action via the global UndoService.
          // To keep it simple, we check if this is the latest action.
          final history = ref.read(undoServiceProvider);
          final latest = history.isNotEmpty ? history.last : null;
          if (latest?.id == action.id) {
            await ref.read(undoServiceProvider.notifier).undo();
          } else {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Only the latest action can be undone.'),
                ),
              );
            }
          }
        },
        child: const Text('Undo'),
      ),
    );
  }
}
