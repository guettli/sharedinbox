import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sharedinbox/core/models/sieve_script.dart';
import 'package:sharedinbox/data/db/local_sieve_repository.dart';
import 'package:sharedinbox/data/jmap/sieve_repository.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/sieve_scripts_screen.dart';

import '../unit/db_test_helper.dart';
import 'helpers.dart';

class _FakeSieveRepository extends SieveRepository {
  _FakeSieveRepository() : super(FakeAccountRepository(), http.Client());

  @override
  Future<List<SieveScript>> listScripts(String accountId) async => [];
}

void main() {
  configureSqliteForTests();

  testWidgets('Remote Filters page shows correct title and banner', (
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

    expect(find.text('Remote Filters'), findsOneWidget);
    expect(
      find.textContaining('Remote Filters run Sieve scripts'),
      findsOneWidget,
    );
    expect(find.textContaining('Local Filters'), findsOneWidget);
  });

  testWidgets('Local Filters page shows correct title and banner', (
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

    expect(find.text('Local Filters'), findsOneWidget);
    expect(
      find.textContaining('Local Filters run Sieve scripts'),
      findsOneWidget,
    );
    expect(find.textContaining('Remote Filters'), findsOneWidget);
  });
}
