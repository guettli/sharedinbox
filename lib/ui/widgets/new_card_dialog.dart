import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/card.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/core/utils/format_utils.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/widgets/accessible_dropdown.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';
import 'package:sharedinbox/ui/widgets/text_prompt_dialog.dart';

/// The dropdown value of "New deck…".
const _newDeck = '';

/// Asks for a new card of [accountId] and adds it (#1381): a deck (preset
/// [deckId], else the deck last used here), the front (empty, focused), the
/// back (preset [back], e.g. text selected in a mail) and tags. Then
/// "Card added" with a way to study the deck, unless [offerStudy] is false
/// (already on its study screen).
Future<void> addCardWithDialog(
  BuildContext context,
  WidgetRef ref, {
  required String accountId,
  String? deckId,
  String back = '',
  bool offerStudy = true,
}) async {
  final router = GoRouter.of(context);
  final messenger = context.appMessenger();
  final card = await showDialog<({String deckId, CardContent content})>(
    context: context,
    builder: (_) => NewCardDialog(
      accountId: accountId,
      deckId: deckId ?? ref.read(lastCardDeckProvider)[accountId],
      back: back,
    ),
  );
  if (card == null) return;
  ref.read(lastCardDeckProvider)[accountId] = card.deckId;
  try {
    await ref
        .read(cardRepositoryProvider)
        .addCard(accountId, card.deckId, NewCard(card.content));
  } on NoWriteKeyException {
    messenger.show('Unlock personal data to add cards.');
    return;
  } catch (e) {
    messenger.show('Could not add the card: ${userErrorMessage(e)}');
    return;
  }
  if (!offerStudy) {
    messenger.show('Card added');
    return;
  }
  messenger.show(
    'Card added',
    action: SnackBarAction(
      label: 'Study',
      onPressed: () => unawaited(
        router.push('/accounts/$accountId/decks/${card.deckId}/study'),
      ),
    ),
  );
}

/// The form of [addCardWithDialog]; pops the deck and content, or null.
class NewCardDialog extends ConsumerStatefulWidget {
  const NewCardDialog({
    super.key,
    required this.accountId,
    this.deckId,
    this.back = '',
  });

  final String accountId;
  final String? deckId;
  final String back;

  @override
  ConsumerState<NewCardDialog> createState() => _NewCardDialogState();
}

class _NewCardDialogState extends ConsumerState<NewCardDialog> {
  final _front = TextEditingController();
  late final _back = TextEditingController(text: widget.back);
  final _tags = TextEditingController();
  late String? _deckId = widget.deckId;

  @override
  void dispose() {
    _front.dispose();
    _back.dispose();
    _tags.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final decks =
        ref.watch(decksProvider(widget.accountId)).value ?? const <Deck>[];
    final known = decks.any((d) => d.deckId == _deckId);
    final deckId = known ? _deckId : null;
    return AlertDialog(
      title: const Text('New card'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AccessibleDropdown(
                child: DropdownButton<String>(
                  key: const Key('newCardDeck'),
                  isExpanded: true,
                  hint: const Text('Deck'),
                  value: deckId,
                  items: [
                    for (final d in decks)
                      DropdownMenuItem(value: d.deckId, child: Text(d.name)),
                    const DropdownMenuItem(
                      key: Key('newCardNewDeck'),
                      value: _newDeck,
                      child: Text('New deck…'),
                    ),
                  ],
                  onChanged: _deckChanged,
                ),
              ),
              TextField(
                key: const Key('newCardFront'),
                controller: _front,
                autofocus: true,
                maxLines: null,
                decoration: const InputDecoration(labelText: 'Front'),
                onChanged: (_) => setState(() {}),
              ),
              TextField(
                key: const Key('newCardBack'),
                controller: _back,
                maxLines: null,
                decoration: const InputDecoration(labelText: 'Back'),
              ),
              TextField(
                key: const Key('newCardTags'),
                controller: _tags,
                decoration: const InputDecoration(
                  labelText: 'Tags',
                  hintText: 'Separated by spaces',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('newCardSave'),
          onPressed: deckId == null || _front.text.trim().isEmpty
              ? null
              : () => _save(deckId),
          child: const Text('Add'),
        ),
      ],
    );
  }

  void _save(String deckId) {
    final content = CardContent(
      front: _front.text.trim(),
      back: _back.text.trim(),
      tags: [
        for (final t in _tags.text.split(RegExp(r'\s+')))
          if (t.isNotEmpty) t,
      ],
    );
    Navigator.pop(context, (deckId: deckId, content: content));
  }

  Future<void> _deckChanged(String? value) async {
    if (value != _newDeck) {
      setState(() => _deckId = value);
      return;
    }
    final messenger = context.appMessenger();
    final name = await showTextPrompt(
      context,
      title: 'New deck',
      confirmLabel: 'Create',
      labelText: 'Name',
    );
    if (name == null || !mounted) return;
    try {
      final deck = await ref
          .read(cardRepositoryProvider)
          .createDeck(widget.accountId, name);
      if (!mounted) return;
      setState(() => _deckId = deck.deckId);
    } on NoWriteKeyException {
      messenger.show('Unlock personal data to add decks.');
    } catch (e) {
      messenger.show('Could not create the deck: ${userErrorMessage(e)}');
    }
  }
}
