import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/entry.dart';
import 'package:sharedinbox/core/models/user_preferences.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/core/services/encrypted_key_service.dart';
import 'package:sharedinbox/core/utils/format_utils.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';
import 'package:sharedinbox/ui/widgets/confirm_delete_dialog.dart';
import 'package:sharedinbox/ui/widgets/decks_view.dart';
import 'package:sharedinbox/ui/widgets/entry_tile.dart';
import 'package:sharedinbox/ui/widgets/journal_view.dart';
import 'package:sharedinbox/ui/widgets/quick_add_field.dart';
import 'package:sharedinbox/ui/widgets/todos_view.dart';

/// One tab of the entries home: its label, key and content for an account.
typedef EntriesTab = (
  String label,
  Key key,
  Widget Function(String accountId) builder,
);

/// The tabs of the entries home (#1357), with the Journal (#1358) and the
/// decks of the flash cards (#1381).
const entriesTabs = <EntriesTab>[
  ('Notes', Key('entriesTab_notes'), _notesTab),
  ('Todos', Key('entriesTab_todos'), _todosTab),
  ('Journal', Key('entriesTab_journal'), _journalTab),
  ('Cards', Key('entriesTab_cards'), _cardsTab),
];

Widget _notesTab(String accountId) => _NotesTab(accountId: accountId);

Widget _todosTab(String accountId) => TodosView(accountId: accountId);

Widget _journalTab(String accountId) => JournalView(accountId: accountId);

Widget _cardsTab(String accountId) => DecksView(accountId: accountId);

/// The entries home (ENCRYPTED-OBJECTS.md 9, #1373): tabs for notes (search,
/// quick-add and the list, newest first), todos (#1357), the journal
/// (#1358) and the flash card decks (#1381).
/// Behind the "Personal data (beta)" switch, and only while the account is
/// unlocked on this device.
class EntriesScreen extends ConsumerWidget {
  const EntriesScreen({super.key, required this.accountId});

  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Entries'),
        actions: [_conflictsBadge(context, ref)],
      ),
      body: PersonalDataGate(
        accountId: accountId,
        child: DefaultTabController(
          length: entriesTabs.length,
          child: Column(
            children: [
              TabBar(
                tabs: [
                  for (final (label, key, _) in entriesTabs)
                    Tab(key: key, text: label),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    for (final (_, _, builder) in entriesTabs)
                      builder(accountId),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Opens the conflict list; only while some object is in conflict.
  Widget _conflictsBadge(BuildContext context, WidgetRef ref) {
    final count = ref.watch(conflictsProvider(accountId)).value?.length ?? 0;
    if (count == 0) return const SizedBox.shrink();
    return IconButton(
      key: const Key('entriesConflictsBadge'),
      tooltip: 'Conflicts',
      icon: Badge(label: Text('$count'), child: const Icon(Icons.call_split)),
      onPressed: () => context.push('/accounts/$accountId/conflicts'),
    );
  }
}

/// Search, quick-add and the entries of one account, newest first.
class _NotesTab extends ConsumerStatefulWidget {
  const _NotesTab({required this.accountId});

  final String accountId;

  @override
  ConsumerState<_NotesTab> createState() => _NotesTabState();
}

class _NotesTabState extends ConsumerState<_NotesTab> {
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
    return Column(
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
        QuickAddField(
          fieldKey: const Key('entriesQuickAdd'),
          sendKey: const Key('entriesQuickAddSend'),
          controller: _quickAdd,
          hintText: 'Quick add',
          onAdd: _add,
        ),
        Expanded(child: _list()),
      ],
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
          itemBuilder: (_, i) => EntryTile(
            entry: list[i],
            onTap: () => context.push(
              '/accounts/${widget.accountId}/entries/${list[i].itemId}',
            ),
            onDelete: () => _delete(list[i]),
            onResolve: () => context.push(
              '/accounts/${widget.accountId}/conflicts/${list[i].itemHmac}',
            ),
          ),
        );
      },
    );
  }

  Future<void> _add() async {
    final body = takeQuickAddText(_quickAdd);
    if (body == null) return;
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

/// Asks before [entry] is deleted.
Future<bool> confirmDeleteEntry(BuildContext context, Entry entry) {
  final title = entry.displayTitle;
  return showConfirmDelete(
    context,
    title: 'Delete entry?',
    content: title.isEmpty ? 'Delete this entry?' : 'Delete "$title"?',
    confirmKey: const Key('entryDeleteConfirm'),
  );
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
