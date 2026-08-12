import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sharedinbox/core/models/sieve_script.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/data/db/local_sieve_repository.dart';
import 'package:sharedinbox/data/jmap/sieve_repository.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/sieve_scripts_screen.dart';

import '../unit/db_test_helper.dart';
import 'helpers.dart';

class _RecordingAppLogRepository extends NoOpAppLogRepository {
  final List<Map<String, Object?>> inserts = [];

  @override
  Future<int?> insert({
    required AppLogLevel level,
    required String event,
    required String message,
    String? dataJson,
    String? screen,
    String? accountId,
    String? mailboxPath,
    String? emailId,
    int? syncLogId,
    DateTime? createdAt,
  }) async {
    inserts.add({
      'level': level,
      'event': event,
      'message': message,
      'accountId': accountId,
      'dataJson': dataJson,
    });
    return inserts.length;
  }
}

class _FakeSieveRepository extends SieveRepository {
  _FakeSieveRepository({this.error, List<SieveScript>? initialScripts})
      : _scripts = List.of(initialScripts ?? const []),
        super(FakeAccountRepository(), http.Client());

  final Object? error;
  final List<SieveScript> _scripts;

  /// If set, `activateScript` throws this instead of updating state.
  Object? activateError;

  /// If set, `activateScript` succeeds (no throw) but leaves the script
  /// marked inactive — mimics a JMAP server that silently ignores activate.
  bool activateNoOp = false;

  int activateCalls = 0;
  int deactivateCalls = 0;

  @override
  Future<List<SieveScript>> listScripts(String accountId) async {
    if (error != null) throw error!;
    return List.of(_scripts);
  }

  @override
  Future<void> activateScript(String accountId, String scriptId) async {
    activateCalls++;
    if (activateError != null) throw activateError!;
    if (activateNoOp) return;
    for (var i = 0; i < _scripts.length; i++) {
      final s = _scripts[i];
      _scripts[i] = SieveScript(
        id: s.id,
        name: s.name,
        blobId: s.blobId,
        isActive: s.id == scriptId,
      );
    }
  }

  @override
  Future<void> deactivateScript(String accountId) async {
    deactivateCalls++;
    for (var i = 0; i < _scripts.length; i++) {
      final s = _scripts[i];
      _scripts[i] = SieveScript(
        id: s.id,
        name: s.name,
        blobId: s.blobId,
        isActive: false,
      );
    }
  }
}

SieveScript _script(String id, {bool isActive = false, String? name}) =>
    SieveScript(
      id: id,
      name: name ?? id,
      blobId: id,
      isActive: isActive,
    );

