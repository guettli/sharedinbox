import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:sharedinbox/core/models/entry.dart';
import 'package:sharedinbox/core/models/user_preferences.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/core/services/encrypted_key_service.dart';
import 'package:sharedinbox/core/utils/format_utils.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';

/// The entries home (ENCRYPTED-OBJECTS.md 9, #1373): search, quick-add and
/// the list of entries, newest first. Behind the "Personal data (beta)"
/// switch, and only while the account is unlocked on this device.
class EntriesScreen extends ConsumerStatefulWidget {
  const EntriesScreen({super.key, required this.accountId});

  final String accountId;

  @override
  ConsumerState<EntriesScreen> createState() => _EntriesScreenState();
}

class _EntriesScreenState extends ConsumerState<EntriesScreen> {
  final _search = TextEditingController();
  final _quickAdd = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    _quickAdd.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Entries')),
      body: PersonalDataGate(
        accountId: widget.accountId,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.lg,
                0,
              ),
              child: TextField(
                key: const Key('entriesSearch'),
                controller: _search,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search entries',
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('entriesQuickAdd'),
                      controller: _quickAdd,
                      decoration: const InputDecoration(
                        hintText: 'Quick add',
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _add(),
                    ),
                  ),
                  IconButton(
                    key: const Key('entriesQuickAddSend'),
                    icon: const Icon(Icons.send),
                    tooltip: 'Add',
                    onPressed: _add,
                  ),
                ],
              ),
            ),
            Expanded(child: _list()),
          ],
        ),
      ),
    );
  }

  Widget _list() {
    final entries = ref.watch(entriesProvider((widget.accountId, _query)));
    return entries.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: ${userErrorMessage(e)}')),
      data: (list) {
        if (list.isEmpty) {
          return Center(
            child:
                Text(_query.trim().isEmpty ? 'No entries yet.' : 'No match.'),
          );
        }
        return ListView.builder(
          itemCount: list.length,
          itemBuilder: (_, i) => _EntryTile(
            entry: list[i],
            onTap: () => context.push(
              '/accounts/${widget.accountId}/entries/${list[i].itemId}',
            ),
            onDelete: () => _delete(list[i]),
          ),
        );
      },
    );
  }

  Future<void> _add() async {
    final body = _quickAdd.text;
    if (body.trim().isEmpty) return;
    _quickAdd.clear();
    try {
      await ref
          .read(entryRepositoryProvider)
          .create(widget.accountId, body: body);
    } on NoWriteKeyException {
      if (!mounted) return;
      _quickAdd.text = body;
      context.showAppSnackBar('Unlock personal data to add entries.');
    }
  }

  Future<void> _delete(Entry entry) async {
    if (!await confirmDeleteEntry(context, entry) || !mounted) return;
    try {
      await ref
          .read(entryRepositoryProvider)
          .delete(widget.accountId, entry.itemId);
    } catch (e) {
      if (!mounted) return;
      context.showAppSnackBar('Could not delete: ${userErrorMessage(e)}');
    }
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.onTap,
    required this.onDelete,
  });

  final Entry entry;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final preview = entry.preview;
    final updated =
        DateFormat.yMMMd().add_Hm().format(entry.updatedAt.toLocal());
    return ListTile(
      key: Key('entry_${entry.itemId}'),
      title: Text(
        entry.displayTitle.isEmpty ? '(empty)' : entry.displayTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        preview.isEmpty ? updated : '$preview\n$updated',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: preview.isNotEmpty,
      onTap: onTap,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (entry.hasConflict)
            Tooltip(
              message: 'Edited on several devices at once; saving resolves it',
              child: Icon(
                Icons.call_split,
                key: Key('entryConflict_${entry.itemId}'),
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          PopupMenuButton<String>(
            key: Key('entryMenu_${entry.itemId}'),
            onSelected: (_) => onDelete(),
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'delete',
                key: Key('entryDelete'),
                child: Text('Delete'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Asks before [entry] is deleted.
Future<bool> confirmDeleteEntry(BuildContext context, Entry entry) async {
  final title = entry.displayTitle;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Delete entry?'),
      content: Text(
        title.isEmpty ? 'Delete this entry?' : 'Delete "$title"?',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('entryDeleteConfirm'),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Shows [child] only while the "Personal data (beta)" switch is on and the
/// account is unlocked on this device; otherwise a message and a way to the
/// personal-data screen.
class PersonalDataGate extends ConsumerWidget {
  const PersonalDataGate({
    super.key,
    required this.accountId,
    required this.child,
  });

  final String accountId;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs =
        ref.watch(userPreferencesProvider).value ?? const UserPreferences();
    if (!prefs.personalDataBeta) {
      return const _GateMessage(
        'Turn on "Personal data (beta)" in Preferences to use encrypted '
        'personal data.',
      );
    }
    final status = ref.watch(personalDataStatusProvider(accountId));
    return status.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _GateMessage('Error: ${userErrorMessage(e)}'),
      data: (s) {
        if (s == PersonalDataStatus.unlocked ||
            s == PersonalDataStatus.foreignKeyWarning) {
          return child;
        }
        return _GateMessage(
          'Set up or unlock encrypted personal data for this account first.',
          action: FilledButton(
            key: const Key('entriesOpenPersonalData'),
            onPressed: () =>
                context.pushReplacement('/accounts/$accountId/personal-data'),
            child: const Text('Personal data'),
          ),
        );
      },
    );
  }
}

class _GateMessage extends StatelessWidget {
  const _GateMessage(this.text, {this.action});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(text, textAlign: TextAlign.center),
              if (action != null) ...[
                const SizedBox(height: AppSpacing.lg),
                action!,
              ],
            ],
          ),
        ),
      );
}
