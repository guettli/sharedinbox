import 'dart:async';

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import 'package:sharedinbox/ui/widgets/swipe_tree/swipe_tree_geometry.dart';
import 'package:sharedinbox/ui/widgets/swipe_tree/swipe_tree_node.dart';

/// Wraps [child] (a mail row) and opens a radial tree of actions on a
/// horizontal swipe, replacing the old left/right archive/delete `Dismissible`
/// (#240).
///
/// The root's children fan out on a circle around the finger. Dragging onto a
/// node highlights it; entering a [BranchNode] replaces the fan with its
/// children (loaded lazily via [BranchNode.loadChildren] when needed); entering
/// a [ScrubberNode] opens a radial value dial. Releasing over a leaf runs it;
/// releasing in the central zone (or dragging back into it) steps up a level;
/// releasing over nothing cancels.
///
/// [buildRoot] is called each time a swipe starts so the tree can reflect the
/// current selection (single row vs. batch). It must return a [BranchNode].
class SwipeActionMenu extends StatefulWidget {
  const SwipeActionMenu({
    super.key,
    required this.child,
    required this.buildRoot,
    this.geometry = const SwipeTreeGeometry(),
  });

  final Widget child;
  final BranchNode Function() buildRoot;
  final SwipeTreeGeometry geometry;

  @override
  State<SwipeActionMenu> createState() => _SwipeActionMenuState();
}

class _Level {
  _Level.fan(this.center, this.nodes, {this.source}) : scrubber = null;
  _Level.scrubber(this.center, ScrubberNode this.scrubber)
      : nodes = const [],
        source = scrubber;

  final Offset center;
  List<SwipeTreeNode> nodes;
  final ScrubberNode? scrubber;

  /// The branch/scrubber node this level was opened from (null for the root).
  final SwipeTreeNode? source;

  bool get isScrubber => scrubber != null;
}

// Placeholder shown while a branch's children are loading.
const _loadingNode = ActionNode(
  icon: Icons.hourglass_empty,
  label: '…',
  color: Colors.grey,
  onInvoke: _noop,
);

void _noop() {}

class _SwipeActionMenuState extends State<SwipeActionMenu> {
  SwipeTreeGeometry get _geo => widget.geometry;

  OverlayEntry? _entry;
  final List<_Level> _stack = [];
  int? _activeIndex;
  Offset _pointer = Offset.zero;
  bool _wasInCenter = false;
  int _scrubberValue = 0;

  // Children loaded lazily per branch node, keyed by identity so a re-open
  // reuses the previous result.
  final Map<BranchNode, List<SwipeTreeNode>> _loaded = {};

  @override
  void dispose() {
    _removeOverlay();
    super.dispose();
  }

  void _removeOverlay() {
    _entry?.remove();
    _entry = null;
  }

  void _rebuildOverlay() => _entry?.markNeedsBuild();

  // ---- gesture ------------------------------------------------------------

  void _onStart(DragStartDetails d) {
    final root = widget.buildRoot();
    if (root.children.isEmpty) return;
    _pointer = d.globalPosition;
    _stack
      ..clear()
      ..add(_Level.fan(_pointer, root.children, source: root));
    _activeIndex = null;
    _wasInCenter = true;
    unawaited(HapticFeedback.selectionClick());

    _entry = OverlayEntry(builder: _buildOverlay);
    Overlay.of(context).insert(_entry!);
  }

  void _onUpdate(DragUpdateDetails d) {
    if (_entry == null || _stack.isEmpty) return;
    _pointer = d.globalPosition;
    final top = _stack.last;

    if (top.isScrubber) {
      final v = _geo.scrubberValue(
        top.center,
        _pointer,
        min: top.scrubber!.min,
        max: top.scrubber!.max,
      );
      if (v != _scrubberValue) {
        _scrubberValue = v;
        unawaited(HapticFeedback.selectionClick());
      }
      _rebuildOverlay();
      return;
    }

    final inCenter = _geo.isInCenter(top.center, _pointer);
    if (inCenter) {
      if (!_wasInCenter && _stack.length > 1) {
        _popLevel();
      } else {
        _setActive(null);
      }
      _wasInCenter = true;
      _rebuildOverlay();
      return;
    }
    _wasInCenter = false;

    final idx = _geo.nodeIndexAt(top.center, top.nodes.length, _pointer);
    _setActive(idx);
    if (idx != null) {
      final node = top.nodes[idx];
      if (node is BranchNode) {
        _enterBranch(node);
      } else if (node is ScrubberNode) {
        _enterScrubber(node);
      }
    }
    _rebuildOverlay();
  }