void main() {
  configureSqliteForTests();

  testWidgets('Remote email filters page shows correct title and banner', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sieveRepositoryProvider.overrideWith((ref) => _FakeSieveRepository()),
        ],
        child: const MaterialApp(home: SieveScriptsScreen(accountId: 'acc-1')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Remote email filters'), findsOneWidget);
    expect(
      find.textContaining('Remote email filters run Sieve scripts'),
      findsOneWidget,
    );
    expect(find.textContaining('Local email filters'), findsOneWidget);
  });

  testWidgets('Remote email filters hides the "+" FAB when listScripts fails', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sieveRepositoryProvider.overrideWith(
            (ref) => _FakeSieveRepository(
              error: const HandshakeException(
                'Handshake error in client',
              ),
            ),
          ),
        ],
        child: const MaterialApp(home: SieveScriptsScreen(accountId: 'acc-1')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('HandshakeException'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Retry'), findsOneWidget);
  });

  testWidgets('Local email filters page shows correct title and banner', (
    tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localSieveRepositoryProvider.overrideWith(
            (ref) => LocalSieveRepository(db),
          ),
        ],
        child: const MaterialApp(
          home: SieveScriptsScreen(accountId: 'acc-1', isLocal: true),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Local email filters'), findsOneWidget);
    expect(
      find.textContaining('Local email filters run Sieve scripts'),
      findsOneWidget,
    );
    expect(find.textContaining('Remote email filters'), findsOneWidget);
  });

  testWidgets('shows "Inactive" subtitle for inactive scripts', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sieveRepositoryProvider.overrideWith(
            (ref) => _FakeSieveRepository(
              initialScripts: [_script('s1', name: 'My filter')],
            ),
          ),
        ],
        child: const MaterialApp(home: SieveScriptsScreen(accountId: 'acc-1')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('My filter'), findsOneWidget);
    expect(find.text('Inactive'), findsOneWidget);
    expect(find.text('Active'), findsNothing);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });

  testWidgets('shows "Active" subtitle for active scripts', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sieveRepositoryProvider.overrideWith(
            (ref) => _FakeSieveRepository(
              initialScripts: [_script('s1', name: 'Prod', isActive: true)],
            ),
          ),
        ],
        child: const MaterialApp(home: SieveScriptsScreen(accountId: 'acc-1')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Active'), findsOneWidget);
    expect(find.text('Inactive'), findsNothing);
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
  });

  testWidgets('popup menu shows Set active for inactive script', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sieveRepositoryProvider.overrideWith(
            (ref) => _FakeSieveRepository(
              initialScripts: [_script('s1', name: 'My filter')],
            ),
          ),
        ],
        child: const MaterialApp(home: SieveScriptsScreen(accountId: 'acc-1')),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    expect(find.text('Set active'), findsOneWidget);
    expect(find.text('Set inactive'), findsNothing);
  });

  testWidgets('popup menu shows Set inactive for active script', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sieveRepositoryProvider.overrideWith(
            (ref) => _FakeSieveRepository(
              initialScripts: [_script('s1', name: 'Prod', isActive: true)],
            ),
          ),
        ],
        child: const MaterialApp(home: SieveScriptsScreen(accountId: 'acc-1')),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    expect(find.text('Set inactive'), findsOneWidget);
    expect(find.text('Set active'), findsNothing);
  });

  testWidgets('tapping "Set active" shows a success snackbar', (tester) async {
    final repo = _FakeSieveRepository(
      initialScripts: [_script('s1', name: 'My filter')],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sieveRepositoryProvider.overrideWith((ref) => repo)],
        child: const MaterialApp(home: SieveScriptsScreen(accountId: 'acc-1')),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set active'));
    await tester.pumpAndSettle();

    expect(repo.activateCalls, 1);
    expect(find.text('Activated "My filter"'), findsOneWidget);
    // After activation, tile now reads Active.
    expect(find.text('Active'), findsOneWidget);
    expect(find.text('Inactive'), findsNothing);
  });

  testWidgets('tapping "Set inactive" shows a success snackbar', (
    tester,
  ) async {
    final repo = _FakeSieveRepository(
      initialScripts: [_script('s1', name: 'Prod', isActive: true)],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sieveRepositoryProvider.overrideWith((ref) => repo)],
        child: const MaterialApp(home: SieveScriptsScreen(accountId: 'acc-1')),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set inactive'));
    await tester.pumpAndSettle();

    expect(repo.deactivateCalls, 1);
    expect(find.text('Deactivated "Prod"'), findsOneWidget);
    expect(find.text('Inactive'), findsOneWidget);
  });

  testWidgets('activation error surfaces via snackbar, no success message', (
    tester,
  ) async {
    final repo = _FakeSieveRepository(
      initialScripts: [_script('s1', name: 'My filter')],
    )..activateError = Exception('server rejected');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sieveRepositoryProvider.overrideWith((ref) => repo)],
        child: const MaterialApp(home: SieveScriptsScreen(accountId: 'acc-1')),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set active'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Failed to activate'),
      findsOneWidget,
    );
    expect(find.textContaining('Activated'), findsNothing);
  });

  testWidgets('activation failure writes an app-log entry (regression #320)', (
    tester,
  ) async {
    final repo = _FakeSieveRepository(
      initialScripts: [_script('s1', name: 'My filter')],
    )..activateError = Exception('server rejected');
    final logRepo = _RecordingAppLogRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sieveRepositoryProvider.overrideWith((ref) => repo),
          appLogRepositoryProvider.overrideWith((ref) => logRepo),
        ],
        child: const MaterialApp(home: SieveScriptsScreen(accountId: 'acc-1')),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set active'));
    await tester.pumpAndSettle();

    final activateLogs = logRepo.inserts.where(
      (row) => row['event'] == 'sieve.activate_failed',
    );
    expect(activateLogs, hasLength(1));
    final row = activateLogs.single;
    expect(row['level'], AppLogLevel.error);
    expect(row['accountId'], 'acc-1');
    expect(row['message'], 'Failed to activate sieve script');
    expect(row['dataJson'], contains('server rejected'));
    expect(row['dataJson'], contains('"scriptId":"s1"'));
  });

  testWidgets(
    'silent no-op activation warns that the change may not have taken effect',
    (tester) async {
      final repo = _FakeSieveRepository(
        initialScripts: [_script('s1', name: 'My filter')],
      )..activateNoOp = true;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sieveRepositoryProvider.overrideWith((ref) => repo)],
          child: const MaterialApp(
            home: SieveScriptsScreen(accountId: 'acc-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set active'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('may not have taken effect'),
        findsOneWidget,
      );
      // Tile still reflects inactive state so user sees the truth.
      expect(find.text('Inactive'), findsOneWidget);
    },
  );
}
