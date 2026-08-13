import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/filter/filter_sieve_converter.dart';
import 'package:sharedinbox/core/models/sieve_script.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart'
    show SieveParseException;
import 'package:sharedinbox/core/sieve/sieve_actions.dart';
import 'package:sharedinbox/core/sieve/sieve_serializer.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/filter_builder.dart';
import 'package:sharedinbox/ui/widgets/mailbox_picker_button.dart';

/// Fields the Sieve builder exposes — excludes those that make no sense at
/// delivery time (e.g. [FilterField.folder]).
const List<FilterField> _sieveFilterFields = [
  FilterField.from_,
  FilterField.to,
  FilterField.cc,
  FilterField.subject,
  FilterField.size,
  FilterField.header,
];

class SieveScriptEditScreen extends ConsumerStatefulWidget {
  const SieveScriptEditScreen({
    super.key,
    required this.accountId,
    this.script,
    this.isLocal = false,
    this.initialFilter,
    this.initialName,
  });

  final String accountId;

  /// Null when creating a new script.
  final SieveScript? script;

  /// True for locally-executed scripts; false for server-side (ManageSieve/JMAP).
  final bool isLocal;

  /// Optional filter to pre-populate a *new* (unsaved) script with; ignored
  /// when [script] is non-null.
  final FilterGroup? initialFilter;

  /// Optional name to pre-fill the name field for a new script.
  final String? initialName;

  @override
  ConsumerState<SieveScriptEditScreen> createState() =>
      _SieveScriptEditScreenState();
}

