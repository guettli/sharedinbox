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
    final rows = await (_db.select(_db.undoActions)
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
          ..limit(limit))
        .get();
    return rows.map((row) {
      return UndoAction.fromJson(
        jsonDecode(row.dataJson) as Map<String, dynamic>,
      );
    }).toList();
  }

  @override
  Future<void> clearHistory() async {
    await _db.delete(_db.undoActions).go();
  }
}
