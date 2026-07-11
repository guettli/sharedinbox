import 'package:flutter/material.dart';

import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/ui/theme/spacing.dart';

/// Callback used by [FolderTreePickerDialog] to create a new folder.
///
/// [parentDisplayPath] is null for a top-level folder, otherwise the
/// [Mailbox.displayPath] of the folder the new one should live under.
/// Should return the created mailbox on success, or throw to keep the
/// picker open with an error [SnackBar].
typedef FolderCreateCallback = Future<Mailbox> Function({
  required String name,
  String? parentDisplayPath,
});

/// Opens a dialog that lets the user pick a mailbox from a hierarchical tree.
///
/// [mailboxesStream] emits the flat list to show; the tree is built by
/// splitting each [Mailbox.displayPath] on `/`, so JMAP mailboxes render as
/// their human-readable folder tree (not as opaque server IDs). The dialog
/// re-renders as new emissions arrive, so a folder just created via
/// [onCreate] (or one that streams in from a concurrent sync) shows up
/// without needing to reopen the picker. Returns the chosen mailbox's
/// `displayPath`, or `null` if the user dismissed the dialog.
///
/// [initialPath] selects/expands the matching entry — accepts either a
/// `displayPath` or a legacy `path` (opaque JMAP ID) for backward compat.
///
/// When [onCreate] is provided, a "New folder…" affordance appears in the
/// dialog action bar (for top-level creation) and as a trailing "+" icon on
/// each real folder row (for creating a subfolder under that row).
Future<String?> showFolderTreePicker(
  BuildContext context, {
  required Stream<List<Mailbox>> mailboxesStream,
  String? initialPath,
  FolderCreateCallback? onCreate,
}) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => FolderTreePickerDialog(
      mailboxesStream: mailboxesStream,
      initialPath: initialPath,
      onCreate: onCreate,
    ),
  );
}

class FolderTreePickerDialog extends StatefulWidget {
  const FolderTreePickerDialog({
    super.key,
    required this.mailboxesStream,
    this.initialPath,
    this.onCreate,
  });

  final Stream<List<Mailbox>> mailboxesStream;
  final String? initialPath;
  final FolderCreateCallback? onCreate;

  @override
  State<FolderTreePickerDialog> createState() => _FolderTreePickerDialogState();
}

class _FolderTreePickerDialogState extends State<FolderTreePickerDialog> {
  List<_FolderNode> _roots = const [];
  List<Mailbox> _mailboxes = const [];
  String? _initialDisplayPath;
  final Set<String> _expanded = {};
  bool _resolved = false;
  bool _creating = false;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Mailbox>>(
      stream: widget.mailboxesStream,
      builder: (ctx, snap) {
        final data = snap.data;
        if (data != null) {
          _mailboxes = data;
          _roots = _buildTree(data);
          if (!_resolved) {
            _initialDisplayPath = _resolveInitial(data, widget.initialPath);
            final init = _initialDisplayPath;
            if (init != null && init.contains('/')) {
              final parts = init.split('/');
              for (var i = 1; i < parts.length; i++) {
                _expanded.add(parts.take(i).join('/'));
              }
            }
            _resolved = true;
          }
        }
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
            if (widget.onCreate != null)
              TextButton.icon(
                onPressed:
                    _creating ? null : () => _promptCreate(parent: null),
                icon: _creating
                    ? const SizedBox(
                        width: AppIconSize.sm,
                        height: AppIconSize.sm,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(
                        Icons.create_new_folder_outlined,
                        size: AppIconSize.sm,
                      ),
                label: const Text('New folder…'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    );
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
                if (widget.onCreate != null && node.displayPath != null)
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    iconSize: AppIconSize.sm,
                    tooltip: 'New subfolder…',
                    icon: const Icon(Icons.create_new_folder_outlined),
                    onPressed: _creating
                        ? null
                        : () => _promptCreate(parent: node.displayPath),
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

  Future<void> _promptCreate({required String? parent}) async {
    final onCreate = widget.onCreate;
    if (onCreate == null) return;
    final existingSiblings = _siblingsUnder(parent);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => _NewFolderDialog(
        parentDisplayPath: parent,
        existingSiblings: existingSiblings,
      ),
    );
    if (name == null || !mounted) return;
    setState(() => _creating = true);
    try {
      final mailbox = await onCreate(name: name, parentDisplayPath: parent);
      if (!mounted) return;
      // Expand the parent chain so the new folder is visible when the
      // stream update arrives, then pop with the new displayPath.
      final displayPath = mailbox.displayPath;
      if (displayPath.contains('/')) {
        final parts = displayPath.split('/');
        for (var i = 1; i < parts.length; i++) {
          _expanded.add(parts.take(i).join('/'));
        }
      }
      Navigator.pop(context, displayPath);
    } catch (e) {
      if (!mounted) return;
      setState(() => _creating = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not create folder: $e')),
      );
    }
  }

  /// Returns the leaf names of every mailbox that would be a sibling of a
  /// new folder created under [parentDisplayPath] (or of a new top-level
  /// folder when null). Used to reject duplicates before hitting the server.
  Set<String> _siblingsUnder(String? parentDisplayPath) {
    final siblings = <String>{};
    for (final m in _mailboxes) {
      final parts = m.displayPath.split('/');
      final parent = parts.length > 1
          ? parts.sublist(0, parts.length - 1).join('/')
          : null;
      if (parent == parentDisplayPath) {
        siblings.add(parts.last);
      }
    }
    return siblings;
  }
}

class _NewFolderDialog extends StatefulWidget {
  const _NewFolderDialog({
    required this.parentDisplayPath,
    required this.existingSiblings,
  });

  final String? parentDisplayPath;
  final Set<String> existingSiblings;

  @override
  State<_NewFolderDialog> createState() => _NewFolderDialogState();
}

class _NewFolderDialogState extends State<_NewFolderDialog> {
  final _controller = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String? _validate(String? raw) {
    final name = raw?.trim() ?? '';
    if (name.isEmpty) return 'Enter a name';
    if (name.contains('/')) return 'Name cannot contain "/"';
    if (widget.existingSiblings.contains(name)) {
      return 'A folder with this name already exists here';
    }
    return null;
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(context, _controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final parent = widget.parentDisplayPath;
    return AlertDialog(
      title: const Text('New folder'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              parent == null ? 'At top level' : 'Under: $parent',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.sm),
            TextFormField(
              controller: _controller,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Folder name'),
              onFieldSubmitted: (_) => _submit(),
              validator: _validate,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
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
