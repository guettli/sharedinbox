abstract interface class SearchHistoryRepository {
  Future<List<String>> getRecentSearches();
  Future<void> saveSearch(String query);
  Future<void> deleteSearch(String query);
  Future<void> clearHistory();
}
