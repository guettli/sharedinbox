import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/entry.dart';
import 'package:sharedinbox/core/utils/format_utils.dart';
import 'package:sharedinbox/core/utils/markdown_tasks.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/entries_screen.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';
import 'package:sharedinbox/ui/widgets/entry_markdown.dart';

/// Edits the title and the Markdown body of one entry (#1373). Opens in a
/// rendered preview when the body is not empty (#1376); ticking a task-list
/// checkbox there saves at once. Other fields are kept; saving also resolves
/// a conflict.
class EntryEditScreen extends ConsumerStatefulWidget {
  const EntryEditScreen({
    super.key,
    required this.accountId,
    required this.itemId,
  });

  final String accountId;
  final String itemId;

  @override
  ConsumerState<EntryEditScreen> createState() => _EntryEditScreenState();
}

class _EntryEditScreenState extends ConsumerState<EntryEditScreen> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  Entry? _entry;
  bool _loaded = false;
  bool _busy = false;
  bool _preview = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final entry = await ref
        .read(entryRepositoryProvider)
        .entry(widget.accountId, widget.itemId);
    if (!mounted) return;
    setState(() {
      _entry = entry;
      _loaded = true;
      _title.text = entry?.title ?? '';
      _body.text = entry?.body ?? '';
      _preview = _body.text.trim().isNotEmpty;
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entry = _entry;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Entry'),
        actions: [
          if (entry != null)
            IconButton(
              key: const Key('entryEditPreviewToggle'),
              icon: Icon(_preview ? Icons.edit : Icons.visibility),
              tooltip: _preview ? 'Edit' : 'Preview',
              onPressed: () => setState(() => _preview = !_preview),
            ),
          if (entry != null)
            IconButton(
              key: const Key('entryEditDelete'),
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete',
              onPressed: _busy ? null : () => _delete(entry),
            ),
          if (entry != null)
            IconButton(
              key: const Key('entryEditSave'),
              icon: const Icon(Icons.check),
              tooltip: 'Save',
              onPressed: _busy ? null : _save,
            ),
        ],
      ),
      body: PersonalDataGate(
        accountId: widget.accountId,
        child: _form(entry),
      ),
    );
  }

  Widget _form(Entry? entry) {
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    if (entry == null) return const Center(child: Text('Entry not found.'));
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        if (entry.hasConflict)
          ListTile(
            key: const Key('entryEditConflict'),
            leading: const Icon(Icons.call_split),
            title: const Text('Edited on several devices at once'),
            subtitle:
                const Text('This shows the newest version; saving keeps it.'),
            trailing: TextButton(
              key: const Key('entryEditResolve'),
              onPressed: () => _resolve(entry),
              child: const Text('Resolve…'),
            ),
          ),
        TextField(
          key: const Key('entryEditTitle'),
          controller: _title,
          decoration: const InputDecoration(labelText: 'Title'),
        ),
        const SizedBox(height: AppSpacing.lg),
        if (_preview)
          EntryMarkdown(
            key: const Key('entryPreview'),
            body: _body.text,
            onToggleTask: _toggleTask,
          )
        else
          TextField(
            key: const Key('entryEditBody'),
            controller: _body,
            decoration: const InputDecoration(
              labelText: 'Text',
              alignLabelWithHint: true,
            ),
            keyboardType: TextInputType.multiline,
            minLines: 8,
            maxLines: null,
          ),
      ],
    );
  }

  /// Opens the conflict view; the entry is loaded again on return.
  Future<void> _resolve(Entry entry) async {
    await context.push(
      '/accounts/${widget.accountId}/conflicts/${entry.itemHmac}',
    );
    if (!mounted) return;
    await _load();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await ref.read(entryRepositoryProvider).update(
            widget.accountId,
            widget.itemId,
            title: _title.text,
            body: _body.text,
          );
      if (!mounted) return;
      context.pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      context.showAppSnackBar('Could not save: ${userErrorMessage(e)}');
    }
  }

  /// Ticks or unticks task [index] and saves it like [_save], with the
  /// current title and any unsaved edits, but stays on the screen.
  Future<void> _toggleTask(int index) async {
    if (_busy) return;
    final old = _body.text;
    setState(() {
      _body.text = toggleTask(old, index);
      _busy = true;
    });
    try {
      await ref.read(entryRepositoryProvider).update(
            widget.accountId,
            widget.itemId,
            title: _title.text,
            body: _body.text,
          );
    } catch (e) {
      if (!mounted) return;
      setState(() => _body.text = old);
      context.showAppSnackBar('Could not save: ${userErrorMessage(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(Entry entry) async {
    if (!await confirmDeleteEntry(context, entry) || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(entryRepositoryProvider)
          .delete(widget.accountId, widget.itemId);
      if (!mounted) return;
      context.pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      context.showAppSnackBar('Could not delete: ${userErrorMessage(e)}');
    }
  }
}
