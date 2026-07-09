import 'package:flutter/material.dart';

import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';

/// Opens a dialog that lets the user pick a mailbox from a hierarchical tree.
///
/// [mailboxes] is the flat list to show; the tree is built by splitting each
/// [Mailbox.displayPath] on `/`, so JMAP mailboxes render as their
/// human-readable folder tree (not as opaque server IDs). Returns the chosen
/// mailbox's `displayPath`, or `null` if the user dismissed the dialog.
/// [initialPath] selects/expands the matching entry — accepts either a
/// `displayPath` or a legacy `path` (opaque JMAP ID) for backward compat.
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
  late final String? _initialDisplayPath;
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    _roots = _buildTree(widget.mailboxes);
    // Accept either a displayPath or a legacy path (opaque JMAP ID) as
    // initialPath — resolve both to the canonical displayPath so the tree
    // highlights the matching row regardless of what the caller stored.
    _initialDisplayPath = _resolveInitial(widget.mailboxes, widget.initialPath);
    final init = _initialDisplayPath;
    if (init != null && init.contains('/')) {
      final parts = init.split('/');
      for (var i = 1; i < parts.length; i++) {
        _expanded.add(parts.take(i).join('/'));
      }
    }
  }

  static String? _resolveInitial(List<Mailbox> mailboxes, String? initial) {
    if (initial == null || initial.isEmpty) return null;
    for (final m in mailboxes) {
      if (m.displayPath == initial) return m.displayPath;
    }
    for (final m in mailboxes) {
      if (m.path == initial) return m.displayPath;
    }
    return initial;
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
    final isSelected =
        node.displayPath != null && node.displayPath == _initialDisplayPath;
    final indent = AppSpacing.md + depth * AppSpacing.lg;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: node.displayPath == null
              ? (hasChildren ? () => _toggle(node.key) : null)
              : () => Navigator.pop(context, node.displayPath),
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
                      color: node.displayPath == null
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
          for (final child in node.children) _buildRow(child, depth: depth + 1),
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

  /// Unique key for expansion tracking — equals the joined displayPath prefix.
  final String key;
  final String label;

  /// The mailbox's `displayPath` when this node corresponds to a real
  /// mailbox. `null` means the node is a phantom parent inferred from a
  /// child's path components.
  String? displayPath;
  final Map<String, _FolderNode> _children = {};

  List<_FolderNode> get children => _children.values.toList(growable: false);
}

/// Builds a hierarchy by splitting each [Mailbox.displayPath] on `/`.
/// Mailboxes that share a prefix become siblings under a common parent;
/// intermediate components that do not exist as real mailboxes become phantom
/// parents. Roots are sorted with [compareMailboxes] when both have a backing
/// mailbox, alphabetically otherwise.
List<_FolderNode> _buildTree(List<Mailbox> mailboxes) {
  final roots = <String, _FolderNode>{};
  final byDisplayPath = {for (final m in mailboxes) m.displayPath: m};

  for (final m in mailboxes) {
    final parts = m.displayPath.split('/');
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
      if (isLeaf) node.displayPath = m.displayPath;
      level = node._children;
    }
  }

  final sortedRoots = roots.values.toList()
    ..sort((a, b) => _compareNodes(a, b, byDisplayPath));
  for (final node in sortedRoots) {
    _sortDescendants(node, byDisplayPath);
  }
  return sortedRoots;
}

void _sortDescendants(_FolderNode node, Map<String, Mailbox> byDisplayPath) {
  final sorted = node._children.values.toList()
    ..sort((a, b) => _compareNodes(a, b, byDisplayPath));
  node._children
    ..clear()
    ..addEntries(sorted.map((c) => MapEntry(c.key, c)));
  for (final c in node._children.values) {
    _sortDescendants(c, byDisplayPath);
  }
}

int _compareNodes(
  _FolderNode a,
  _FolderNode b,
  Map<String, Mailbox> byDisplayPath,
) {
  final ma = a.displayPath == null ? null : byDisplayPath[a.displayPath];
  final mb = b.displayPath == null ? null : byDisplayPath[b.displayPath];
  if (ma != null && mb != null) return compareMailboxes(ma, mb);
  return a.label.toLowerCase().compareTo(b.label.toLowerCase());
}
