import 'dart:io';
import 'package:test/test.dart';

void main() {
  test('coverage exclusion list contains no ghost paths', () {
    final scriptFile = File('scripts/check_coverage.dart');
    expect(
      scriptFile.existsSync(),
      isTrue,
      reason: 'scripts/check_coverage.dart must exist',
    );

    final content = scriptFile.readAsStringSync();

    // Extract paths using a simple regex: 'lib/...'
    final pathRegex = RegExp(r"'([^']+)'");
    final paths = <String>{};

    bool inNoCode = false;
    bool inExcluded = false;

    for (final line in content.split('\n')) {
      if (line.startsWith('const _noCode = {')) {
        inNoCode = true;
      } else if (line.startsWith('const _excluded = {')) {
        inExcluded = true;
      } else if (line.startsWith('};')) {
        inNoCode = false;
        inExcluded = false;
      } else if ((inNoCode || inExcluded) && line.trim().startsWith("'")) {
        final match = pathRegex.firstMatch(line);
        if (match != null) {
          paths.add(match.group(1)!);
        }
      }
    }

    expect(paths, isNotEmpty, reason: 'Should have found some excluded paths');

    for (final path in paths) {
      expect(
        File(path).existsSync(),
        isTrue,
        reason: 'Ghost path found in check_coverage.dart: $path',
      );
    }
  });
}
