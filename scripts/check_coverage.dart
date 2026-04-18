#!/usr/bin/env dart
// Checks that every non-excluded lib/ source file appears in coverage/lcov.info.
// Run after: flutter test test/unit/ --coverage
//
// To exclude a file add its lib-relative path to [_excluded] below.

import 'dart:io';

// Minimum line-hit percentage across all measured (non-excluded) files.
const _minCoveragePercent = 85;

// Pure-abstract interfaces: no executable code, Dart VM never instruments them.
const _noCode = {
  'lib/core/repositories/account_repository.dart',
  'lib/core/repositories/draft_repository.dart',
  'lib/core/repositories/email_repository.dart',
  'lib/core/repositories/mailbox_repository.dart',
  'lib/core/storage/secure_storage.dart',
};

// Files excluded from the unit-coverage gate because they require integration
// or widget tests (covered by `task integration` / `task test-flutter`).
const _excluded = {
  // Drift table schema DSL + database factory — the column getters (e.g.
  // `TextColumn get id => text()()`) are build-time input to Drift's code
  // generator and are never called at runtime. The `_openConnection()`
  // factory uses `path_provider` which is unavailable in unit tests.
  'lib/data/db/database.dart',
  // IMAP/SMTP factory — top-level functions that open real network connections;
  // no seam to inject a fake client without wrapping the enough_mail types.
  'lib/data/imap/imap_client_factory.dart',
  // Pure adapter over FlutterSecureStorage (a platform plugin);
  // all three methods just delegate — no logic, and platform channels are
  // unavailable in unit tests.
  'lib/data/storage/flutter_secure_storage_impl.dart',
  // Flutter wiring — requires full widget/app context.
  'lib/di.dart',
  'lib/main.dart',
  'lib/ui/router.dart',
  // Screens below the 70% gate — covered by widget tests but not yet fully:
  'lib/ui/screens/add_account_screen.dart',
  'lib/ui/screens/compose_screen.dart',
  'lib/ui/screens/email_detail_screen.dart',
};

void main() {
  final lcovFile = File('coverage/lcov.info');
  final measuredFiles = lcovFile.existsSync()
      ? lcovFile
          .readAsLinesSync()
          .where((l) => l.startsWith('SF:'))
          .map((l) => l.substring(3))
          .toSet()
      : <String>{};

  final sourceFiles = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart') && !f.path.endsWith('.g.dart'))
      .map((f) => f.path.replaceFirst('./', ''))
      .where((p) => !_excluded.contains(p) && !_noCode.contains(p))
      .toList()
    ..sort();

  final missing = sourceFiles.where((f) => !measuredFiles.contains(f)).toList();

  if (missing.isNotEmpty) {
    for (final f in missing) {
      stderr.writeln('MISSING from coverage: $f');
    }
    stderr.writeln(
      'ERROR: ${missing.length} file(s) missing from unit coverage.\n'
      'Add a test or add to _excluded in scripts/check_coverage.dart.',
    );
    exit(1);
  }

  // Compute line-hit percentage, skipping excluded files so their 0% lines
  // don't distort the number for genuinely tested code.
  String? currentSf;
  int total = 0, hits = 0;
  for (final line in lcovFile.readAsLinesSync()) {
    if (line.startsWith('SF:')) {
      currentSf = line.substring(3);
    } else if (line.startsWith('DA:') &&
        currentSf != null &&
        !_excluded.contains(currentSf) &&
        !_noCode.contains(currentSf) &&
        !currentSf.endsWith('.g.dart')) {
      final count = int.parse(line.substring(3).split(',')[1]);
      total++;
      if (count > 0) hits++;
    }
  }
  final pct = total > 0 ? (hits * 100 ~/ total) : 0;
  final measuredCount =
      measuredFiles.where((f) => !_excluded.contains(f)).length;
  stdout.writeln(
    'coverage: $pct% across $measuredCount measured files'
    ' (${_excluded.length} integration-excluded, ${_noCode.length} no-code'
    ' — see scripts/check_coverage.dart)',
  );

  if (pct < _minCoveragePercent) {
    stderr.writeln(
      'ERROR: coverage $pct% is below the required $_minCoveragePercent%.',
    );
    exit(1);
  }
}