class _SieveScriptEditScreenState extends ConsumerState<SieveScriptEditScreen>
    with SingleTickerProviderStateMixin {
  late final TextEditingController _nameController;
  late final TextEditingController _contentController;
  late final TabController _tabController;

  bool _loadingContent = false;
  bool _saving = false;
  String? _error;

  // Visual-editor state.
  FilterGroup _filterGroup = FilterGroup.empty();
  List<SieveAction> _actions = [];
  bool _visualSupported = true;
  int _visualLoadCount = 0;

  /// Script content as it was loaded from the repository, so we can tell
  /// whether the user actually changed anything on the edit path and only
  /// prompt "apply to inbox?" when there is a real change.
  String? _initialContent;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.script?.name ?? widget.initialName ?? '',
    );
    _contentController = TextEditingController();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_onTabChanged);
    if (widget.script != null) {
      unawaited(_loadContent());
    } else if (widget.initialFilter != null) {
      _filterGroup = widget.initialFilter!;
      _actions = [KeepAction()];
      _contentController.text = SieveSerializer().serialize(
        _filterGroup,
        _actions,
      );
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _contentController.dispose();
    _tabController
      ..removeListener(_onTabChanged)
      ..dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    if (_tabController.index == 1) {
      // Switched to Script tab: serialize visual state.
      if (_visualSupported) {
        _contentController.text = SieveSerializer().serialize(
          _filterGroup,
          _actions,
        );
      }
    } else {
      // Switched to Visual tab: parse script into visual state.
      _parseScriptIntoVisual();
    }
  }

  void _parseScriptIntoVisual() {
    final result = FilterSieveConverter().parse(_contentController.text);
    if (result == null) {
      setState(() => _visualSupported = false);
      return;
    }
    setState(() {
      _filterGroup = result.group;
      _actions = List<SieveAction>.from(result.actions);
      _visualSupported = true;
      _visualLoadCount++;
    });
  }

  Future<void> _loadContent() async {
    setState(() => _loadingContent = true);
    try {
      final content = widget.isLocal
          ? await ref
              .read(localSieveRepositoryProvider)
              .getScriptContent(widget.accountId, widget.script!.blobId)
          : await ref
              .read(sieveRepositoryProvider)
              .getScriptContent(widget.accountId, widget.script!.blobId);
      if (mounted) {
        _contentController.text = content;
        _initialContent = content;
        _parseScriptIntoVisual();
        setState(() => _loadingContent = false);
      }
    } catch (e, stack) {
      unawaited(
        ref.read(appLoggerProvider).error(
              'sieve.script.load_failed',
              'Failed to load sieve script content',
              accountId: widget.accountId,
              data: {'scriptId': widget.script?.id, 'isLocal': widget.isLocal},
              error: e,
              stack: stack,
            ),
      );
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loadingContent = false;
        });
      }
    }
  }

  Future<void> _save() async {
    // Sync visual → script if on visual tab.
    if (_tabController.index == 0 && _visualSupported) {
      _contentController.text = SieveSerializer().serialize(
        _filterGroup,
        _actions,
      );
    }
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Name is required');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final content = _contentController.text;
    final isNew = widget.script == null;
    final contentChanged =
        _initialContent == null || _initialContent != content;
    SieveScript saved;
    try {
      if (widget.isLocal) {
        saved = await ref.read(localSieveRepositoryProvider).saveScript(
              widget.accountId,
              id: widget.script?.id,
              name: name,
              content: content,
            );
      } else {
        saved = await ref.read(sieveRepositoryProvider).saveScript(
              widget.accountId,
              id: widget.script?.id,
              name: name,
              content: content,
            );
      }
    } catch (e, stack) {
      unawaited(
        ref.read(appLoggerProvider).error(
              'sieve.script.save_failed',
              'Failed to save sieve script',
              accountId: widget.accountId,
              data: {
                'scriptId': widget.script?.id,
                'scriptName': _nameController.text.trim(),
                'isLocal': widget.isLocal,
              },
              error: e,
              stack: stack,
            ),
      );
      if (mounted) {
        setState(() {
          _error = e.toString();
          _saving = false;
        });
      }
      return;
    }

    // Only offer "apply to inbox" when there is a real change worth applying:
    // always on create, and on edit only when the script content differs from
    // what was loaded.
    if (isNew || contentChanged) {
      await _offerApplyToInbox(
        savedScript: saved,
        wasActive: widget.script?.isActive ?? false,
        content: content,
      );
    }

    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _offerApplyToInbox({
    required SieveScript savedScript,
    required bool wasActive,
    required String content,
  }) async {
    final emails = ref.read(emailRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);

    int count;
    try {
      count = await emails.previewSieveRuleMatches(widget.accountId, content);
    } on SieveParseException {
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Could not evaluate this filter against your inbox.'),
          ),
        );
      }
      return;
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('Preview failed: $e')));
      }
      return;
    }

    if (!mounted) return;

    if (count == 0) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('No matching messages'),
          content: const Text(
            'This filter does not match any messages currently in your inbox.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    final shouldApply = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Apply filter now?'),
        content: Text(
          wasActive
              ? 'This filter matches $count message(s) in your inbox. '
                  'Apply it to them now?'
              : 'This filter matches $count message(s) in your inbox. '
                  'The filter will be activated first. Apply it now?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Apply'),
          ),
        ],
      ),
    );

    if (shouldApply != true || !mounted) return;

    try {
      if (!wasActive) {
        if (widget.isLocal) {
          await ref
              .read(localSieveRepositoryProvider)
              .activateScript(widget.accountId, savedScript.id);
        } else {
          await ref
              .read(sieveRepositoryProvider)
              .activateScript(widget.accountId, savedScript.id);
        }
      }
      final applied = await emails.applySieveScriptToInbox(
        widget.accountId,
        content,
      );
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Filter applied to $applied message(s).')),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Failed to apply filter: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.script == null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isNew ? 'New script' : 'Edit script'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Visual'),
            Tab(text: 'Script'),
          ],
        ),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.lg),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.save),
              onPressed: _save,
              tooltip: 'Save',
            ),
        ],
      ),
      body: _loadingContent
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      border: OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.next,
                    enabled: !_saving,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  if (_error != null) ...[
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  Expanded(
                    child: TabBarView(
                      controller: _tabController,
                      // Disable swipe-to-switch: a horizontal drag while
                      // editing a filter row must not page over to the raw
                      // Script tab. Users switch views via the tab bar.
                      physics: const NeverScrollableScrollPhysics(),
                      children: [_buildVisualTab(), _buildScriptTab()],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildVisualTab() {
    if (!_visualSupported) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Text(
            'This script uses features not supported by the visual editor.\n'
            'Edit as raw Sieve on the Script tab.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilterBuilderWidget(
            key: ValueKey(_visualLoadCount),
            initialValue: _filterGroup,
            onChanged: (g) => setState(() => _filterGroup = g),
            availableFields: _sieveFilterFields,
          ),
          const SizedBox(height: AppSpacing.md),
          _ActionEditor(
            accountId: widget.accountId,
            actions: _actions,
            onChanged: (a) => setState(() => _actions = a),
          ),
        ],
      ),
    );
  }

  Widget _buildScriptTab() {
    return TextField(
      controller: _contentController,
      decoration: const InputDecoration(
        labelText: 'Script',
        border: OutlineInputBorder(),
        alignLabelWithHint: true,
      ),
      maxLines: null,
      expands: true,
      textAlignVertical: TextAlignVertical.top,
      style: const TextStyle(fontFamily: 'monospace'),
      enabled: !_saving,
    );
  }
}

