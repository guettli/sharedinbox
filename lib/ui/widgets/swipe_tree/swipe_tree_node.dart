import 'dart:async';

import 'package:flutter/widgets.dart';

/// A node in the swipe-action tree.
///
/// The tree is opened by a horizontal swipe on a mail row: the root's children
/// fan out around the finger and the user drags to a node and releases to pick
/// it (see [SwipeActionMenu]). A node is one of:
///
/// * [ActionNode] — a leaf that runs [ActionNode.onInvoke] on release.
/// * [BranchNode] — an edge that, when entered, replaces the fan with its
///   [BranchNode.children].
/// * [ScrubberNode] — a leaf that opens a radial value dial (`min…max`) and
///   reports the picked integer through [ScrubberNode.onPick] on release.
sealed class SwipeTreeNode {
  const SwipeTreeNode({
    required this.icon,
    required this.label,
    required this.color,
  });

  /// Icon rendered in the node's chip.
  final IconData icon;

  /// Short label rendered under the icon.
  final String label;

  /// Accent colour for the chip.
  final Color color;
}

/// A leaf that performs an action when released on.
class ActionNode extends SwipeTreeNode {
  const ActionNode({
    required super.icon,
    required super.label,
    required super.color,
    required this.onInvoke,
  });

  /// Runs when the user releases the swipe over this node.
  final FutureOr<void> Function() onInvoke;
}

/// An edge whose [children] replace the current fan once the finger enters it.
///
/// When [children] is empty and [loadChildren] is set, the children are fetched
/// lazily the first time the finger enters this branch (used for the dynamic
/// `Move → folders` level, whose folder list is account-specific and loaded
/// asynchronously).
class BranchNode extends SwipeTreeNode {
  const BranchNode({
    required super.icon,
    required super.label,
    required super.color,
    this.children = const [],
    this.loadChildren,
  });

  final List<SwipeTreeNode> children;
  final Future<List<SwipeTreeNode>> Function()? loadChildren;
}

/// A leaf that opens a radial scrubber selecting an integer in `[min, max]`.
///
/// Used for the `Snooze → Days/Weeks → 0…100` levels, where a fan of 101 chips
/// would be impractical. The finger's distance from the level centre maps to
/// the value; [format] renders the live readout and [onPick] receives the final
/// value on release. A picked value of [min] is treated as a cancel by callers
/// that wire it that way (e.g. "snooze 0 days" is a no-op).
class ScrubberNode extends SwipeTreeNode {
  const ScrubberNode({
    required super.icon,
    required super.label,
    required super.color,
    required this.onPick,
    this.min = 0,
    this.max = 100,
    this.format,
  });

  final int min;
  final int max;
  final void Function(int value) onPick;

  /// Renders the centre readout for [value]. Defaults to `"$value $label"`.
  final String Function(int value)? format;

  String formatValue(int value) => format?.call(value) ?? '$value $label';
}
