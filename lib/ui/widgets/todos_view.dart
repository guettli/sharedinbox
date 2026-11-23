import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/entry.dart';
import 'package:sharedinbox/core/models/user_preferences.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/core/utils/format_utils.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';
import 'package:sharedinbox/ui/widgets/quick_add_field.dart';

/// The todos (entries with a `task`) of every unlocked account (#1357):
/// filters open / today / done, quick-add and a tick per row. New todos go
/// to the default account for new items, else [accountId] (the open one).
class TodosView extends ConsumerStatefulWidget {
  const TodosView({super.key, required this.accountId});

  final String accountId;

  @override
  ConsumerState<TodosView> createState() => _TodosViewState();
}

class _TodosViewState extends ConsumerState<TodosView> {
  final _quickAdd = TextEditingController();
  TodoFilter _filter = TodoFilter.open;

  @override
  void dispose() {
    _quickAdd.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final today = isoDate(ref.watch(todayProvider)());
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            0,
          ),
          child: SegmentedButton<TodoFilter>(
            segments: const [
              ButtonSegment(
                value: TodoFilter.open,
                label: Text('Open', key: Key('todosFilter_open')),
              ),
              ButtonSegment(
                value: TodoFilter.today,
                label: Text('Today', key: Key('todosFilter_today')),
              ),
              ButtonSegment(
                value: TodoFilter.done,
                label: Text('Done', key: Key('todosFilter_done')),
              ),
            ],
            selected: {_filter},
            onSelectionChanged: (s) => setState(() => _filter = s.single),
          ),
        ),
        QuickAddField(
          fieldKey: const Key('todosQuickAdd'),
          sendKey: const Key('todosQuickAddSend'),
          controller: _quickAdd,
          hintText: 'Add a todo',
          onAdd: _add,
        ),
        Expanded(child: _list(today)),
      ],
    );
  }

  Widget _list(String today) {
    final todos = ref.watch(todosProvider((_filter, today)));
    final accounts = ref.watch(allAccountsProvider).value ?? const [];
    final unlocked =
        ref.watch(unlockedPersonalDataAccountsProvider).value ?? const [];
    return todos.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: ${userErrorMessage(e)}')),
      data: (list) {
        if (list.isEmpty) {
          return Center(
            child: Text(
              switch (_filter) {
                TodoFilter.open => 'No open todos.',
                TodoFilter.today => 'Nothing due today.',
                TodoFilter.done => 'No done todos yet.',
              },
            ),
          );
        }
        return ListView.builder(
          itemCount: list.length,
          itemBuilder: (_, i) {
            final todo = list[i];
            final account =
                accounts.where((a) => a.id == todo.accountId).firstOrNull;
            return _TodoTile(
              todo: todo,
              today: today,
              accountLabel: unlocked.length > 1
                  ? (account?.email ?? todo.accountId)
                  : null,
              onTick: () => _tick(todo),
              onTap: () => context.push(
                '/accounts/${todo.accountId}/entries/${todo.itemId}',
              ),
              onResolve: () => context.push(
                '/accounts/${todo.accountId}/conflicts/${todo.itemHmac}',
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _add() async {
    final body = _quickAdd.text;
    if (body.trim().isEmpty) return;
    _quickAdd.clear();
    final prefs = await ref
        .read(userPreferencesRepositoryProvider)
        .observePreferences()
        .first;
    final unlocked =
        ref.read(unlockedPersonalDataAccountsProvider).value ?? const [];
    final accountId = resolveNewItemAccount(
      prefs,
      unlocked,
      currentAccountId: widget.accountId,
    );
    if (accountId == null) return _locked(body);
    try {
      await ref
          .read(entryRepositoryProvider)
          .create(accountId, body: body, task: const EntryTask());
    } on NoWriteKeyException {
      _locked(body);
    }
  }

  /// Puts [body] back and asks to unlock.
  void _locked(String body) {
    if (!mounted) return;
    _quickAdd.text = body;
    context.showAppSnackBar('Unlock personal data to add todos.');
  }

  Future<void> _tick(Entry todo) async {
    final task = todo.task!;
    try {
      await ref.read(entryRepositoryProvider).setTask(
            todo.accountId,
            todo.itemId,
            task.copyWith(done: !task.done),
          );
    } catch (e) {
      if (!mounted) return;
      context.showAppSnackBar('Could not save: ${userErrorMessage(e)}');
    }
  }
}

class _TodoTile extends StatelessWidget {
  const _TodoTile({
    required this.todo,
    required this.today,
    required this.accountLabel,
    required this.onTick,
    required this.onTap,
    required this.onResolve,
  });

  final Entry todo;
  final String today;

  /// Shown while todos of several accounts are listed.
  final String? accountLabel;
  final VoidCallback onTick;
  final VoidCallback onTap;
  final VoidCallback onResolve;

  @override
  Widget build(BuildContext context) {
    final task = todo.task!;
    final due = task.due;
    final overdue = !task.done && due != null && due.compareTo(today) < 0;
    final colors = Theme.of(context).colorScheme;
    final label = accountLabel;
    return ListTile(
      key: Key('todo_${todo.itemId}'),
      leading: Checkbox(
        key: Key('todoTick_${todo.itemId}'),
        value: task.done,
        onChanged: (_) => onTick(),
      ),
      title: Text(
        todo.displayTitle.isEmpty ? '(empty)' : todo.displayTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: task.done
            ? const TextStyle(decoration: TextDecoration.lineThrough)
            : null,
      ),
      subtitle: due == null && label == null
          ? null
          : Wrap(
              spacing: AppSpacing.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (due != null)
                  Text(
                    'Due $due',
                    key: Key('todoDue_${todo.itemId}'),
                    style: overdue ? TextStyle(color: colors.error) : null,
                  ),
                if (label != null)
                  Chip(
                    key: Key('todoAccount_${todo.itemId}'),
                    label: Text(label),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
      onTap: onTap,
      trailing: todo.hasConflict
          ? IconButton(
              key: Key('entryConflict_${todo.itemId}'),
              tooltip: 'Edited on several devices — resolve',
              icon: Icon(Icons.call_split, color: colors.error),
              onPressed: onResolve,
            )
          : null,
    );
  }
}