// ---------------------------------------------------------------------------
// Action editor
// ---------------------------------------------------------------------------

enum _ActionType { keep, discard, markAsRead, starMessage, fileInto }

class _ActionEditor extends StatelessWidget {
  const _ActionEditor({
    required this.accountId,
    required this.actions,
    required this.onChanged,
  });

  final String accountId;
  final List<SieveAction> actions;
  final void Function(List<SieveAction>) onChanged;

  _ActionType _typeOf(SieveAction a) => switch (a) {
        KeepAction() => _ActionType.keep,
        DiscardAction() => _ActionType.discard,
        MarkAsSeenAction() => _ActionType.markAsRead,
        StarMessageAction() => _ActionType.starMessage,
        FileIntoAction() => _ActionType.fileInto,
        FlagAction() => _ActionType.keep,
      };

  SieveAction _defaultFor(_ActionType t) => switch (t) {
        _ActionType.keep => KeepAction(),
        _ActionType.discard => DiscardAction(),
        _ActionType.markAsRead => MarkAsSeenAction(),
        _ActionType.starMessage => StarMessageAction(),
        _ActionType.fileInto => FileIntoAction(''),
      };

  void _changeType(int i, _ActionType t) {
    final next = List<SieveAction>.from(actions);
    final current = next[i];
    if (t == _ActionType.fileInto && current is FileIntoAction) return;
    next[i] = _defaultFor(t);
    onChanged(next);
  }

  void _changeFolder(int i, String folder) {
    final next = List<SieveAction>.from(actions);
    next[i] = FileIntoAction(folder);
    onChanged(next);
  }

  void _remove(int i) {
    final next = List<SieveAction>.from(actions)..removeAt(i);
    onChanged(next);
  }

  void _add() {
    onChanged([...actions, KeepAction()]);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          child: Text('Actions', style: Theme.of(context).textTheme.labelLarge),
        ),
        for (var i = 0; i < actions.length; i++) _buildRow(context, i),
        TextButton.icon(
          onPressed: _add,
          icon: const Icon(Icons.add, size: AppIconSize.sm),
          label: const Text('Add action'),
        ),
      ],
    );
  }

  Widget _buildRow(BuildContext context, int i) {
    final action = actions[i];
    final type = _typeOf(action);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          DropdownButton<_ActionType>(
            value: type,
            isDense: true,
            underline: const SizedBox.shrink(),
            onChanged: (t) {
              if (t != null) _changeType(i, t);
            },
            items: const [
              DropdownMenuItem(value: _ActionType.keep, child: Text('Keep')),
              DropdownMenuItem(
                value: _ActionType.discard,
                child: Text('Discard'),
              ),
              DropdownMenuItem(
                value: _ActionType.markAsRead,
                child: Text('Mark as read'),
              ),
              DropdownMenuItem(
                value: _ActionType.starMessage,
                child: Text('Star message'),
              ),
              DropdownMenuItem(
                value: _ActionType.fileInto,
                child: Text('File into'),
              ),
            ],
          ),
          if (type == _ActionType.fileInto) ...[
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _FolderField(
                accountId: accountId,
                value: (action as FileIntoAction).folder,
                onChanged: (v) => _changeFolder(i, v),
              ),
            ),
          ] else
            const Spacer(),
          IconButton(
            icon: const Icon(Icons.remove_circle_outline, size: AppIconSize.sm),
            tooltip: 'Remove',
            onPressed: () => _remove(i),
          ),
        ],
      ),
    );
  }
}

/// Sieve `fileinto` stores the mailbox's `displayPath`, so we forward the
/// raw string the picker returned back to [onChanged] unchanged.
class _FolderField extends ConsumerWidget {
  const _FolderField({
    required this.accountId,
    required this.value,
    required this.onChanged,
  });

  final String accountId;
  final String value;
  final void Function(String) onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(mailboxRepositoryProvider);
    return MailboxPickerButton(
      accountId: accountId,
      value: value,
      onCreate: ({required name, parentDisplayPath}) => repo.createMailbox(
        accountId,
        name,
        parentDisplayPath: parentDisplayPath,
      ),
      onPicked: (_, displayPath) => onChanged(displayPath),
    );
  }
}
