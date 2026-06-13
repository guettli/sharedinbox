import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/core/repositories/undo_repository.dart';
import 'package:sharedinbox/data/db/database.dart';

class UndoRepositoryImpl implements UndoRepository {
  UndoRepositoryImpl(this._db);

  final AppDatabase _db;

  @override
  Future<void> saveAction(UndoAction action) async {
    await _db.into(_db.undoActions).insert(
          UndoActionsCompanion.insert(
            id: action.id,
            accountId: action.accountId,
            dataJson: jsonEncode(action.toJson()),
            createdAt: action.timestamp,
          ),
          mode: InsertMode.insertOrReplace,
        );
  }

  @override
  Future<void> deleteAction(String id) async {
    await (_db.delete(_db.undoActions)..where((t) => t.id.equals(id))).go();
  }

  @override
  Future<List<UndoAction>> getHistory({int limit = 10}) async {
    // Fetch the newest `limit` rows but return them in chronological order
    // (oldest first) to match the in-memory list invariant in UndoService,
    // where pushAction appends newer actions to the end.
    final rows = await (_db.select(_db.undoActions)
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
          ..limit(limit))
        .get();
    return rows.reversed.map((row) {
      return UndoAction.fromJson(
        jsonDecode(row.dataJson) as Map<String, dynamic>,
      );
    }).toList();
  }

  @override
  Future<void> clearHistory() async {
    await _db.delete(_db.undoActions).go();
  }

  @override
  Future<void> pushAndTrim(
    UndoAction action, {
    required int maxHistory,
  }) async {
    await _db.transaction(() async {
      await saveAction(action);
      await trim(maxHistory: maxHistory);
    });
  }

  @override
  Future<void> trim({required int maxHistory}) async {
    await _db.customStatement(
      'DELETE FROM undo_actions WHERE id NOT IN ('
      'SELECT id FROM undo_actions ORDER BY created_at DESC LIMIT ?'
      ')',
      [maxHistory],
    );
  }
}
