import 'dart:io';
import 'package:test/test.dart';

// Guards scripts/check_coverage.dart against:
//   1. Ghost paths: entries in _excluded or _noCode that no longer exist
//      because the source file was renamed or deleted.
//   2. Missing rationales: entries in _excluded that don't explain why the
//      file cannot reasonably be unit-tested. Every exclusion should carry
//      a non-empty rationale so a future reader can decide whether the file
//      has become testable and can be lifted out of _excluded.
void main() {
  final scriptFile = File('scripts/check_coverage.dart');
  final content = scriptFile.readAsStringSync();

  test('scripts/check_coverage.dart exists', () {
    expect(scriptFile.existsSync(), isTrue);
  });

  test('_noCode entries all point to real files', () {
    final noCodePaths = _extractSetLiteral(content, r'const _noCode = {');
    expect(
      noCodePaths,
      isNotEmpty,
      reason: '_noCode should list at least one path',
    );
    for (final path in noCodePaths) {
      expect(
        File(path).existsSync(),
        isTrue,
        reason: 'Ghost path in _noCode: $path',
      );
    }
  });

  test('_excluded entries all point to real files with a rationale', () {
    final excluded = _extractMapLiteral(
      content,
      RegExp(r'const _excluded = <String, String>\{'),
    );
    expect(
      excluded,
      isNotEmpty,
      reason: '_excluded should list at least one path',
    );
    for (final entry in excluded.entries) {
      expect(
        File(entry.key).existsSync(),
        isTrue,
        reason: 'Ghost path in _excluded: ${entry.key}',
      );
      expect(
        entry.value.trim(),
        isNotEmpty,
        reason: 'Missing rationale for excluded file: ${entry.key}',
      );
    }
  });
}

/// Extracts single-quoted string entries from a Set literal that starts at
/// the line matching [header] and ends at the next line beginning with `};`.
Set<String> _extractSetLiteral(String content, String header) {
  final paths = <String>{};
  final pathRegex = RegExp(r"'([^']+)'");
  var inside = false;
  for (final line in content.split('\n')) {
    if (line.startsWith(header)) {
      inside = true;
      continue;
    }
    if (inside && line.startsWith('};')) return paths;
    if (inside) {
      final match = pathRegex.firstMatch(line);
      if (match != null) paths.add(match.group(1)!);
    }
  }
  return paths;
}

/// Extracts key/value pairs from a `Map<String, String>` literal.
///
/// Handles the value on either the same line as the key (`'k': 'v',`) or on
/// the next line (`'k':\n    'v',`), which is how `dart format` wraps long
/// entries.
Map<String, String> _extractMapLiteral(String content, RegExp header) {
  final entries = <String, String>{};
  final lines = content.split('\n');
  var inside = false;
  String? pendingKey;
  for (final line in lines) {
    if (header.hasMatch(line)) {
      inside = true;
      continue;
    }
    if (inside && line.startsWith('};')) return entries;
    if (!inside) continue;

    if (pendingKey != null) {
      final valueMatch = RegExp(r"'((?:[^'\\]|\\.)*)'").firstMatch(line);
      if (valueMatch != null) {
        entries[pendingKey] = _unescape(valueMatch.group(1)!);
        pendingKey = null;
      }
      continue;
    }

    // Key on its own line: `  'lib/foo.dart':`
    final keyOnly = RegExp(r"^\s*'((?:[^'\\]|\\.)+)'\s*:\s*$").firstMatch(line);
    if (keyOnly != null) {
      pendingKey = _unescape(keyOnly.group(1)!);
      continue;
    }

    // Key and value on same line: `  'lib/foo.dart': 'because ...',`
    final both = RegExp(
      r"^\s*'((?:[^'\\]|\\.)+)'\s*:\s*'((?:[^'\\]|\\.)*)'",
    ).firstMatch(line);
    if (both != null) {
      entries[_unescape(both.group(1)!)] = _unescape(both.group(2)!);
    }
  }
  return entries;
}

String _unescape(String s) => s.replaceAll(r"\'", "'").replaceAll(r'\\', r'\');
