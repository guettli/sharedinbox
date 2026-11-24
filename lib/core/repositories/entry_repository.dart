import 'package:sharedinbox/core/models/entry.dart';

/// The entries of the encrypted personal data (ENCRYPTED-OBJECTS.md §6,
/// #1373). Reads come from the local projection; writes go through the
/// encrypted-object store, work offline and are uploaded by its sync.
abstract class EntryRepository {
  /// The entries of [accountId], newest first (by `createdAt`, else by the
  /// last edit); [query] filters title and body (case-insensitive
  /// substring).
  Stream<List<Entry>> observeEntries(String accountId, {String query = ''});

  /// The entries of [accountId] linked to any of [messageIds], oldest
  /// first like the notes of a mail (#1375).
  Stream<List<Entry>> observeEntriesForMessages(
    String accountId,
    Iterable<String> messageIds,
  );

  Future<Entry?> entry(String accountId, String itemId);

  /// Every entry of [accountId], in no particular order (the export,
  /// #1356).
  Future<List<Entry>> allEntries(String accountId);

  /// The todos (entries with a `task`) of [accountIds] that match [filter]
  /// on [today] (local `YYYY-MM-DD`): open and today ones by due date
  /// (none last), priority and newest first; done ones newest first.
  Stream<List<Entry>> observeTodos({
    required Set<String> accountIds,
    required TodoFilter filter,
    required String today,
  });

  /// The journal entries (with a `date`) of [accountId], newest day first,
  /// oldest edit first within a day (#1358).
  Stream<List<Entry>> observeJournal(String accountId);

  /// A [task] makes it a todo, a [date] (`YYYY-MM-DD`) a journal entry;
  /// [links] are the Message-IDs of its mails. Throws `NoWriteKeyException`
  /// while the account is locked.
  Future<Entry> create(
    String accountId, {
    String? title,
    required String body,
    EntryTask? task,
    String? date,
    List<String> links = const [],
  });

  /// Sets [title] (empty: none) and [body], and the `date` when [date] is
  /// given (null: no longer a journal entry); every other field is kept.
  /// Also resolves a conflict.
  Future<void> update(
    String accountId,
    String itemId, {
    String? title,
    required String body,
    Object? date = keepDate,
  });

  /// Sets the `task` (null: no longer a todo): tick, untick, due date.
  /// Every other field is kept.
  Future<void> setTask(String accountId, String itemId, EntryTask? task);

  Future<void> delete(String accountId, String itemId);
}
