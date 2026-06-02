import 'package:drift/drift.dart';
import 'package:sharedinbox/core/repositories/search_history_repository.dart';
import 'package:sharedinbox/data/db/database.dart';

class SearchHistoryRepositoryImpl implements SearchHistoryRepository {
  SearchHistoryRepositoryImpl(this._db);
  final AppDatabase _db;

  static const _maxEntries = 10;

  @override
  Future<List<String>> getRecentSearches() async {
    final rows =
        await (_db.select(_db.searchHistoryEntries)
              ..orderBy([(t) => OrderingTerm.desc(t.searchedAt)])
              ..limit(_maxEntries))
            .get();
    return rows.map((r) => r.query).toList();
  }

  @override
  Future<void> saveSearch(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;

    await _db.transaction(() async {
      // Remove existing entry for same query (deduplication).
      await (_db.delete(
        _db.searchHistoryEntries,
      )..where((t) => t.query.equals(trimmed))).go();

      await _db
          .into(_db.searchHistoryEntries)
          .insert(
            SearchHistoryEntriesCompanion.insert(
              query: trimmed,
              searchedAt: DateTime.now(),
            ),
          );

      // Prune to the most recent _maxEntries.
      final keepIds =
          await (_db.select(_db.searchHistoryEntries)
                ..orderBy([(t) => OrderingTerm.desc(t.searchedAt)])
                ..limit(_maxEntries))
              .map((r) => r.id)
              .get();

      if (keepIds.isNotEmpty) {
        await (_db.delete(
          _db.searchHistoryEntries,
        )..where((t) => t.id.isNotIn(keepIds))).go();
      }
    });
  }

  @override
  Future<void> clearHistory() async {
    await _db.delete(_db.searchHistoryEntries).go();
  }
}
