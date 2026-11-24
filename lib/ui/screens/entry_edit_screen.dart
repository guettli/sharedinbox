import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:sharedinbox/core/encrypted_objects/envelope.dart'
    show ObjectTooLargeException;
import 'package:sharedinbox/core/encrypted_objects/keys.dart'
    show personalCollectionId;
import 'package:sharedinbox/core/models/entry.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart'
    show NoWriteKeyException;
import 'package:sharedinbox/core/services/image_shrink_service.dart';
import 'package:sharedinbox/core/utils/attachment_files.dart';
import 'package:sharedinbox/core/utils/format_utils.dart';
import 'package:sharedinbox/core/utils/journal_days.dart';
import 'package:sharedinbox/core/utils/markdown_images.dart';
import 'package:sharedinbox/core/utils/markdown_tasks.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/entries_screen.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/app_snackbar.dart';
import 'package:sharedinbox/ui/widgets/entry_markdown.dart';
import 'package:sharedinbox/ui/widgets/shrink_image_dialog.dart';

/// Edits the title and the Markdown body of one entry (#1373). Opens in a
/// rendered preview when the body is not empty (#1376); ticking a task-list
/// checkbox there saves at once. Other fields are kept; saving also resolves
/// a conflict. A task section makes it a todo with a due date and a done
/// tick (#1357); each change there saves at once. A date chip puts it in
/// the journal or takes it out (#1358); it is saved with the text.
/// "Insert image" uploads a picked, shrunk image as a blob and adds its
/// `si-img:` line to the text (#1377).
/// Leaving with unsaved title, text or journal-day edits saves them, like
/// Save does; if that fails, the user chooses to keep editing or discard.
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
  EntryTask? _task;

  /// The journal day (`YYYY-MM-DD`), null: not in the journal.
  String? _date;
  bool _loaded = false;

  /// Completes when the running save, task change or upload ends; null
  /// while none runs. Leaving waits for it.
  Completer<void>? _running;
  bool get _busy => _running != null;

  void _setBusy(bool busy) {
    if (busy) {
      _running ??= Completer<void>();
      return;
    }
    _running?.complete();
    _running = null;
  }

  /// Ends the running operation, also when the screen is gone.
  void _idle() {
    if (!mounted) {
      _setBusy(false);
      return;
    }
    setState(() => _setBusy(false));
  }

  /// A back press is being handled; further ones are ignored.
  bool _popping = false;
  bool _preview = false;

  /// Title, body and journal day as last loaded or saved, to tell whether
  /// leaving has to save first.
  String _savedTitle = '';
  String _savedBody = '';
  String? _savedDate;

  /// Set once leaving should no longer save (saved, deleted or discarded).
  bool _leaving = false;

  /// The settings of the last shrink, the start of the next.
  ImageShrinkSettings _shrinkSettings = ImageShrinkSettings.defaults;

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
      _task = entry?.task;
      _date = entry?.date;
      _loaded = true;
      _title.text = entry?.title ?? '';
      _body.text = entry?.body ?? '';
      _preview = _body.text.trim().isNotEmpty;
      _markSaved();
    });
  }

  void _markSaved() {
    _savedTitle = _title.text;
    _savedBody = _body.text;
    _savedDate = _date;
  }

  /// Whether title, body or journal day differ from what is saved.
  bool get _dirty =>
      _entry != null &&
      !_leaving &&
      (_title.text != _savedTitle ||
          _body.text != _savedBody ||
          _date != _savedDate);

  /// Back while edits are unsaved or a save runs: waits for the running
  /// operation, then saves what is unsaved (which leaves) or just leaves.
  void _onPopBlocked(bool didPop, Object? _) {
    if (didPop || _popping) return;
    _popping = true;
    unawaited(_leave());
  }

  Future<void> _leave() async {
    await _running?.future;
    if (!mounted) return;
    if (_dirty) {
      await _save(leaving: true);
      _popping = false;
      return;
    }
    setState(() => _leaving = true);
    context.pop();
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
    return ListenableBuilder(
      listenable: Listenable.merge([_title, _body]),
      builder: (context, child) => PopScope(
        // While false, iOS swipe-back is off; the back button saves.
        canPop: !_dirty && !_busy,
        onPopInvokedWithResult: _onPopBlocked,
        child: child!,
      ),
      child: _scaffold(entry),
    );
  }

  Widget _scaffold(Entry? entry) {
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
              key: const Key('entryEditInsertImage'),
              icon: const Icon(Icons.add_photo_alternate_outlined),
              tooltip: 'Insert image',
              onPressed: _busy ? null : _insertImage,
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
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: _dateChip(),
        ),
        TextField(
          key: const Key('entryEditTitle'),
          controller: _title,
          decoration: const InputDecoration(labelText: 'Title'),
        ),
        const SizedBox(height: AppSpacing.sm),
        ..._taskSection(),
        const SizedBox(height: AppSpacing.lg),
        if (_preview)
          EntryMarkdown(
            key: const Key('entryPreview'),
            body: _body.text,
            onToggleTask: _toggleTask,
            loadImage: _loadImage,
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

  /// The journal day, or a way to add one.
  Widget _dateChip() {
    final date = _date;
    if (date == null) {
      return ActionChip(
        key: const Key('entryEditAddDate'),
        avatar: const Icon(Icons.event_note),
        label: const Text('Add to journal'),
        onPressed: _pickDate,
      );
    }
    final day = parseJournalDate(date);
    return InputChip(
      key: const Key('entryEditDate'),
      avatar: const Icon(Icons.event_note),
      label: Text(day == null ? date : DateFormat.yMMMEd().format(day)),
      onPressed: _pickDate,
      deleteButtonTooltipMessage: 'Remove from journal',
      deleteIcon: const Icon(Icons.close, key: Key('entryEditRemoveDate')),
      onDeleted: () => setState(() => _date = null),
    );
  }

  Future<void> _pickDate() async {
    final now = ref.read(todayProvider)();
    final initial = parseJournalDate(_date) ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(min(initial.year, now.year - 100)),
      lastDate: DateTime(max(initial.year, now.year + 100), 12, 31),
    );
    if (picked == null || !mounted) return;
    setState(() => _date = isoDate(picked));
  }

  /// The "Todo" switch and, while on, the due date and the done tick.
  List<Widget> _taskSection() {
    final task = _task;
    final due = task?.due;
    return [
      SwitchListTile(
        key: const Key('entryTodoSwitch'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Todo'),
        value: task != null,
        onChanged:
            _busy ? null : (on) => _setTask(on ? const EntryTask() : null),
      ),
      if (task != null) ...[
        ListTile(
          key: const Key('entryDueDate'),
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.event),
          title: Text(due == null ? 'No due date' : 'Due $due'),
          onTap: _busy ? null : () => _pickDue(task),
          trailing: due == null
              ? null
              : IconButton(
                  key: const Key('entryDueDateClear'),
                  icon: const Icon(Icons.clear),
                  tooltip: 'Clear due date',
                  onPressed: _busy
                      ? null
                      : () => _setTask(task.copyWith(clearDue: true)),
                ),
        ),
        CheckboxListTile(
          key: const Key('entryDone'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('Done'),
          value: task.done,
          onChanged:
              _busy ? null : (v) => _setTask(task.copyWith(done: v ?? false)),
        ),
      ],
    ];
  }

  Future<void> _pickDue(EntryTask task) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(task.due ?? '') ?? now,
      firstDate: DateTime(now.year - 10),
      lastDate: DateTime(now.year + 10),
    );
    if (picked == null || !mounted) return;
    await _setTask(task.copyWith(due: isoDate(picked)));
  }

  /// Saves [task] (null: not a todo) at once; title and body stay unsaved.
  Future<void> _setTask(EntryTask? task) async {
    if (_busy) return;
    final old = _task;
    setState(() {
      _task = task;
      _setBusy(true);
    });
    try {
      await ref
          .read(entryRepositoryProvider)
          .setTask(widget.accountId, widget.itemId, task);
    } catch (e) {
      if (!mounted) return;
      setState(() => _task = old);
      context.showAppSnackBar('Could not save: ${userErrorMessage(e)}');
    } finally {
      _idle();
    }
  }

  Future<({String contentType, Uint8List bytes})?> _loadImage(
    String itemId,
  ) =>
      ref
          .read(mailObjectBlobStoreProvider)
          .blob(widget.accountId, personalCollectionId, itemId);

  /// Picks an image, offers to shrink it, and inserts it.
  Future<void> _insertImage() async {
    final picked = await ref.read(pickImageFileProvider)();
    if (picked == null || !mounted) return;
    final contentType = guessAttachmentType(picked.name);
    final service = ref.read(imageShrinkServiceProvider);
    if (!service.isShrinkable(contentType)) {
      if (!_isRasterImage(contentType)) {
        context.showAppSnackBar('Only photos and pictures can be inserted.');
        return;
      }
      await _insertImageBytes(picked.bytes, contentType);
      return;
    }
    final shrunk = await ShrinkImageDialog.show(
      context,
      path: picked.path,
      service: service,
      initialSettings: _shrinkSettings,
    );
    if (!mounted) return;
    if (shrunk == null) {
      await _insertImageBytes(picked.bytes, contentType);
      return;
    }
    _shrinkSettings = shrunk.settings;
    await _insertImageBytes(shrunk.bytes, 'image/jpeg');
  }

  static bool _isRasterImage(String contentType) =>
      contentType.startsWith('image/') && !contentType.startsWith('image/svg');

  /// Stores [bytes] as a blob (also offline: it is uploaded later) and
  /// inserts its image line at the cursor, or at the end in the preview.
  /// The entry itself is saved by [_save].
  Future<void> _insertImageBytes(Uint8List bytes, String contentType) async {
    setState(() => _setBusy(true));
    try {
      final itemId = await ref.read(mailObjectBlobStoreProvider).putBlob(
            widget.accountId,
            personalCollectionId,
            bytes,
            contentType,
          );
      if (!mounted) return;
      final selection = _body.selection;
      final offset =
          _preview || !selection.isValid ? -1 : selection.extentOffset;
      final (text, cursor) = insertSiImage(_body.text, offset, itemId);
      setState(() {
        _body.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: cursor),
        );
        _preview = false;
      });
    } on ObjectTooLargeException catch (e, stack) {
      if (!mounted) return;
      context.showAppSnackBar(
        'Image is ${_mib(e.size)} MiB after shrinking; the limit is '
        '${_mib(e.limit)} MiB. Shrink it more and try again.',
        level: AppLogLevel.warn,
        event: 'entry.image.too_large',
        error: e,
        stack: stack,
      );
    } on NoWriteKeyException catch (e, stack) {
      if (!mounted) return;
      context.showAppSnackBar(
        'Personal data is locked.',
        level: AppLogLevel.warn,
        event: 'entry.image.locked',
        error: e,
        stack: stack,
      );
    } catch (e, stack) {
      if (!mounted) return;
      context.showAppSnackBar(
        'Could not insert the image: ${userErrorMessage(e)}',
        level: AppLogLevel.warn,
        event: 'entry.image.failed',
        error: e,
        stack: stack,
      );
    } finally {
      _idle();
    }
  }

  static String _mib(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

  /// Opens the conflict view; the entry is loaded again on return.
  Future<void> _resolve(Entry entry) async {
    await context.push(
      '/accounts/${widget.accountId}/conflicts/${entry.itemHmac}',
    );
    if (!mounted) return;
    await _load();
  }

  /// Saves title, body and journal day and goes back. When [leaving] (back
  /// with unsaved edits) and the save fails, asks whether to discard them.
  Future<void> _save({bool leaving = false}) async {
    setState(() => _setBusy(true));
    try {
      await ref.read(entryRepositoryProvider).update(
            widget.accountId,
            widget.itemId,
            title: _title.text,
            body: _body.text,
            date: _date,
          );
      if (!mounted) return;
      setState(() => _leaving = true);
      context.pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _setBusy(false));
      if (leaving && await _confirmDiscard(e) && mounted) {
        setState(() => _leaving = true);
        context.pop();
        return;
      }
      if (!mounted) return;
      context.showAppSnackBar('Could not save: ${userErrorMessage(e)}');
    }
  }

  /// Asks whether to leave without the unsaved edits after [error].
  Future<bool> _confirmDiscard(Object error) async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Could not save'),
        content: Text(
          '${userErrorMessage(error)}\n\nDiscard your changes to this entry?',
        ),
        actions: [
          TextButton(
            key: const Key('entryEditKeepEditing'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            key: const Key('entryEditDiscard'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  /// Ticks or unticks task [index] and saves it like [_save], with the
  /// current title and any unsaved edits, but stays on the screen.
  Future<void> _toggleTask(int index) async {
    if (_busy) return;
    final old = _body.text;
    setState(() {
      _body.text = toggleTask(old, index);
      _setBusy(true);
    });
    final title = _title.text;
    final body = _body.text;
    final date = _date;
    try {
      await ref.read(entryRepositoryProvider).update(
            widget.accountId,
            widget.itemId,
            title: title,
            body: body,
            date: date,
          );
      // What was saved, not what was typed meanwhile.
      if (mounted) {
        setState(() {
          _savedTitle = title;
          _savedBody = body;
          _savedDate = date;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _body.text = old);
      context.showAppSnackBar('Could not save: ${userErrorMessage(e)}');
    } finally {
      _idle();
    }
  }

  Future<void> _delete(Entry entry) async {
    if (!await confirmDeleteEntry(context, entry) || !mounted) return;
    setState(() => _setBusy(true));
    try {
      await ref
          .read(entryRepositoryProvider)
          .delete(widget.accountId, widget.itemId);
      if (!mounted) return;
      setState(() => _leaving = true);
      context.pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _setBusy(false));
      context.showAppSnackBar('Could not delete: ${userErrorMessage(e)}');
    }
  }
}
