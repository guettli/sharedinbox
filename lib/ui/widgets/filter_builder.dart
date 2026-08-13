import 'package:flutter/material.dart';
import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';
import 'package:sharedinbox/ui/widgets/mailbox_picker_button.dart';

/// A widget that lets the user build a structured [FilterGroup] interactively.
///
/// Use a [ValueKey] on this widget when replacing [initialValue] from the
/// outside (e.g., after loading a Sieve script) to force a full rebuild.
class FilterBuilderWidget extends StatefulWidget {
  const FilterBuilderWidget({
    super.key,
    required this.initialValue,
    required this.onChanged,
    this.availableFields = FilterField.values,
    this.accountId,
  });

  final FilterGroup initialValue;
  final void Function(FilterGroup) onChanged;

  /// Fields shown in the "field" dropdown. Defaults to every [FilterField].
  /// The Sieve rule editor omits fields that do not exist in the Sieve spec
  /// (e.g. [FilterField.folder]).
  final List<FilterField> availableFields;

  /// Optional account scope for the folder picker. When null, the picker
  /// lists folders across every account (matching the search itself).
  final String? accountId;

  @override
  State<FilterBuilderWidget> createState() => _FilterBuilderWidgetState();
}

class _FilterBuilderWidgetState extends State<FilterBuilderWidget> {
  late FilterGroup _group;

  @override
  void initState() {
    super.initState();
    _group = widget.initialValue;
  }

  void _update(FilterGroup g) {
    setState(() => _group = g);
    widget.onChanged(g);
  }

  @override
  Widget build(BuildContext context) {
    return _GroupEditor(
      group: _group,
      onChanged: _update,
      depth: 0,
      availableFields: widget.availableFields,
      accountId: widget.accountId,
    );
  }
}

// ---------------------------------------------------------------------------
// Group editor
// ---------------------------------------------------------------------------

class _GroupEditor extends StatelessWidget {
  const _GroupEditor({
    super.key,
    required this.group,
    required this.onChanged,
    required this.depth,
    required this.availableFields,
    required this.accountId,
    this.onRemoveGroup,
  });

  final FilterGroup group;
  final void Function(FilterGroup) onChanged;
  final int depth;
  final List<FilterField> availableFields;
  final String? accountId;
  final VoidCallback? onRemoveGroup;

  static const _maxDepth = 1;

  void _setOperator(FilterOperator op) =>
      onChanged(group.copyWith(operator: op));

  void _addLeaf() {
    final leaf = FilterLeaf(
      field: availableFields.first,
      comparison: availableFields.first.allowedComparisons.first,
      value: '',
    );
    onChanged(group.copyWith(children: [...group.children, leaf]));
  }

  void _addSubGroup() {
    final sub = FilterGroup(operator: FilterOperator.and_, children: []);
    onChanged(group.copyWith(children: [...group.children, sub]));
  }

  void _replaceChild(int index, FilterNode node) {
    final next = List<FilterNode>.from(group.children);
    next[index] = node;
    onChanged(group.copyWith(children: next));
  }

  void _removeChild(int index) {
    final next = List<FilterNode>.from(group.children)..removeAt(index);
    onChanged(group.copyWith(children: next));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isRoot = depth == 0;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _OperatorRow(
          operator: group.operator,
          onChanged: _setOperator,
          onRemove: onRemoveGroup,
        ),
        for (var i = 0; i < group.children.length; i++) _buildChild(context, i),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            TextButton.icon(
              onPressed: _addLeaf,
              icon: const Icon(Icons.add, size: AppIconSize.sm),
              label: const Text('Add condition'),
            ),
            if (depth < _maxDepth)
              TextButton.icon(
                onPressed: _addSubGroup,
                icon: const Icon(Icons.playlist_add, size: AppIconSize.sm),
                label: const Text('Add group'),
              ),
          ],
        ),
      ],
    );
    if (isRoot) return content;
    return Card(
      margin: const EdgeInsets.only(
        left: AppSpacing.md,
        top: AppSpacing.xs,
        bottom: AppSpacing.xs,
      ),
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: content,
      ),
    );
  }

  Widget _buildChild(BuildContext context, int i) {
    final child = group.children[i];
    return switch (child) {
      final FilterLeaf leaf => _LeafRow(
          key: ValueKey(i),
          leaf: leaf,
          onChanged: (l) => _replaceChild(i, l),
          onDelete: () => _removeChild(i),
          availableFields: availableFields,
          accountId: accountId,
        ),
      final FilterGroup sub => _GroupEditor(
          key: ValueKey(i),
          group: sub,
          onChanged: (g) => _replaceChild(i, g),
          depth: depth + 1,
          availableFields: availableFields,
          accountId: accountId,
          onRemoveGroup: () => _removeChild(i),
        ),
    };
  }
}

// ---------------------------------------------------------------------------
// Operator row (AND / OR toggle)
// ---------------------------------------------------------------------------

class _OperatorRow extends StatelessWidget {
  const _OperatorRow({
    required this.operator,
    required this.onChanged,
    this.onRemove,
  });

