import 'package:flutter/material.dart';
import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';

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
  });

  final FilterGroup initialValue;
  final void Function(FilterGroup) onChanged;

  /// Fields shown in the "field" dropdown. Defaults to every [FilterField].
  /// The Sieve rule editor omits fields that do not exist in the Sieve spec
  /// (e.g. [FilterField.folder]).
  final List<FilterField> availableFields;

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
    this.onRemoveGroup,
  });

  final FilterGroup group;
  final void Function(FilterGroup) onChanged;
  final int depth;
  final List<FilterField> availableFields;
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
    final sub = FilterGroup(
      operator: FilterOperator.and_,
      children: [],
    );
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
        ),
      final FilterGroup sub => _GroupEditor(
          key: ValueKey(i),
          group: sub,
          onChanged: (g) => _replaceChild(i, g),
          depth: depth + 1,
          availableFields: availableFields,
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
  });

  final FilterLeaf leaf;
  final void Function(FilterLeaf) onChanged;
  final VoidCallback onDelete;
  final List<FilterField> availableFields;

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

  @override
  Widget build(BuildContext context) {
    final isHeader = widget.leaf.field == FilterField.header;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          DropdownButton<FilterField>(
            value: widget.leaf.field,
            onChanged: _onFieldChanged,
            isDense: true,
            underline: const SizedBox.shrink(),
            items: widget.availableFields
                .map(
                  (f) => DropdownMenuItem(value: f, child: Text(f.label)),
                )
                .toList(),
          ),
          if (isHeader) ...[
            const SizedBox(width: AppSpacing.sm),
            SizedBox(
              width: 140,
              child: TextField(
                controller: _headerNameCtrl,
                onChanged: (v) =>
                    widget.onChanged(widget.leaf.copyWith(headerName: v)),
                decoration: const InputDecoration(
                  hintText: 'header name',
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: AppSpacing.sm,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(width: AppSpacing.sm),
          DropdownButton<FilterComparison>(
            value: widget.leaf.comparison,
            onChanged: _onCompChanged,
            isDense: true,
            underline: const SizedBox.shrink(),
            items: widget.leaf.field.allowedComparisons
                .map(
                  (c) => DropdownMenuItem(value: c, child: Text(c.label)),
                )
                .toList(),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: TextField(
              controller: _ctrl,
              onChanged: (v) =>
                  widget.onChanged(widget.leaf.copyWith(value: v)),
              decoration: const InputDecoration(
                hintText: 'value',
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: AppSpacing.sm,
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.remove_circle_outline, size: AppIconSize.sm),
            tooltip: 'Remove',
            onPressed: widget.onDelete,
          ),
        ],
      ),
    );
  }
}
