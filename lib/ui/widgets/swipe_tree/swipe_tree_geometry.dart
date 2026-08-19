import 'dart:math' as math;
import 'dart:ui' show Offset;

/// Pure geometry for the radial swipe menu, kept free of Flutter widgets so it
/// can be unit-tested directly.
///
/// A level's children are laid out on a circle of radius [ringRadius] around
/// the level centre (the point where that level opened). Hit-testing maps a
/// pointer position to either the central "back / cancel" zone or the index of
/// the node under the finger.
class SwipeTreeGeometry {
  const SwipeTreeGeometry({
    this.ringRadius = 96,
    this.nodeRadius = 30,
    this.centerRadius = 34,
    this.scrubberInner = 40,
    this.scrubberOuter = 220,
  });

  /// Distance from the level centre to each node's centre.
  final double ringRadius;

  /// Hit radius of an individual node chip.
  final double nodeRadius;

  /// Radius of the central back/cancel zone.
  final double centerRadius;

  /// Inner/outer radii mapping distance to a [ScrubberNode] value.
  final double scrubberInner;
  final double scrubberOuter;

  /// Positions of [count] nodes evenly spread on the ring around [center].
  ///
  /// The first node sits at the top (12 o'clock) and the rest continue
  /// clockwise, so a single-child branch reads as "straight up from the
  /// finger".
  List<Offset> nodeOffsets(Offset center, int count) {
    if (count <= 0) return const [];
    final offsets = <Offset>[];
    for (var i = 0; i < count; i++) {
      final angle = -math.pi / 2 + (2 * math.pi * i) / count;
      offsets.add(
        Offset(
          center.dx + ringRadius * math.cos(angle),
          center.dy + ringRadius * math.sin(angle),
        ),
      );
    }
    return offsets;
  }

  /// True when [pointer] is inside the central back/cancel zone of [center].
  bool isInCenter(Offset center, Offset pointer) =>
      (pointer - center).distance <= centerRadius;

  /// Index of the node under [pointer], or `null` when the finger is over none.
  ///
  /// When two chips overlap the closest one wins.
  int? nodeIndexAt(Offset center, int count, Offset pointer) {
    final offsets = nodeOffsets(center, count);
    int? best;
    var bestDist = double.infinity;
    for (var i = 0; i < offsets.length; i++) {
      final d = (pointer - offsets[i]).distance;
      if (d <= nodeRadius && d < bestDist) {
        best = i;
        bestDist = d;
      }
    }
    return best;
  }

  /// Maps the finger's distance from [center] to an integer in `[min, max]`.
  ///
  /// At/inside [scrubberInner] the value is [min]; at/beyond [scrubberOuter]
  /// it is [max]; in between it scales linearly and rounds to the nearest
  /// integer.
  int scrubberValue(
    Offset center,
    Offset pointer, {
    required int min,
    required int max,
  }) {
    final d = (pointer - center).distance;
    if (d <= scrubberInner) return min;
    if (d >= scrubberOuter) return max;
    final t = (d - scrubberInner) / (scrubberOuter - scrubberInner);
    return min + (t * (max - min)).round();
  }
}
