import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/data/repositories/search_history_repository_impl.dart';

import 'db_test_helper.dart';

void main() {
  configureSqliteForTests();

  group('SearchHistoryRepositoryImpl', () {
    test('getRecentSearches returns empty list when no history', () async {
      final db = openTestDatabase();
      final repo = SearchHistoryRepositoryImpl(db);

      expect(await repo.getRecentSearches(), isEmpty);

      await db.close();
    });

    test('saveSearch persists the query and trims whitespace', () async {
      final db = openTestDatabase();
      final repo = SearchHistoryRepositoryImpl(db);

      await repo.saveSearch('  alpha  ');

      expect(await repo.getRecentSearches(), ['alpha']);

      await db.close();
    });

    test('saveSearch ignores empty or whitespace-only queries', () async {
      final db = openTestDatabase();
      final repo = SearchHistoryRepositoryImpl(db);

      await repo.saveSearch('');
      await repo.saveSearch('   ');

      expect(await repo.getRecentSearches(), isEmpty);

      await db.close();
    });

    test('saveSearch deduplicates: re-saving moves entry to the front',
        () async {
      final db = openTestDatabase();
      final repo = SearchHistoryRepositoryImpl(db);

      await repo.saveSearch('alpha');
      await repo.saveSearch('beta');
      await repo.saveSearch('alpha');

      // alpha was re-saved last, so it should be first.
      expect(await repo.getRecentSearches(), ['alpha', 'beta']);

      await db.close();
    });

    test('saveSearch prunes to the most recent 10 entries', () async {
      final db = openTestDatabase();
      final repo = SearchHistoryRepositoryImpl(db);

      for (var i = 0; i < 12; i++) {
        await repo.saveSearch('query-$i');
      }

      final results = await repo.getRecentSearches();
      expect(results, hasLength(10));
      // Most recent first; oldest two should be dropped.
      expect(results.first, 'query-11');
      expect(results.contains('query-0'), isFalse);
      expect(results.contains('query-1'), isFalse);

      await db.close();
    });

    test('getRecentSearches returns entries ordered by most recent first',
        () async {
      final db = openTestDatabase();
      final repo = SearchHistoryRepositoryImpl(db);

      await repo.saveSearch('first');
      await repo.saveSearch('second');
      await repo.saveSearch('third');

      expect(await repo.getRecentSearches(), ['third', 'second', 'first']);

      await db.close();
    });

    test('deleteSearch removes only the matching entry', () async {
      final db = openTestDatabase();
      final repo = SearchHistoryRepositoryImpl(db);

      await repo.saveSearch('alpha');
      await repo.saveSearch('beta');
      await repo.saveSearch('gamma');

      await repo.deleteSearch('beta');

      expect(await repo.getRecentSearches(), ['gamma', 'alpha']);

      await db.close();
    });

    test('deleteSearch is a no-op for unknown queries', () async {
      final db = openTestDatabase();
      final repo = SearchHistoryRepositoryImpl(db);

      await repo.saveSearch('alpha');
      await repo.deleteSearch('missing');

      expect(await repo.getRecentSearches(), ['alpha']);

      await db.close();
    });

    test('deleteSearch ignores empty input', () async {
      final db = openTestDatabase();
      final repo = SearchHistoryRepositoryImpl(db);

      await repo.saveSearch('alpha');
      await repo.deleteSearch('');
      await repo.deleteSearch('   ');

      expect(await repo.getRecentSearches(), ['alpha']);

      await db.close();
    });

    test('clearHistory empties the table', () async {
      final db = openTestDatabase();
      final repo = SearchHistoryRepositoryImpl(db);

      await repo.saveSearch('alpha');
      await repo.saveSearch('beta');

      await repo.clearHistory();

      expect(await repo.getRecentSearches(), isEmpty);

      await db.close();
    });
  });
}