  final FilterOperator operator;
  final void Function(FilterOperator) onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SegmentedButton<FilterOperator>(
          segments: const [
            ButtonSegment(value: FilterOperator.and_, label: Text('AND')),
            ButtonSegment(value: FilterOperator.or_, label: Text('OR')),
          ],
          selected: {operator},
          onSelectionChanged: (s) => onChanged(s.first),
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        const Spacer(),
        if (onRemove != null)
          IconButton(
            icon: const Icon(Icons.close, size: AppIconSize.sm),
            tooltip: 'Remove group',
            onPressed: onRemove,
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Leaf row (field | comparison | value | delete)
// ---------------------------------------------------------------------------

class _LeafRow extends StatefulWidget {
  const _LeafRow({
    super.key,
    required this.leaf,
    required this.onChanged,
    required this.onDelete,
    required this.availableFields,
    required this.accountId,
  });

  final FilterLeaf leaf;
  final void Function(FilterLeaf) onChanged;
  final VoidCallback onDelete;
  final List<FilterField> availableFields;
  final String? accountId;

  @override
  State<_LeafRow> createState() => _LeafRowState();
}

class _LeafRowState extends State<_LeafRow> {
  late final TextEditingController _ctrl;
  late final TextEditingController _headerNameCtrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.leaf.value);
    _headerNameCtrl = TextEditingController(text: widget.leaf.headerName ?? '');
  }

  @override
  void didUpdateWidget(_LeafRow old) {
    super.didUpdateWidget(old);
    if (widget.leaf.value != _ctrl.text) {
      _ctrl.text = widget.leaf.value;
    }
    final nextName = widget.leaf.headerName ?? '';
    if (nextName != _headerNameCtrl.text) {
      _headerNameCtrl.text = nextName;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _headerNameCtrl.dispose();
    super.dispose();
  }

  void _onFieldChanged(FilterField? f) {
    if (f == null) return;
    final allowed = f.allowedComparisons;
    final comp = allowed.contains(widget.leaf.comparison)
        ? widget.leaf.comparison
        : allowed.first;
    widget.onChanged(widget.leaf.copyWith(field: f, comparison: comp));
  }

  void _onCompChanged(FilterComparison? c) {
    if (c == null) return;
    widget.onChanged(widget.leaf.copyWith(comparison: c));
  }

  /// Below this width the leaf controls stack onto two rows so the header
  /// name and value inputs stay tappable and full-width instead of being
  /// squeezed to zero by the fixed-width dropdowns on a narrow phone screen.
  static const _narrowBreakpoint = 480.0;

  Widget _fieldDropdown() => DropdownButton<FilterField>(
        value: widget.leaf.field,
        onChanged: _onFieldChanged,
        isDense: true,
        underline: const SizedBox.shrink(),
        items: widget.availableFields
            .map((f) => DropdownMenuItem(value: f, child: Text(f.label)))
            .toList(),
      );

  Widget _comparisonDropdown() => DropdownButton<FilterComparison>(
        value: widget.leaf.comparison,
        onChanged: _onCompChanged,
        isDense: true,
        underline: const SizedBox.shrink(),
        items: widget.leaf.field.allowedComparisons
            .map((c) => DropdownMenuItem(value: c, child: Text(c.label)))
            .toList(),
      );

  Widget _headerNameField() => TextField(
        controller: _headerNameCtrl,
        onChanged: (v) => widget.onChanged(widget.leaf.copyWith(headerName: v)),
        decoration: _leafFieldDecoration('header name'),
      );

  Widget _valueField() => TextField(
        controller: _ctrl,
        onChanged: (v) => widget.onChanged(widget.leaf.copyWith(value: v)),
        decoration: _leafFieldDecoration('value'),
      );

  // Folder is always an exact match against the picked mailbox, so there is no
  // comparison dropdown — just the picker button, which stores the mailbox's
  // raw `path` (opaque JMAP id or IMAP path) so the LIKE against
  // `emails.mailbox_path` matches.
  Widget _folderPicker() => MailboxPickerButton(
        accountId: widget.accountId,
        value: widget.leaf.value,
        onPicked: (picked, displayPath) => widget.onChanged(
          widget.leaf.copyWith(value: picked?.path ?? displayPath),
        ),
      );

  Widget _deleteButton() => IconButton(
        icon: const Icon(Icons.remove_circle_outline, size: AppIconSize.sm),
        tooltip: 'Remove',
        onPressed: widget.onDelete,
      );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < _narrowBreakpoint;
          return narrow ? _buildStacked() : _buildSingleRow();
        },
      ),
    );
  }

  /// Wide layout: everything on one line.
  Widget _buildSingleRow() {
    final isHeader = widget.leaf.field == FilterField.header;
    final isFolder = widget.leaf.field == FilterField.folder;
    return Row(
      children: [
        _fieldDropdown(),
        if (isHeader) ...[
          const SizedBox(width: AppSpacing.sm),
          SizedBox(width: 140, child: _headerNameField()),
        ],
        const SizedBox(width: AppSpacing.sm),
        if (isFolder)
          Expanded(child: _folderPicker())
        else ...[
          _comparisonDropdown(),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: _valueField()),
        ],
        _deleteButton(),
      ],
    );
  }

  /// Narrow (phone) layout: dropdowns on the first row, the header name and
  /// value inputs on a second row where they can use the full width.
  Widget _buildStacked() {
    final isHeader = widget.leaf.field == FilterField.header;
    final isFolder = widget.leaf.field == FilterField.folder;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _fieldDropdown(),
            if (!isFolder) ...[
              const SizedBox(width: AppSpacing.sm),
              _comparisonDropdown(),
            ],
            const Spacer(),
            _deleteButton(),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        if (isFolder)
          _folderPicker()
        else if (isHeader)
          Row(
            children: [
              Expanded(child: _headerNameField()),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: _valueField()),
            ],
          )
        else
          _valueField(),
      ],
    );
  }
}

/// Shared decoration for the leaf-row text inputs (header name and value),
/// hoisted out so the two nearly-identical [InputDecoration] literals don't
/// trip the duplication detector.
InputDecoration _leafFieldDecoration(String hint) => InputDecoration(
      hintText: hint,
      isDense: true,
      border: const OutlineInputBorder(),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.sm,
      ),
    );
