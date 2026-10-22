import 'package:sharedinbox/core/models/undo_action.dart';

abstract class UndoRepository {
  Future<void> saveAction(UndoAction action);
  Future<void> deleteAction(String id);

  /// Sets (or clears) [UndoAction.undoneAt] on the stored row [id], keeping
  /// the rest of the row as it is now (a flush may have re-keyed its email
  /// ids meanwhile). Does nothing when the row no longer exists.
  Future<void> setUndoneAt(String id, DateTime? undoneAt);
  Future<List<UndoAction>> getHistory({int limit = 10});
  Future<void> clearHistory();

  /// Inserts [action] and trims the table down to the newest [maxHistory]
  /// rows in a single transaction so a crash mid-push cannot leave the log
  /// missing both the trimmed entry and the new entry.
  Future<void> pushAndTrim(UndoAction action, {required int maxHistory});

  /// Deletes rows beyond the newest [maxHistory] entries by `createdAt`.
  /// Safe to call at startup to reconcile the DB with the in-memory cap.
  Future<void> trim({required int maxHistory});
}
