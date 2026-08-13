import 'package:sharedinbox/core/models/mailbox.dart';

/// A node in a folder hierarchy built from a flat list of [Mailbox]es.
///
/// The tree is derived by splitting each [Mailbox.displayPath] on `/`, so
/// JMAP mailboxes render as their human-readable folder tree (not as opaque
/// server IDs). Intermediate path components that do not exist as real
/// mailboxes become "phantom" parents whose [displayPath] is `null`.
class FolderNode {
  FolderNode({required this.key, required this.label});

  /// Unique key for expansion tracking — equals the joined displayPath prefix.
  final String key;
  final String label;

  /// The mailbox's `displayPath` when this node corresponds to a real
  /// mailbox. `null` means the node is a phantom parent inferred from a
  /// child's path components.
  String? displayPath;
  final Map<String, FolderNode> _children = {};

  List<FolderNode> get children => _children.values.toList(growable: false);
}

/// Builds a hierarchy by splitting each [Mailbox.displayPath] on `/`.
/// Mailboxes that share a prefix become siblings under a common parent;
/// intermediate components that do not exist as real mailboxes become phantom
/// parents. Roots are sorted with [compareMailboxes] when both have a backing
/// mailbox, alphabetically otherwise.
List<FolderNode> buildFolderTree(List<Mailbox> mailboxes) {
  final roots = <String, FolderNode>{};
  final byDisplayPath = {for (final m in mailboxes) m.displayPath: m};

  for (final m in mailboxes) {
    final parts = m.displayPath.split('/');
    Map<String, FolderNode> level = roots;
    final prefix = <String>[];
    for (var i = 0; i < parts.length; i++) {
      prefix.add(parts[i]);
      final key = prefix.join('/');
      final isLeaf = i == parts.length - 1;
      final node = level.putIfAbsent(
        key,
        () => FolderNode(key: key, label: parts[i]),
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

void _sortDescendants(FolderNode node, Map<String, Mailbox> byDisplayPath) {
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
  FolderNode a,
  FolderNode b,
  Map<String, Mailbox> byDisplayPath,
) {
  final ma = a.displayPath == null ? null : byDisplayPath[a.displayPath];
  final mb = b.displayPath == null ? null : byDisplayPath[b.displayPath];
  if (ma != null && mb != null) return compareMailboxes(ma, mb);
  return a.label.toLowerCase().compareTo(b.label.toLowerCase());
}
