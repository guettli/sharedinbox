import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/ui/widgets/swipe_tree/swipe_tree_geometry.dart';

void main() {
  const geo = SwipeTreeGeometry();
  const center = Offset(200, 200);

  group('nodeOffsets', () {
    test('empty for zero children', () {
      expect(geo.nodeOffsets(center, 0), isEmpty);
    });

    test('places the first node straight above the centre', () {
      final offsets = geo.nodeOffsets(center, 4);
      expect(offsets, hasLength(4));
      expect(offsets.first.dx, closeTo(center.dx, 0.001));
      expect(offsets.first.dy, closeTo(center.dy - geo.ringRadius, 0.001));
    });

    test('spreads every node onto the ring at ringRadius', () {
      for (final o in geo.nodeOffsets(center, 6)) {
        expect((o - center).distance, closeTo(geo.ringRadius, 0.001));
      }
    });
  });

  group('isInCenter', () {
    test('true within the centre radius, false outside', () {
      expect(geo.isInCenter(center, center), isTrue);
      expect(
        geo.isInCenter(center, center + Offset(geo.centerRadius - 1, 0)),
        isTrue,
      );
      expect(
        geo.isInCenter(center, center + Offset(geo.centerRadius + 5, 0)),
        isFalse,
      );
    });
  });

  group('nodeIndexAt', () {
    test('returns the index of the node under the pointer', () {
      final offsets = geo.nodeOffsets(center, 4);
      for (var i = 0; i < offsets.length; i++) {
        expect(geo.nodeIndexAt(center, 4, offsets[i]), i);
      }
    });

    test('returns null when the pointer is over no node', () {
      // The centre is far from every ring node.
      expect(geo.nodeIndexAt(center, 4, center), isNull);
    });
  });

  group('scrubberValue', () {
    test('clamps to min at/inside the inner radius', () {
      expect(
        geo.scrubberValue(center, center, min: 0, max: 100),
        0,
      );
      expect(
        geo.scrubberValue(
          center,
          center + Offset(geo.scrubberInner - 5, 0),
          min: 0,
          max: 100,
        ),
        0,
      );
    });

    test('clamps to max at/beyond the outer radius', () {
      expect(
        geo.scrubberValue(
          center,
          center + Offset(geo.scrubberOuter + 50, 0),
          min: 0,
          max: 100,
        ),
        100,
      );
    });

    test('scales linearly between inner and outer radius', () {
      final mid = (geo.scrubberInner + geo.scrubberOuter) / 2;
      expect(
        geo.scrubberValue(center, center + Offset(mid, 0), min: 0, max: 100),
        closeTo(50, 1),
      );
    });

    test('honours a non-zero min', () {
      expect(
        geo.scrubberValue(center, center, min: 1, max: 10),
        1,
      );
    });
  });
}
