#!/usr/bin/env dart
// Checks that every non-excluded lib/ source file appears in coverage/lcov.info.
// Run after: flutter test test/unit/ --coverage
//
// To exclude a file add its lib-relative path to [_excluded] below.

import 'dart:io';

// Minimum line-hit percentage across all measured (non-excluded) files.
const _minCoveragePercent = 70;

// Pure-abstract interfaces: no executable code, Dart VM never instruments them.
const _noCode = {
  'lib/core/repositories/account_repository.dart',
  'lib/core/repositories/email_repository.dart',
  'lib/core/repositories/mailbox_repository.dart',
};

// Files excluded from the unit-coverage gate because they require integration
// or widget tests (covered by `task integration` / `task test-flutter`).
const _excluded = {
  // Data layer — requires Drift/SQLite, IMAP/SMTP network connections.
  'lib/data/db/database.dart',
  'lib/data/imap/imap_client_factory.dart',
  'lib/data/repositories/account_repository_impl.dart',
  'lib/data/repositories/email_repository_impl.dart',
  'lib/data/repositories/mailbox_repository_impl.dart',
  // Flutter wiring — requires full widget/app context.
  'lib/di.dart',
  'lib/main.dart',
  'lib/ui/router.dart',
  'lib/ui/screens/account_list_screen.dart',
  'lib/ui/screens/add_account_screen.dart',
  'lib/ui/screens/compose_screen.dart',
  'lib/ui/screens/email_detail_screen.dart',
  'lib/ui/screens/email_list_screen.dart',
  'lib/ui/screens/mailbox_list_screen.dart',
  'lib/ui/screens/settings_screen.dart',
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
