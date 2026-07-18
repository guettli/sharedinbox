#!/usr/bin/env dart
// Checks that every non-excluded lib/ source file appears in coverage/lcov.info.
// Run after: flutter test test/unit/ --coverage
//
// To exclude a file add its lib-relative path to [_excluded] below.

import 'dart:io';

// Minimum line-hit percentage across all measured (non-excluded) files.
const _minCoveragePercent = 80;

// Pure-abstract interfaces and const-only token classes: no executable code,
// Dart VM never instruments them.
const _noCode = {
  'lib/core/db_schema_version.dart',
  'lib/core/repositories/account_repository.dart',
  'lib/core/repositories/draft_repository.dart',
  'lib/core/repositories/email_repository.dart',
  'lib/core/repositories/mailbox_repository.dart',
  'lib/core/repositories/share_key_repository.dart',
  'lib/core/repositories/sync_log_repository.dart',
  'lib/core/repositories/sync_state_repository.dart',
  'lib/core/repositories/undo_repository.dart',
  'lib/core/repositories/search_history_repository.dart',
  'lib/core/repositories/user_preferences_repository.dart',
  'lib/core/models/undo_action.dart',
  'lib/core/models/user_preferences.dart',
  'lib/core/models/note.dart',
  'lib/core/repositories/note_repository.dart',
  'lib/core/storage/secure_storage.dart',
  'lib/ui/theme/spacing.dart',
};

// Files excluded from the unit-coverage gate because they require integration
// or widget tests (covered by `task integration` / `task test-flutter`).
const _excluded = {
  'lib/data/db/database.dart',
  'lib/data/db/db_encryption_migration.dart',
  'lib/data/imap/imap_client_factory.dart',
  'lib/data/imap/managesieve_client.dart',
  'lib/data/storage/flutter_secure_storage_impl.dart',
  'lib/di.dart',
  'lib/main.dart',
  'lib/ui/router.dart',
  'lib/ui/screens/account_actions.dart',
  'lib/ui/screens/account_compare_screen.dart',
  'lib/ui/screens/account_home_screen.dart',
  'lib/ui/screens/account_list_screen.dart',
  'lib/ui/screens/account_receive_screen.dart',
  'lib/ui/screens/account_send_screen.dart',
  'lib/ui/screens/add_account_screen.dart',
  'lib/ui/screens/address_emails_screen.dart',
  'lib/ui/screens/bug_report_screen.dart',
  'lib/ui/screens/changelog_screen.dart',
  'lib/ui/screens/combined_inbox_screen.dart',
  'lib/ui/screens/compose_screen.dart',
  'lib/ui/screens/crash_screen.dart',
  'lib/ui/screens/edit_account_screen.dart',
  'lib/ui/screens/email_detail_screen.dart',
  'lib/ui/screens/email_list_screen.dart',
  'lib/ui/screens/mailbox_list_screen.dart',
  'lib/ui/screens/message_debug_screen.dart',
  'lib/ui/screens/search_screen.dart',
  'lib/ui/screens/sieve_script_edit_screen.dart',
  'lib/ui/screens/sieve_scripts_screen.dart',
  'lib/ui/screens/sync_log_screen.dart',
  'lib/ui/screens/thread_detail_screen.dart',
  'lib/ui/screens/undo_log_detail_screen.dart',
  'lib/ui/screens/undo_log_screen.dart',
  'lib/ui/widgets/app_drawer.dart',
  'lib/ui/widgets/secure_email_webview.dart',
  'lib/ui/widgets/snooze_picker.dart',
  'lib/ui/widgets/try_connection_button.dart',
  'lib/ui/widgets/undo_shell.dart',
  'lib/ui/screens/about_screen.dart',
  'lib/ui/screens/email_action_helpers.dart',
  'lib/ui/utils/about_markdown.dart',
  'lib/ui/widgets/email_headers_dialog.dart',
  'lib/ui/widgets/email_tile.dart',
  'lib/core/sync/account_comparison_provider.dart',
  'lib/core/sync/account_sync_manager.dart',
  'lib/core/sync/background_sync.dart',
  'lib/core/sync/message_probe.dart',
  'lib/core/sync/reliability_runner.dart',
  'lib/data/jmap/jmap_client.dart',
  'lib/data/jmap/sieve_repository.dart',
  'lib/data/repositories/account_repository_impl.dart',
  'lib/data/repositories/email_repository_impl.dart',
  'lib/data/repositories/mailbox_repository_impl.dart',
  'lib/data/repositories/share_key_repository_impl.dart',
  'lib/data/repositories/sync_log_repository_impl.dart',
  'lib/data/repositories/undo_repository_impl.dart',
  'lib/data/repositories/search_history_repository_impl.dart',
  'lib/data/repositories/user_preferences_repository_impl.dart',
  'lib/ui/screens/user_preferences_screen.dart',
  'lib/ui/screens/push_settings_screen.dart',
  'lib/core/services/update_service.dart',
  'lib/core/services/unified_push_service.dart',
  'lib/ui/screens/trusted_image_senders_screen.dart',
  'lib/data/repositories/note_repository_impl.dart',
  'lib/data/repositories/draft_repository_impl.dart',
  'lib/ui/widgets/filter_builder.dart',
  'lib/ui/widgets/thread_tile.dart',
  'lib/ui/widgets/email_thread_list.dart',
};

void main() {
  // Check for ghost paths in _excluded and _noCode.
  final allConfiguredPaths = {..._excluded, ..._noCode};
  for (final path in allConfiguredPaths) {
    if (!File(path).existsSync()) {
      stderr.writeln('ERROR: Ghost path found in check_coverage.dart: $path');
      exit(2);
    }
  }

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
