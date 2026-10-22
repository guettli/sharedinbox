import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/user_preferences.dart';
import 'package:sharedinbox/data/db/database.dart'
    show UserPreferencesCompanion;
import 'package:sharedinbox/data/repositories/user_preferences_repository_impl.dart';

import 'db_test_helper.dart';

void main() {
  configureSqliteForTests();

  group('UserPreferencesRepositoryImpl', () {
    test('observePreferences yields defaults when no row exists', () async {
      final db = openTestDatabase();
      final repo = UserPreferencesRepositoryImpl(db);

      final prefs = await repo.observePreferences().first;
      expect(prefs.menuPosition, MenuPosition.bottom);
      expect(prefs.afterMailViewAction, AfterMailViewAction.nextMessage);
      expect(prefs.prefetchMode, PrefetchMode.wifiOnly);

      await db.close();
    });

    test('updateMenuPosition round-trips through observePreferences', () async {
      final db = openTestDatabase();
      final repo = UserPreferencesRepositoryImpl(db);

      await repo.updateMenuPosition(MenuPosition.top);
      final prefs = await repo.observePreferences().first;
      expect(prefs.menuPosition, MenuPosition.top);

      await db.close();
    });

    test('legacy mailViewButtonPosition value in the DB is ignored', () async {
      // The column is unused since #1093 but kept to avoid a migration.
      // Rows written by older versions must still load.
      final db = openTestDatabase();
      final repo = UserPreferencesRepositoryImpl(db);

      await db.into(db.userPreferences).insert(
            const UserPreferencesCompanion(
              id: Value(1),
              menuPosition: Value('top'),
              mailViewButtonPosition: Value('top'),
            ),
          );
      final prefs = await repo.observePreferences().first;
      expect(prefs.menuPosition, MenuPosition.top);

      await db.close();
    });

    test('updateAfterMailViewAction round-trips', () async {
      final db = openTestDatabase();
      final repo = UserPreferencesRepositoryImpl(db);

      await repo.updateAfterMailViewAction(AfterMailViewAction.showMailbox);
      final prefs = await repo.observePreferences().first;
      expect(prefs.afterMailViewAction, AfterMailViewAction.showMailbox);

      await db.close();
    });

    test('updatePrefetchMode + updateBodyCacheLimitMb round-trip', () async {
      final db = openTestDatabase();
      final repo = UserPreferencesRepositoryImpl(db);

      await repo.updatePrefetchMode(PrefetchMode.always);
      await repo.updateBodyCacheLimitMb(250);
      final prefs = await repo.observePreferences().first;
      expect(prefs.prefetchMode, PrefetchMode.always);
      expect(prefs.bodyCacheLimitMb, 250);

      await db.close();
    });

    test('trusted image senders: add, observe, remove, lowercase-normalize',
        () async {
      final db = openTestDatabase();
      final repo = UserPreferencesRepositoryImpl(db);

      expect(await repo.observeTrustedImageSenders().first, isEmpty);

      await repo.addTrustedImageSender('Alice@Example.com');
      await repo.addTrustedImageSender('bob@example.com');

      final senders = await repo.observeTrustedImageSenders().first;
      expect(senders.toSet(), {'alice@example.com', 'bob@example.com'});

      await repo.removeTrustedImageSender('ALICE@example.com');
      expect(
        await repo.observeTrustedImageSenders().first,
        ['bob@example.com'],
      );

      await db.close();
    });

    test('adding the same trusted sender twice is a no-op', () async {
      final db = openTestDatabase();
      final repo = UserPreferencesRepositoryImpl(db);

      await repo.addTrustedImageSender('alice@example.com');
      await repo.addTrustedImageSender('alice@example.com');

      expect(
        await repo.observeTrustedImageSenders().first,
        ['alice@example.com'],
      );

      await db.close();
    });
  });
}
