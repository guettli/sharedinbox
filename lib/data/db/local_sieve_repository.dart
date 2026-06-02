import 'package:drift/drift.dart';

import 'package:sharedinbox/core/models/sieve_script.dart';
import 'package:sharedinbox/data/db/database.dart';

class LocalSieveRepository {
  LocalSieveRepository(this._db);

  final AppDatabase _db;

  Future<List<SieveScript>> listScripts(String accountId) async {
    final rows = await (_db.select(
      _db.localSieveScripts,
    )..where((t) => t.accountId.equals(accountId)))
        .get();
    return rows
        .map(
          (r) => SieveScript(
            id: r.id.toString(),
            name: r.name,
            blobId: r.id.toString(),
            isActive: r.isActive,
          ),
        )
        .toList();
  }

  Future<String> getScriptContent(String accountId, String blobId) async {
    final rowId = int.parse(blobId);
    final row = await (_db.select(
      _db.localSieveScripts,
    )..where((t) => t.id.equals(rowId) & t.accountId.equals(accountId)))
        .getSingleOrNull();
    if (row == null) throw Exception('Local script not found: $blobId');
    return row.content;
  }

  Future<SieveScript> saveScript(
    String accountId, {
    String? id,
    required String name,
    required String content,
  }) async {
    if (id != null) {
      final rowId = int.parse(id);
      await (_db.update(_db.localSieveScripts)
            ..where((t) => t.id.equals(rowId) & t.accountId.equals(accountId)))
          .write(
        LocalSieveScriptsCompanion(
          name: Value(name),
          content: Value(content),
        ),
      );
      final updated = await (_db.select(_db.localSieveScripts)
            ..where(
              (t) => t.id.equals(rowId) & t.accountId.equals(accountId),
            ))
          .getSingleOrNull();
      return SieveScript(
        id: id,
        name: name,
        blobId: id,
        isActive: updated?.isActive ?? false,
      );
    }
    final rowId = await _db.into(_db.localSieveScripts).insert(
          LocalSieveScriptsCompanion.insert(
            accountId: accountId,
            name: name,
            content: Value(content),
          ),
        );
    final idStr = rowId.toString();
    return SieveScript(id: idStr, name: name, blobId: idStr, isActive: false);
  }

  Future<void> deleteScript(String accountId, String scriptId) async {
    final rowId = int.parse(scriptId);
    await (_db.delete(
      _db.localSieveScripts,
    )..where((t) => t.id.equals(rowId) & t.accountId.equals(accountId)))
        .go();
  }

  Future<void> activateScript(String accountId, String scriptId) async {
    await _db.transaction(() async {
      await (_db.update(_db.localSieveScripts)
            ..where((t) => t.accountId.equals(accountId)))
          .write(const LocalSieveScriptsCompanion(isActive: Value(false)));
      final rowId = int.parse(scriptId);
      await (_db.update(_db.localSieveScripts)
            ..where((t) => t.id.equals(rowId) & t.accountId.equals(accountId)))
          .write(const LocalSieveScriptsCompanion(isActive: Value(true)));
    });
  }
}
