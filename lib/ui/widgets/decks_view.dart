import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/import/card_import.dart';
import 'package:sharedinbox/core/models/card.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/core/repositories/review_repository.dart';
import 'package:sharedinbox/core/utils/format_utils.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';
import 'package:sharedinbox/ui/widgets/confirm_delete_dialog.dart';
import 'package:sharedinbox/ui/widgets/new_card_dialog.dart';
import 'package:sharedinbox/ui/widgets/text_prompt_dialog.dart';

/// The Cards tab of the entries home (ENCRYPTED-OBJECTS.md §9, #1381): the
/// decks of an account with what is left to study (due, learning, new); a
/// tap studies a deck. New deck, Import… (`.apkg` / `.csv`, #1383), and per
/// deck Rename, Add card and Delete.
class DecksView extends ConsumerStatefulWidget {
  const DecksView({super.key, required this.accountId});

  final String accountId;

  @override
  ConsumerState<DecksView> createState() => _DecksViewState();
}

class _DecksViewState extends ConsumerState<DecksView> {
  bool _importing = false;

  String get _accountId => widget.accountId;

  @override
  Widget build(BuildContext context) {
    final decks = ref.watch(decksProvider(_accountId));
    final counts = ref.watch(deckCountsProvider(_accountId)).value ?? const {};
    final importer = ref.watch(cardImporterProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            0,
          ),
          child: Wrap(
            spacing: AppSpacing.sm,
            children: [
              FilledButton.tonalIcon(
                key: const Key('decksNew'),
                onPressed: _createDeck,
                icon: const Icon(Icons.add),
                label: const Text('New deck'),
              ),
              OutlinedButton.icon(
                key: const Key('decksImport'),
                onPressed: _importing ? null : () => _import(importer),
                icon: const Icon(Icons.file_open_outlined),
                label: const Text('Import…'),
              ),
            ],
          ),
        ),
        if (_importing)
          const LinearProgressIndicator(key: Key('decksImportProgress')),
        Expanded(
          child: decks.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) =>
                Center(child: Text('Error: ${userErrorMessage(e)}')),
            data: (list) {
              if (list.isEmpty) {
                return const Center(child: Text('No decks yet.'));
              }
              return ListView.builder(
                itemCount: list.length,
                itemBuilder: (_, i) =>
                    _deckTile(list[i], counts[list[i].deckId]),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _deckTile(Deck deck, DeckCounts? counts) {
    final id = deck.deckId;
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      key: Key('deckTile_$id'),
      title: Text(deck.name.isEmpty ? '(unnamed)' : deck.name),
      leading: deck.hasConflict
          ? Icon(
              Icons.call_split,
              key: Key('deckConflict_$id'),
              color: colors.error,
              semanticLabel: 'In conflict',
            )
          : const Icon(Icons.style_outlined),
      subtitle: Wrap(
        spacing: AppSpacing.sm,
        children: [
          _count('deckDue_$id', counts?.due ?? 0, 'due', colors.primary),
          _count(
            'deckLearning_$id',
            counts?.learning ?? 0,
            'learning',
            colors.error,
          ),
          _count('deckNew_$id', counts?.newCards ?? 0, 'new', colors.tertiary),
        ],
      ),
      onTap: () =>
          unawaited(context.push('/accounts/$_accountId/decks/$id/study')),
      trailing: PopupMenuButton<String>(
        key: Key('deckMenu_$id'),
        itemBuilder: (_) => const [
          PopupMenuItem(
            key: Key('deckRename'),
            value: 'rename',
            child: Text('Rename'),
          ),
          PopupMenuItem(
            key: Key('deckAddCard'),
            value: 'add_card',
            child: Text('Add card'),
          ),
          PopupMenuItem(
            key: Key('deckDelete'),
            value: 'delete',
            child: Text('Delete'),
          ),
        ],
        onSelected: (value) => unawaited(_menu(value, deck)),
      ),
    );
  }

  Future<void> _menu(String value, Deck deck) => switch (value) {
        'rename' => _rename(deck),
        'add_card' => addCardWithDialog(
            context,
            ref,
            accountId: _accountId,
            deckId: deck.deckId,
          ),
        _ => _delete(deck),
      };

  Widget _count(String key, int n, String label, Color color) => Text(
        '$n $label',
        key: Key(key),
        style: n == 0 ? null : TextStyle(color: color),
      );

  Future<void> _createDeck() async {
    final name = await showTextPrompt(
      context,
      title: 'New deck',
      confirmLabel: 'Create',
      labelText: 'Name',
    );
    if (name == null || !mounted) return;
    await _write(
      () => ref.read(cardRepositoryProvider).createDeck(_accountId, name),
    );
  }

  Future<void> _rename(Deck deck) async {
    final name = await showTextPrompt(
      context,
      title: 'Rename deck',
      confirmLabel: 'Rename',
      labelText: 'Name',
    );
    if (name == null || !mounted) return;
    await _write(
      () => ref
          .read(cardRepositoryProvider)
          .renameDeck(_accountId, deck.deckId, name),
    );
  }

  Future<void> _delete(Deck deck) async {
    final repo = ref.read(cardRepositoryProvider);
    final n = await repo.cardCount(_accountId, deck.deckId);
    if (!mounted) return;
    final confirmed = await showConfirmDelete(
      context,
      title: 'Delete deck?',
      content: 'Delete deck "${deck.name}" and its '
          '${n == 1 ? '1 card' : '$n cards'}?',
      confirmKey: const Key('deckDeleteConfirm'),
    );
    if (!confirmed || !mounted) return;
    await _write(() => repo.deleteDeck(_accountId, deck.deckId));
  }

  /// Runs a deck write; a locked account asks to unlock.
  Future<void> _write(Future<Object?> Function() write) async {
    final messenger = context.appMessenger();
    try {
      await write();
    } on NoWriteKeyException {
      messenger.show('Unlock personal data to change decks.');
    } catch (e) {
      messenger.show('Could not save: ${userErrorMessage(e)}');
    }
  }

  Future<void> _import(CardImporter importer) async {
    final messenger = context.appMessenger();
    final file = await ref.read(pickImportFileProvider)();
    if (file == null || !mounted) return;
    setState(() => _importing = true);
    final ImportResult result;
    try {
      result = file.name.toLowerCase().endsWith('.csv')
          ? await importer.importCsv(
              _accountId,
              utf8.decode(file.bytes, allowMalformed: true),
            )
          : await importer.importApkg(_accountId, file.bytes);
    } on NoWriteKeyException {
      messenger.show('Unlock personal data to import cards.');
      return;
    } on UnsupportedAnkiFormatException catch (e) {
      messenger.show('Cannot import ${file.name}: ${e.message}');
      return;
    } on FormatException catch (e) {
      messenger.show('Cannot import ${file.name}: ${e.message}');
      return;
    } catch (e) {
      messenger.show('Import failed: ${userErrorMessage(e)}');
      return;
    } finally {
      if (mounted) setState(() => _importing = false);
    }
    if (!mounted) return;
    await _showImportResult(file.name, result);
  }

  Future<void> _showImportResult(String name, ImportResult r) {
    final lines = [
      '${r.added} added, ${r.updated} updated, ${r.unchanged} unchanged',
      if (r.skippedDeleted > 0) '${r.skippedDeleted} skipped (deleted here)',
      if (r.skippedCloze > 0) '${r.skippedCloze} skipped (cloze)',
      if (r.skippedEmpty > 0) '${r.skippedEmpty} skipped (empty)',
      if (r.missingMedia > 0) '${r.missingMedia} images missing',
      if (r.decks.isNotEmpty) 'Decks: ${r.decks.join(', ')}',
    ];
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('decksImportResult'),
        title: Text('Imported $name'),
        content: Text(lines.join('\n')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}
