import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/models/sieve_script.dart';
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

/// Counts [matches] inbox mails for every filter preview.
class _MatchingEmailRepository extends FakeEmailRepository {
  _MatchingEmailRepository(this.matches);

  final int matches;

  @override
  Future<int> previewSieveRuleMatches(String accountId, String content) async =>
      matches;
}

/// Pumps until [finder] shows. The real database answers outside the fake
/// test clock, and the save spinner keeps pumpAndSettle from settling.
Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 250; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
  fail('Timed out waiting for $finder');
}

void main() {
  configureSqliteForTests();

  /// Creates a new local filter whose preview matches [matches] inbox mails
  /// and returns the repository it was saved to. [existing] is saved first,
  /// as the active filter.
  Future<LocalSieveRepository> saveNewFilter(
    WidgetTester tester, {
    int matches = 0,
    String? existing,
  }) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final repo = LocalSieveRepository(db);
    if (existing != null) {
      await tester.runAsync(() async {
        final s = await repo.saveScript(
          'acc-1',
          name: existing,
          content: 'keep;',
        );
        await repo.activateScript('acc-1', s.id);
      });
    }
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localSieveRepositoryProvider.overrideWith((ref) => repo),
          emailRepositoryProvider
              .overrideWithValue(_MatchingEmailRepository(matches)),
          appLogRepositoryProvider
              .overrideWith((ref) => const NoOpAppLogRepository()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
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
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Script'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Script'), _script);
    await tester.tap(find.byTooltip('Save'));
    await _pumpUntil(
      tester,
      find.text(matches == 0 ? 'No matching messages' : 'Apply filter now?'),
    );
    return repo;
  }

  Future<List<SieveScript>> scripts(
    WidgetTester tester,
    LocalSieveRepository repo,
  ) async =>
      (await tester.runAsync(() => repo.listScripts('acc-1')))!;

  testWidgets('a new filter that matches nothing yet can be activated', (
    tester,
  ) async {
    final repo = await saveNewFilter(tester, existing: 'Old filter');

    expect(
      find.textContaining('turns off any other active filter'),
      findsOneWidget,
    );
    await tester.tap(find.text('Activate'));
    await _pumpUntil(tester, find.text('Filter activated.'));

    final byName = {for (final s in await scripts(tester, repo)) s.name: s};
    expect(byName['Pizza to Junk']!.isActive, isTrue);
    expect(byName['Old filter']!.isActive, isFalse);
  });

  testWidgets('"Leave inactive" keeps the new filter inactive', (
    tester,
  ) async {
    final repo = await saveNewFilter(tester);

    await tester.tap(find.text('Leave inactive'));
    await _pumpUntil(tester, find.text('open'));

    expect((await scripts(tester, repo)).single.isActive, isFalse);
  });

  testWidgets('a new filter that matches mail can be activated only', (
    tester,
  ) async {
    final repo = await saveNewFilter(tester, matches: 2);

    await tester.tap(find.text('Only activate'));
    await _pumpUntil(tester, find.text('Filter activated.'));

    expect((await scripts(tester, repo)).single.isActive, isTrue);
  });
}
