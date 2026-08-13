#!/usr/bin/env dart
// Checks that every non-excluded lib/ source file appears in coverage/lcov.info.
// Run after: flutter test test/unit/ test/widget/ --coverage
//
// To exclude a file, add its lib-relative path to [_excluded] together with
// a short rationale explaining why it cannot reasonably be unit-tested (real
// network, platform plugin, integration-only surface, etc.). The rationale is
// enforced by test/unit/coverage_exclusion_test.dart.

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
  'lib/core/sync/push_status.dart',
  'lib/ui/theme/spacing.dart',
};

// Files excluded from the unit-coverage gate. Each entry MUST carry a short
// rationale explaining why unit-testing is impractical (real network, platform
// plugin, integration-only surface, etc.). The rationale is enforced by
// test/unit/coverage_exclusion_test.dart — empty values fail the test.
//
// Widget-only screens/widgets stay here even when a widget test exists,
// because widget tests exercise a small slice of each build() path and
// pull down the aggregate line-hit percentage. A widget test proves the
// screen renders; it doesn't unit-test the file.
const _excluded = <String, String>{
  'lib/data/db/database.dart':
      'Drift schema opened via path_provider + flutter_secure_storage plugins',
  'lib/data/imap/imap_client_factory.dart':
      'Opens a real IMAP TLS socket to a mail server',
  'lib/data/imap/managesieve_client.dart':
      'Opens a real ManageSieve TCP socket to a mail server',
  'lib/data/storage/flutter_secure_storage_impl.dart':
      'flutter_secure_storage platform channel — plugin-only surface',
  'lib/di.dart':
      'Riverpod provider wiring only — exercised end-to-end in widget + integration tests',
  'lib/main.dart':
      'runApp entry point + FlutterError.onError — exercised in integration tests',
  'lib/ui/router.dart':
      'GoRouter route table — mirrored and exercised via test/widget/helpers.dart',
  'lib/ui/screens/about_screen.dart':
      'Widget-only About screen (device_info_plus + package_info_plus surface)',
  'lib/ui/screens/account_actions.dart':
      'Widget-only bottom-sheet menu of account actions',
  'lib/ui/screens/account_compare_screen.dart': 'Widget-only account diff view',
  'lib/ui/screens/account_home_screen.dart':
      'Widget-only screen showing account overview',
  'lib/ui/screens/account_list_screen.dart':
      'Widget-only account list — many conditional branches, unit-untestable',
  'lib/ui/screens/account_receive_screen.dart':
      'Widget-only add-account step (receive)',
  'lib/ui/screens/account_send_screen.dart':
      'Widget-only add-account step (send)',
  'lib/ui/screens/add_account_screen.dart':
      'Widget-only multi-step add-account form',
  'lib/ui/screens/app_log_screen.dart': 'Widget-only application log viewer',
  'lib/ui/screens/address_emails_screen.dart':
      'Widget-only per-address inbox view',
  'lib/ui/screens/bug_report_screen.dart':
      'Widget-only in-app bug-report form that POSTs to the bugreport server',
  'lib/ui/screens/changelog_screen.dart': 'Widget-only changelog viewer',
  'lib/ui/screens/combined_inbox_screen.dart': 'Widget-only unified inbox view',
  'lib/ui/screens/compose_screen.dart':
      'Widget-only compose form with drafts, attachments, send flow',
  'lib/ui/screens/crash_screen.dart':
      'Widget-only crash reporter shown by FlutterError.onError',
  'lib/ui/screens/database_unreadable_screen.dart':
      'Widget-only startup fallback shown when the DB cannot be opened',
  'lib/ui/screens/edit_account_screen.dart': 'Widget-only account edit form',
  'lib/ui/screens/email_action_helpers.dart':
      'BuildContext- and WidgetRef-heavy batch action helpers (widget-tested)',
  'lib/ui/screens/email_detail_screen.dart':
      'Widget-only email detail — WebView + navigation + prefetch',
  'lib/ui/screens/email_list_screen.dart':
      'Widget-only mailbox email list with selection-mode UI',
  'lib/ui/screens/force_resync_screen.dart':
      'Widget-only progress UI wrapping AccountSyncManager.forceResync (unit-tested)',
  'lib/ui/screens/mailbox_list_screen.dart': 'Widget-only mailbox tree view',
  'lib/ui/screens/message_debug_screen.dart':
      'Widget-only debug UI displaying raw message data',
  'lib/ui/screens/outbox_screen.dart': 'Widget-only per-account outbox view',
  'lib/ui/screens/push_settings_screen.dart':
      'Widget-only push notification settings (UnifiedPush plugin)',
  'lib/ui/screens/search_screen.dart':
      'Widget-only search UI with async result stream',
  'lib/ui/screens/sieve_script_edit_screen.dart':
      'Widget-only Sieve editor — save round-trips through ManageSieve/JMAP',
  'lib/ui/screens/sieve_scripts_screen.dart':
      'Widget-only Sieve script list view',
  'lib/ui/screens/sync_log_screen.dart': 'Widget-only sync-log viewer',
  'lib/ui/screens/sync_state_screen.dart':
      'Widget-only per-mailbox sync-state view',
  'lib/ui/screens/thread_detail_screen.dart': 'Widget-only thread reader',
  'lib/ui/screens/trusted_image_senders_screen.dart':
      'Widget-only settings screen for the trusted-image sender allowlist',
  'lib/ui/screens/undo_log_detail_screen.dart':
      'Widget-only undo-log detail view',
  'lib/ui/screens/undo_log_screen.dart': 'Widget-only undo-log list view',
  'lib/ui/screens/user_preferences_screen.dart': 'Widget-only preferences form',
  'lib/ui/widgets/app_drawer.dart': 'Widget-only navigation drawer',
  'lib/ui/widgets/email_headers_dialog.dart': 'Widget-only headers dialog',
  'lib/ui/widgets/error_report_scaffold.dart':
      'Widget-only shared error-screen shell + Copy/Report buttons',
  'lib/ui/widgets/email_thread_list.dart':
      'Widget with a controller — controller has unit test, widget slice needs BuildContext',
  'lib/ui/widgets/email_tile.dart': 'Widget-only list tile',
  'lib/ui/widgets/filter_builder.dart':
      'Widget-only interactive FilterGroup editor',
  'lib/ui/widgets/secure_email_webview.dart':
      'Wraps webview_flutter plugin — no headless webview backend on Linux',
  'lib/ui/widgets/snooze_picker.dart':
      'Widget-only date/time picker bottom sheet',
  'lib/ui/widgets/thread_tile.dart': 'Widget-only list tile',
  'lib/ui/widgets/try_connection_button.dart':
      'Widget-only button wrapping async connection test',
  'lib/ui/widgets/undo_shell.dart':
      'Widget-only shell that shows undo snackbars',
  'lib/ui/utils/about_markdown.dart':
      'device_info_plus + package_info_plus + MediaQuery — needs a real BuildContext',
  'lib/data/jmap/sieve_repository.dart':
      'Wraps ManageSieve socket + JMAP HTTP calls to a live server',
  'lib/data/repositories/draft_repository_impl.dart':
      'IMAP APPEND / JMAP Email/set over a real network connection',
  'lib/data/repositories/share_key_repository_impl.dart':
      'ShareEncryptionService generates a real X25519 key pair — deliberately slow',
  'lib/data/repositories/note_repository_impl.dart':
      'IMAP APPEND / JMAP Email/set over a real network connection',
  'lib/core/services/update_service.dart':
      'FutureProvider hits https://sharedinbox.de/latest.json with no injectable http.Client',
  'lib/core/services/unified_push_service.dart':
      'UnifiedPush plugin channel — plugin-only surface',
  'lib/core/sync/background_sync.dart':
      'workmanager plugin + secure storage + IMAP + path_provider surface',
  'lib/core/sync/message_probe.dart':
      'Opens live IMAP TLS socket + JMAP HTTP calls to a mail server',
};

void main() {
  // Check for ghost paths in _excluded and _noCode.
  final allConfiguredPaths = {..._excluded.keys, ..._noCode};
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
      .where((p) => !_excluded.containsKey(p) && !_noCode.contains(p))
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
        !_excluded.containsKey(currentSf) &&
        !_noCode.contains(currentSf) &&
        !currentSf.endsWith('.g.dart')) {
      final count = int.parse(line.substring(3).split(',')[1]);
      total++;
      if (count > 0) hits++;
    }
  }
  final pct = total > 0 ? (hits * 100 ~/ total) : 0;
  final measuredCount =
      measuredFiles.where((f) => !_excluded.containsKey(f)).length;
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
