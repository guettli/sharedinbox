import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/filter/filter_sieve_converter.dart';
import 'package:sharedinbox/core/models/sieve_script.dart';
import 'package:sharedinbox/core/sieve/sieve_actions.dart';
import 'package:sharedinbox/core/sieve/sieve_serializer.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/widgets/filter_builder.dart';

class SieveScriptEditScreen extends ConsumerStatefulWidget {
  const SieveScriptEditScreen({
    super.key,
    required this.accountId,
    this.script,
    this.isLocal = false,
  });

  final String accountId;

  /// Null when creating a new script.
  final SieveScript? script;

  /// True for locally-executed scripts; false for server-side (ManageSieve/JMAP).
  final bool isLocal;

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

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.script?.name ?? '');
    _contentController = TextEditingController();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_onTabChanged);
    if (widget.script != null) {
      unawaited(_loadContent());
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
        _contentController.text =
            SieveSerializer().serialize(_filterGroup, _actions);
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
        _parseScriptIntoVisual();
        setState(() => _loadingContent = false);
      }
    } catch (e) {
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
      _contentController.text =
          SieveSerializer().serialize(_filterGroup, _actions);
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
    try {
      if (widget.isLocal) {
        await ref.read(localSieveRepositoryProvider).saveScript(
              widget.accountId,
              id: widget.script?.id,
              name: name,
              content: _contentController.text,
            );
      } else {
        await ref.read(sieveRepositoryProvider).saveScript(
              widget.accountId,
              id: widget.script?.id,
              name: name,
              content: _contentController.text,
            );
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _saving = false;
        });
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
          tabs: const [Tab(text: 'Visual'), Tab(text: 'Script')],
        ),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.all(16),
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
              padding: const EdgeInsets.all(16),
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
                  const SizedBox(height: 12),
                  if (_error != null) ...[
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Expanded(
                    child: TabBarView(
                      controller: _tabController,
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
          padding: const EdgeInsets.all(24),
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
          ),
          const SizedBox(height: 12),
          _ActionEditor(
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

enum _ActionType { keep, discard, markAsRead, fileInto }

class _ActionEditor extends StatelessWidget {
  const _ActionEditor({required this.actions, required this.onChanged});

  final List<SieveAction> actions;
  final void Function(List<SieveAction>) onChanged;

  _ActionType _typeOf(SieveAction a) => switch (a) {
        KeepAction() => _ActionType.keep,
        DiscardAction() => _ActionType.discard,
        MarkAsSeenAction() => _ActionType.markAsRead,
        FileIntoAction() => _ActionType.fileInto,
        FlagAction() => _ActionType.keep,
      };

  SieveAction _defaultFor(_ActionType t) => switch (t) {
        _ActionType.keep => KeepAction(),
        _ActionType.discard => DiscardAction(),
        _ActionType.markAsRead => MarkAsSeenAction(),
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
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text('Actions', style: Theme.of(context).textTheme.labelLarge),
        ),
        for (var i = 0; i < actions.length; i++) _buildRow(context, i),
        TextButton.icon(
          onPressed: _add,
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Add action'),
        ),
      ],
    );
  }

  Widget _buildRow(BuildContext context, int i) {
    final action = actions[i];
    final type = _typeOf(action);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
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
                value: _ActionType.fileInto,
                child: Text('File into'),
              ),
            ],
          ),
          if (type == _ActionType.fileInto) ...[
            const SizedBox(width: 8),
            Expanded(
              child: _FolderField(
                value: (action as FileIntoAction).folder,
                onChanged: (v) => _changeFolder(i, v),
              ),
            ),
          ] else
            const Spacer(),
          IconButton(
            icon: const Icon(Icons.remove_circle_outline, size: 18),
            tooltip: 'Remove',
            onPressed: () => _remove(i),
          ),
        ],
      ),
    );
  }
}

class _FolderField extends StatefulWidget {
  const _FolderField({required this.value, required this.onChanged});
  final String value;
  final void Function(String) onChanged;

  @override
  State<_FolderField> createState() => _FolderFieldState();
}

class _FolderFieldState extends State<_FolderField> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value);
  }

  @override
  void didUpdateWidget(_FolderField old) {
    super.didUpdateWidget(old);
    if (widget.value != _ctrl.text) _ctrl.text = widget.value;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _ctrl,
      onChanged: widget.onChanged,
      decoration: const InputDecoration(
        hintText: 'folder',
        isDense: true,
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      ),
    );
  }
}
