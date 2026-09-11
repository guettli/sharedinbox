/// Turns a flat list of a conversation's messages into a reply tree, linking
/// each message to its parent via the `In-Reply-To` / `References` headers so
/// the detail screen can render nested replies that span folders (#754).
library;

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/utils/message_id_utils.dart';

/// One message in a conversation tree, plus its replies and how deeply it is
/// nested (roots are depth 0).
class ConversationNode {
  ConversationNode({
    required this.email,
    required this.children,
    required this.depth,
  });

  final Email email;
  final List<ConversationNode> children;
  final int depth;
}

/// Builds the reply forest for [emails] (all messages of one conversation).
///
/// A message's parent is the nearest ancestor named by its `In-Reply-To`, then
/// its `References` (immediate parent last, so scanned in reverse), that is
/// itself present in the list. Messages with no resolvable parent are roots.
/// Children — and roots — are ordered oldest first.
///
/// Broken chains that reference each other in a loop (A replies to B, B replies
/// to A) would otherwise recurse forever; a `visited` set makes every message
/// appear exactly once, so assembly always terminates. Any message left
/// unreachable by such a cycle is promoted to a root.
List<ConversationNode> buildConversationTree(List<Email> emails) {
  if (emails.isEmpty) return const [];

  int compareByDate(Email a, Email b) {
    final da = a.sentAt ?? a.receivedAt;
    final db = b.sentAt ?? b.receivedAt;
    return da.compareTo(db);
  }

  // Index by canonical Message-ID. Cross-folder copies of the same message can
  // share a Message-ID; the first (earliest, since the caller sorts by date)
  // wins so the map is stable.
  final byMessageId = <String, Email>{};
  for (final e in emails) {
    final id = normaliseMessageId(e.messageId);
    if (id != null) byMessageId.putIfAbsent(id, () => e);
  }

  Email? parentOf(Email e) {
    final ownId = normaliseMessageId(e.messageId);
    final candidates = <String>[
      if (normaliseMessageId(e.inReplyTo) != null)
        normaliseMessageId(e.inReplyTo)!,
      ...?_referenceIds(e.references)?.reversed,
    ];
    for (final candidate in candidates) {
      if (candidate == ownId) continue;
      final parent = byMessageId[candidate];
      if (parent != null && parent.id != e.id) return parent;
    }
    return null;
  }

  final childrenByParentId = <String, List<Email>>{};
  final roots = <Email>[];
  for (final e in emails) {
    final parent = parentOf(e);
    if (parent == null) {
      roots.add(e);
    } else {
      childrenByParentId.putIfAbsent(parent.id, () => []).add(e);
    }
  }

  final visited = <String>{};
  List<ConversationNode> assemble(List<Email> level, int depth) {
    level.sort(compareByDate);
    final nodes = <ConversationNode>[];
    for (final e in level) {
      // Cycle/duplicate guard: a message already placed is not descended into
      // again, so a References loop cannot recurse forever.
      if (!visited.add(e.id)) continue;
      final children = childrenByParentId[e.id] ?? const <Email>[];
      nodes.add(
        ConversationNode(
          email: e,
          children: assemble(List.of(children), depth + 1),
          depth: depth,
        ),
      );
    }
    return nodes;
  }

  final tree = assemble(roots, 0);

  // Promote any message stranded inside a reference cycle (unreachable from a
  // root) to its own root so nothing is silently dropped.
  final stranded = emails.where((e) => !visited.contains(e.id)).toList();
  if (stranded.isNotEmpty) tree.addAll(assemble(stranded, 0));

  return tree;
}

List<String>? _referenceIds(String? references) {
  final normalised = normaliseReferences(references);
  if (normalised == null) return null;
  return normalised.split(' ');
}