  void _onEnd(DragEndDetails d) {
    if (_entry == null || _stack.isEmpty) {
      _teardown();
      return;
    }
    final top = _stack.last;
    if (top.isScrubber) {
      unawaited(HapticFeedback.mediumImpact());
      top.scrubber!.onPick(_scrubberValue);
    } else if (_activeIndex != null) {
      final node = top.nodes[_activeIndex!];
      if (node is ActionNode) {
        unawaited(HapticFeedback.mediumImpact());
        final result = node.onInvoke();
        if (result is Future) unawaited(result);
      }
    }
    _teardown();
  }

  void _teardown() {
    _removeOverlay();
    _stack.clear();
    _activeIndex = null;
    _wasInCenter = false;
    _scrubberValue = 0;
  }

  // ---- navigation ---------------------------------------------------------

  void _setActive(int? idx) {
    if (idx == _activeIndex) return;
    _activeIndex = idx;
    if (idx != null) unawaited(HapticFeedback.selectionClick());
  }

  void _popLevel() {
    _stack.removeLast();
    _activeIndex = null;
    final top = _stack.last;
    _wasInCenter = _geo.isInCenter(top.center, _pointer);
    unawaited(HapticFeedback.selectionClick());
  }

  void _enterBranch(BranchNode node) {
    final List<SwipeTreeNode> children;
    if (node.children.isNotEmpty) {
      children = node.children;
    } else if (_loaded[node] != null) {
      children = _loaded[node]!;
    } else if (node.loadChildren != null) {
      children = const [_loadingNode];
      unawaited(_startLoad(node));
    } else {
      children = const [];
    }
    _stack.add(_Level.fan(_pointer, List.of(children), source: node));
    _activeIndex = null;
    _wasInCenter = true;
  }

  void _enterScrubber(ScrubberNode node) {
    _stack.add(_Level.scrubber(_pointer, node));
    _scrubberValue = node.min;
    _activeIndex = null;
    _wasInCenter = true;
  }

  Future<void> _startLoad(BranchNode node) async {
    final children = await node.loadChildren!();
    if (!mounted) return;
    _loaded[node] = children;
    // Only patch the visible level if the finger is still inside this branch.
    if (_stack.isNotEmpty && identical(_stack.last.source, node)) {
      _stack.last.nodes = children.isEmpty
          ? const [
              ActionNode(
                icon: Icons.folder_off_outlined,
                label: 'None',
                color: Colors.grey,
                onInvoke: _noop,
              ),
            ]
          : children;
      _rebuildOverlay();
    }
  }

  // ---- rendering ----------------------------------------------------------

  Widget _buildOverlay(BuildContext context) {
    if (_stack.isEmpty) return const SizedBox.shrink();
    final top = _stack.last;
    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          children: [
            const ModalBarrier(color: Colors.black26),
            if (top.isScrubber)
              ..._scrubberWidgets(top)
            else
              ..._fanWidgets(top),
          ],
        ),
      ),
    );
  }

  List<Widget> _fanWidgets(_Level level) {
    final offsets = _geo.nodeOffsets(level.center, level.nodes.length);
    return [
      _centerDot(level.center),
      for (var i = 0; i < level.nodes.length; i++)
        _chip(level.nodes[i], offsets[i], active: i == _activeIndex),
    ];
  }

  List<Widget> _scrubberWidgets(_Level level) {
    final s = level.scrubber!;
    return [
      Positioned(
        left: level.center.dx - 60,
        top: level.center.dy - 60,
        child: Container(
          width: 120,
          height: 120,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: s.color,
            shape: BoxShape.circle,
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8)],
          ),
          child: Text(
            s.formatValue(_scrubberValue),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    ];
  }

  Widget _centerDot(Offset center) => Positioned(
        left: center.dx - 6,
        top: center.dy - 6,
        child: Container(
          width: 12,
          height: 12,
          decoration: const BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
          ),
        ),
      );

  Widget _chip(SwipeTreeNode node, Offset at, {required bool active}) {
    final hasChildren = node is BranchNode || node is ScrubberNode;
    return Positioned(
      left: at.dx - 30,
      top: at.dy - 30,
      child: AnimatedScale(
        scale: active ? 1.25 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          width: 60,
          height: 60,
          decoration: BoxDecoration(
            color: active ? node.color : node.color.withValues(alpha: 0.9),
            shape: BoxShape.circle,
            border: active ? Border.all(color: Colors.white, width: 3) : null,
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
          ),
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(node.icon, color: Colors.white, size: 22),
              Text(
                hasChildren ? '${node.label} ›' : node.label,
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: const TextStyle(color: Colors.white, fontSize: 9),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Anchor the fan at the initial touch point rather than where the drag is
      // first recognised, so the menu opens under the finger.
      dragStartBehavior: DragStartBehavior.down,
      // Only a horizontal drag opens the menu, so the vertical list still
      // scrolls and a still-finger long-press still toggles selection.
      onHorizontalDragStart: _onStart,
      onHorizontalDragUpdate: _onUpdate,
      onHorizontalDragEnd: _onEnd,
      onHorizontalDragCancel: _teardown,
      child: widget.child,
    );
  }
}
