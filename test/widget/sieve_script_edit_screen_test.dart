import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/data/db/local_sieve_repository.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/sieve_script_edit_screen.dart';

import '../unit/db_test_helper.dart';
import 'helpers.dart';

const _script = '''
require ["fileinto"];
if header :contains "subject" "pizza" {
    fileinto "Junk";
}''';

/// Pumps until [finder] shows. The real database answers outside the fake
/// test clock, and the save spinner keeps pumpAndSettle from settling.
Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 50 && finder.evaluate().isEmpty; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
}

void main() {
  configureSqliteForTests();

  /// Creates a local filter whose preview matches nothing (the fake email
  /// repository counts 0) and returns the repository it was saved to.
  Future<LocalSieveRepository> saveNewFilter(WidgetTester tester) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final repo = LocalSieveRepository(db);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localSieveRepositoryProvider.overrideWith((ref) => repo),
          emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
          appLogRepositoryProvider
              .overrideWith((ref) => const NoOpAppLogRepository()),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SieveScriptEditScreen(
                    accountId: 'acc-1',
                    isLocal: true,
                    initialName: 'Pizza to Junk',
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Script'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Script'), _script);
    await tester.tap(find.byTooltip('Save'));
    await _pumpUntil(tester, find.text('No matching messages'));
    return repo;
  }

  testWidgets('a new filter that matches nothing yet can be activated', (
    tester,
  ) async {
    final repo = await saveNewFilter(tester);

    expect(find.text('No matching messages'), findsOneWidget);
    await tester.tap(find.text('Activate'));
    await _pumpUntil(tester, find.text('open'));

    final scripts = (await tester.runAsync(() => repo.listScripts('acc-1')))!;
    expect(scripts.single.name, 'Pizza to Junk');
    expect(scripts.single.isActive, isTrue);
  });

  testWidgets('"Leave inactive" keeps the new filter inactive', (
    tester,
  ) async {
    final repo = await saveNewFilter(tester);

    await tester.tap(find.text('Leave inactive'));
    await _pumpUntil(tester, find.text('open'));

    final scripts = (await tester.runAsync(() => repo.listScripts('acc-1')))!;
    expect(scripts.single.isActive, isFalse);
  });
}
