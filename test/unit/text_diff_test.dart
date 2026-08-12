import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/utils/text_diff.dart';

void main() {
  group('computeContextDiff', () {
    test('returns empty when the two inputs are identical', () {
      expect(computeContextDiff('same\ntext', 'same\ntext'), isEmpty);
    });

    test('marks a single changed line as removed + added', () {
      final diff = computeContextDiff('hello\nworld', 'hello\nthere');
      expect(diff, [
        const DiffLine(DiffLineKind.context, 'hello'),
        const DiffLine(DiffLineKind.removed, 'world'),
        const DiffLine(DiffLineKind.added, 'there'),
      ]);
    });

    test('keeps only context lines around a change', () {
      final a = List.generate(20, (i) => 'line$i').join('\n');
      final b =
          (List.generate(20, (i) => 'line$i')..[10] = 'CHANGED').join('\n');
      final diff = computeContextDiff(a, b);

      expect(
        diff.any((l) => l.kind == DiffLineKind.removed && l.text == 'line10'),
        isTrue,
      );
      expect(
        diff.any((l) => l.kind == DiffLineKind.added && l.text == 'CHANGED'),
        isTrue,
      );
      // The far-away identical lines are not emitted.
      expect(diff.any((l) => l.text == 'line0'), isFalse);
      expect(diff.any((l) => l.text == 'line19'), isFalse);
      // Two lines of context on each side of the change are kept.
      expect(diff.any((l) => l.text == 'line8'), isTrue);
      expect(diff.any((l) => l.text == 'line12'), isTrue);
    });

    test('collapses the equal run between two separate changes into a gap', () {
      final a = List.generate(20, (i) => 'line$i').join('\n');
      final b = (List.generate(20, (i) => 'line$i')
            ..[3] = 'FIRST'
            ..[16] = 'SECOND')
          .join('\n');
      final diff = computeContextDiff(a, b);

      // The long identical middle run collapses into a single gap marker.
      expect(diff.where((l) => l.kind == DiffLineKind.gap), hasLength(1));
      // The identical lines far from both changes are not emitted.
      expect(diff.any((l) => l.text == 'line10'), isFalse);
    });

    test('caps the output and notes how many lines were dropped', () {
      // Every other line differs so the diff is large.
      final a = List.generate(400, (i) => 'a$i').join('\n');
      final b = List.generate(400, (i) => 'b$i').join('\n');
      final diff = computeContextDiff(a, b, maxLines: 50);

      expect(diff.length, 51); // maxLines + the trailing gap marker
      expect(diff.last.kind, DiffLineKind.gap);
      expect(diff.last.text, contains('more line'));
    });

    test('normalises CRLF so pure line-ending changes are ignored', () {
      expect(computeContextDiff('a\r\nb', 'a\nb'), isEmpty);
    });
  });
}
