import 'package:sharedinbox/core/models/undo_action.dart';

abstract class UndoRepository {
  Future<void> saveAction(UndoAction action);
  Future<void> deleteAction(String id);
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
