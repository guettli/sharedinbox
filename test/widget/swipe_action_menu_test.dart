import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/ui/widgets/swipe_tree/swipe_action_menu.dart';
import 'package:sharedinbox/ui/widgets/swipe_tree/swipe_tree_geometry.dart';
import 'package:sharedinbox/ui/widgets/swipe_tree/swipe_tree_node.dart';

void main() {
  const geo = SwipeTreeGeometry();
  // Root fan opens at the touch point; the menu anchors there.
  const start = Offset(400, 300);

  // A 3-child root: an action, a branch (one child), and a scrubber. Node
  // offsets are deterministic given the geometry, so tests can drag straight
  // onto a node.
  late List<String> invoked;
  late int? pickedValue;

  BranchNode buildRoot() => BranchNode(
        icon: Icons.more_horiz,
        label: 'Actions',
        color: Colors.blueGrey,
        children: [
          ActionNode(
            icon: Icons.archive,
            label: 'Archive',
            color: Colors.green,
            onInvoke: () => invoked.add('archive'),
          ),
          BranchNode(
            icon: Icons.drive_file_move,
            label: 'Move',
            color: Colors.blue,
            children: [
              ActionNode(
                icon: Icons.folder,
                label: 'Work',
                color: Colors.blue,
                onInvoke: () => invoked.add('move:Work'),
              ),
            ],
          ),
          ScrubberNode(
            icon: Icons.today,
            label: 'Days',
            color: Colors.deepPurple,
            onPick: (v) => pickedValue = v,
          ),
        ],
      );

  Widget harness() => MaterialApp(
        home: Scaffold(
          body: SwipeActionMenu(
            buildRoot: buildRoot,
            child:
                const SizedBox.expand(child: ColoredBox(color: Colors.white)),
          ),
        ),
      );

  setUp(() {
    invoked = [];
    pickedValue = null;
  });

  // Node offsets for a 3-child fan around [start].
  List<Offset> rootOffsets() => geo.nodeOffsets(start, 3);

  Future<TestGesture> openMenu(WidgetTester tester) async {
    final g = await tester.startGesture(start);
    // A horizontal nudge claims the drag; DragStartBehavior.down keeps the
    // anchor at [start].
    await g.moveBy(const Offset(40, 0));
    await tester.pump();
    return g;
  }

  testWidgets('opens the fan on a horizontal swipe', (tester) async {
    await tester.pumpWidget(harness());
    final g = await openMenu(tester);
    expect(find.text('Archive'), findsOneWidget);
    expect(find.text('Move ›'), findsOneWidget);
    await g.up();
    await tester.pump();
  });

  testWidgets('release over an action node invokes it', (tester) async {
    await tester.pumpWidget(harness());
    final g = await openMenu(tester);
    await g.moveTo(rootOffsets()[0]); // Archive
    await tester.pump();
    await g.up();
    await tester.pump();
    expect(invoked, ['archive']);
  });

  testWidgets('release over empty space cancels', (tester) async {
    await tester.pumpWidget(harness());
    final g = await openMenu(tester);
    await g.moveTo(const Offset(10, 10)); // nowhere near a node
    await tester.pump();
    await g.up();
    await tester.pump();
    expect(invoked, isEmpty);
    // Overlay is torn down.
    expect(find.text('Archive'), findsNothing);
  });

  testWidgets('entering a branch swaps in its children', (tester) async {
    await tester.pumpWidget(harness());
    final g = await openMenu(tester);
    final moveOffset = rootOffsets()[1];
    await g.moveTo(moveOffset); // enter Move branch
    await tester.pump();
    expect(find.text('Work'), findsOneWidget);

    // The branch level is centred on moveOffset; its single child sits above it.
    final childOffset = geo.nodeOffsets(moveOffset, 1)[0];
    await g.moveTo(childOffset);
    await tester.pump();
    await g.up();
    await tester.pump();
    expect(invoked, ['move:Work']);
  });

  testWidgets('dragging back to the centre pops a level', (tester) async {
    await tester.pumpWidget(harness());
    final g = await openMenu(tester);
    final moveOffset = rootOffsets()[1];
    await g.moveTo(moveOffset); // enter Move (finger starts at branch centre)
    await tester.pump();
    expect(find.text('Work'), findsOneWidget);

    // Drag out to the child (leaving the centre), then back into the centre to
    // pop the level — the root fan returns.
    await g.moveTo(geo.nodeOffsets(moveOffset, 1)[0]);
    await tester.pump();
    await g.moveTo(moveOffset);
    await tester.pump();
    expect(find.text('Work'), findsNothing);
    expect(find.text('Archive'), findsOneWidget);
    await g.up();
    await tester.pump();
    expect(invoked, isEmpty);
  });

  testWidgets('scrubber picks a value from the drag distance', (tester) async {
    await tester.pumpWidget(harness());
    final g = await openMenu(tester);
    final scrubberOffset = rootOffsets()[2];
    await g.moveTo(scrubberOffset); // enter the Days scrubber
    await tester.pump();

    // Drag out to the far edge → clamps to max (100).
    await g.moveTo(scrubberOffset + const Offset(400, 0));
    await tester.pump();
    await g.up();
    await tester.pump();
    expect(pickedValue, 100);
  });
}
