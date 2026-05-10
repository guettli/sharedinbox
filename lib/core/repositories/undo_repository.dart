import 'package:sharedinbox/core/models/undo_action.dart';

abstract class UndoRepository {
  Future<void> saveAction(UndoAction action);
  Future<void> deleteAction(String id);
  Future<List<UndoAction>> getHistory({int limit = 10});
  Future<void> clearHistory();
}
