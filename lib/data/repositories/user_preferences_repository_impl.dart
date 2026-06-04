import 'package:drift/drift.dart';
import 'package:sharedinbox/core/models/user_preferences.dart' as pref;
import 'package:sharedinbox/core/repositories/user_preferences_repository.dart';
import 'package:sharedinbox/data/db/database.dart';

class UserPreferencesRepositoryImpl implements UserPreferencesRepository {
  UserPreferencesRepositoryImpl(this._db);

  final AppDatabase _db;
  static const _rowId = 1;

  @override
  Stream<pref.UserPreferences> observePreferences() {
    return (_db.select(
      _db.userPreferences,
    )..where((t) => t.id.equals(_rowId)))
        .watchSingleOrNull()
        .map(_rowToModel);
  }

  @override
  Future<void> updateMenuPosition(pref.MenuPosition position) async {
    await _db.into(_db.userPreferences).insertOnConflictUpdate(
          UserPreferencesCompanion(
            id: const Value(_rowId),
            menuPosition: Value(position.name),
          ),
        );
  }

  @override
  Future<void> updateMailViewButtonPosition(pref.MenuPosition position) async {
    await _db.into(_db.userPreferences).insertOnConflictUpdate(
          UserPreferencesCompanion(
            id: const Value(_rowId),
            mailViewButtonPosition: Value(position.name),
          ),
        );
  }

  @override
  Future<void> updateAfterMailViewAction(
    pref.AfterMailViewAction action,
  ) async {
    await _db.into(_db.userPreferences).insertOnConflictUpdate(
          UserPreferencesCompanion(
            id: const Value(_rowId),
            afterMailViewAction: Value(action.name),
          ),
        );
  }

  @override
  Future<void> updatePrefetchMode(pref.PrefetchMode mode) async {
    await _db.into(_db.userPreferences).insertOnConflictUpdate(
          UserPreferencesCompanion(
            id: const Value(_rowId),
            prefetchMode: Value(mode.name),
          ),
        );
  }

  @override
  Future<void> updateBodyCacheLimitMb(int mb) async {
    await _db.into(_db.userPreferences).insertOnConflictUpdate(
          UserPreferencesCompanion(
            id: const Value(_rowId),
            bodyCacheLimitMb: Value(mb),
          ),
        );
  }

  @override
  Stream<List<String>> observeTrustedImageSenders() {
    return (_db.select(_db.imageTrustedSenders)
          ..orderBy([(t) => OrderingTerm.desc(t.addedAt)]))
        .watch()
        .map((rows) => rows.map((r) => r.senderEmail).toList());
  }

  @override
  Future<void> addTrustedImageSender(String senderEmail) async {
    await _db.into(_db.imageTrustedSenders).insertOnConflictUpdate(
          ImageTrustedSendersCompanion(
            senderEmail: Value(senderEmail.toLowerCase()),
            addedAt: Value(DateTime.now()),
          ),
        );
  }

  @override
  Future<void> removeTrustedImageSender(String senderEmail) async {
    await (_db.delete(_db.imageTrustedSenders)
          ..where((t) => t.senderEmail.equals(senderEmail.toLowerCase())))
        .go();
  }

  static pref.UserPreferences _rowToModel(UserPreferencesRow? row) {
    if (row == null) return const pref.UserPreferences();
    return pref.UserPreferences(
      menuPosition: pref.MenuPosition.values.firstWhere(
        (e) => e.name == row.menuPosition,
        orElse: () => pref.MenuPosition.bottom,
      ),
      mailViewButtonPosition: pref.MenuPosition.values.firstWhere(
        (e) => e.name == row.mailViewButtonPosition,
        orElse: () => pref.MenuPosition.bottom,
      ),
      afterMailViewAction: pref.AfterMailViewAction.values.firstWhere(
        (e) => e.name == row.afterMailViewAction,
        orElse: () => pref.AfterMailViewAction.nextMessage,
      ),
      prefetchMode: pref.PrefetchMode.fromString(row.prefetchMode),
      bodyCacheLimitMb: row.bodyCacheLimitMb,
    );
  }
}
