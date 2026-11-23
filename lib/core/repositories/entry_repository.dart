import 'package:sharedinbox/core/models/entry.dart';

/// The entries of the encrypted personal data (ENCRYPTED-OBJECTS.md §6,
/// #1373). Reads come from the local projection; writes go through the
/// encrypted-object store, work offline and are uploaded by its sync.
abstract class EntryRepository {
  /// The entries of [accountId], newest first; [query] filters title and
  /// body (case-insensitive substring).
  Stream<List<Entry>> observeEntries(String accountId, {String query = ''});

  Future<Entry?> entry(String accountId, String itemId);

  /// Throws `NoWriteKeyException` while the account is locked.
  Future<Entry> create(String accountId, {String? title, required String body});

  /// Sets [title] (empty: none) and [body]; every other field is kept. Also
  /// resolves a conflict.
  Future<void> update(
    String accountId,
    String itemId, {
    String? title,
    required String body,
  });

  Future<void> delete(String accountId, String itemId);
}
