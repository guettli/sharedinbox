import 'package:flutter/material.dart';

import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';

/// Opens a dialog that lets the user pick a mailbox from a hierarchical tree.
///
/// [mailboxes] is the flat list to show; the tree is built by splitting each
/// `path` on `/`. Returns the chosen `mailbox.path`, or `null` if the user
/// dismissed the dialog. [initialPath] selects/expands the matching entry.
Future<String?> showFolderTreePicker(
  BuildContext context, {
  required List<Mailbox> mailboxes,
  String? initialPath,
}) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => FolderTreePickerDialog(
      mailboxes: mailboxes,
      initialPath: initialPath,
    ),
  );
}

class FolderTreePickerDialog extends StatefulWidget {
  const FolderTreePickerDialog({
    super.key,
    required this.mailboxes,
    this.initialPath,
  });

  final List<Mailbox> mailboxes;
  final String? initialPath;

  @override
  State<FolderTreePickerDialog> createState() => _FolderTreePickerDialogState();
}

class _FolderTreePickerDialogState extends State<FolderTreePickerDialog> {
  late final List<_FolderNode> _roots;
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    _roots = _buildTree(widget.mailboxes);
    // Expand ancestors of the initial path so it is visible on open.
    final init = widget.initialPath;
    if (init != null && init.contains('/')) {
      final parts = init.split('/');
      for (var i = 1; i < parts.length; i++) {
        _expanded.add(parts.take(i).join('/'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Pick folder'),
      contentPadding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      content: SizedBox(
        width: 360,
        height: 400,
        child: _roots.isEmpty
            ? const Center(child: Text('No folders'))
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final node in _roots) _buildRow(node, depth: 0),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _buildRow(_FolderNode node, {required int depth}) {
    final hasChildren = node.children.isNotEmpty;
    final isExpanded = _expanded.contains(node.key);
    final isSelected = node.path != null && node.path == widget.initialPath;
    final indent = AppSpacing.md + depth * AppSpacing.lg;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: node.path == null
              ? (hasChildren ? () => _toggle(node.key) : null)
              : () => Navigator.pop(context, node.path),
          child: Padding(
            padding: EdgeInsetsDirectional.only(
              start: indent,
              end: AppSpacing.md,
              top: AppSpacing.sm,
              bottom: AppSpacing.sm,
            ),
            child: Row(
              children: [
                SizedBox(
                  width: AppIconSize.md,
                  child: hasChildren
                      ? IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          iconSize: AppIconSize.md,
                          icon: Icon(
                            isExpanded
                                ? Icons.expand_more
                                : Icons.chevron_right,
                          ),
                          onPressed: () => _toggle(node.key),
                        )
                      : const SizedBox.shrink(),
                ),
                const SizedBox(width: AppSpacing.xs),
                Icon(
                  hasChildren
                      ? (isExpanded ? Icons.folder_open : Icons.folder)
                      : Icons.folder_outlined,
                  size: AppIconSize.sm,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    node.label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: isSelected ? FontWeight.bold : null,
                      color: node.path == null
                          ? Theme.of(context).colorScheme.onSurfaceVariant
                          : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (hasChildren && isExpanded)
          for (final child in node.children)
            _buildRow(child, depth: depth + 1),
      ],
    );
  }

  void _toggle(String key) {
    setState(() {
      if (!_expanded.add(key)) _expanded.remove(key);
    });
  }
}

class _FolderNode {
  _FolderNode({required this.key, required this.label});

  /// Unique key for expansion tracking — equals the joined path prefix.
  final String key;
  final String label;

  /// Mailbox path when this node corresponds to a real mailbox. `null` means
  /// the node is a phantom parent inferred from a child's path components.
  String? path;
  final Map<String, _FolderNode> _children = {};

  List<_FolderNode> get children => _children.values.toList(growable: false);
}

/// Builds a hierarchy by splitting each `mailbox.path` on `/`. Mailboxes that
/// share a prefix become siblings under a common parent; intermediate
/// components that do not exist as real mailboxes become phantom parents.
/// Roots are sorted with [compareMailboxes] when both have a backing mailbox,
/// alphabetically otherwise.
List<_FolderNode> _buildTree(List<Mailbox> mailboxes) {
  final roots = <String, _FolderNode>{};
  final byPath = {for (final m in mailboxes) m.path: m};

  for (final m in mailboxes) {
    final parts = m.path.split('/');
    Map<String, _FolderNode> level = roots;
    final prefix = <String>[];
    for (var i = 0; i < parts.length; i++) {
      prefix.add(parts[i]);
      final key = prefix.join('/');
      final isLeaf = i == parts.length - 1;
      final node = level.putIfAbsent(
        key,
        () => _FolderNode(key: key, label: parts[i]),
      );
      if (isLeaf) node.path = m.path;
      level = node._children;
    }
  }

  final sortedRoots = roots.values.toList()
    ..sort((a, b) => _compareNodes(a, b, byPath));
  for (final node in sortedRoots) {
    _sortDescendants(node, byPath);
  }
  return sortedRoots;
}

void _sortDescendants(_FolderNode node, Map<String, Mailbox> byPath) {
  final sorted = node._children.values.toList()
    ..sort((a, b) => _compareNodes(a, b, byPath));
  node._children
    ..clear()
    ..addEntries(sorted.map((c) => MapEntry(c.key, c)));
  for (final c in node._children.values) {
    _sortDescendants(c, byPath);
  }
}

int _compareNodes(
  _FolderNode a,
  _FolderNode b,
  Map<String, Mailbox> byPath,
) {
  final ma = a.path == null ? null : byPath[a.path];
  final mb = b.path == null ? null : byPath[b.path];
  if (ma != null && mb != null) return compareMailboxes(ma, mb);
  return a.label.toLowerCase().compareTo(b.label.toLowerCase());
}
