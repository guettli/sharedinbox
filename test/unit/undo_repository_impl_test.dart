import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/data/repositories/undo_repository_impl.dart';

import 'db_test_helper.dart';

UndoAction _action(
  String id, {
  UndoType type = UndoType.delete,
  DateTime? timestamp,
}) =>
    UndoAction(
      id: id,
      accountId: 'acc-1',
      type: type,
      emailIds: const ['e1'],
      sourceMailboxPath: 'INBOX',
      destinationMailboxPath: type == UndoType.delete ? 'Trash' : 'Archive',
      timestamp: timestamp,
    );

void main() {
  configureSqliteForTests();

  group('UndoRepositoryImpl', () {
    test('getHistory returns an empty list when no rows exist', () async {
      final db = openTestDatabase();
      final repo = UndoRepositoryImpl(db);

      expect(await repo.getHistory(), isEmpty);

      await db.close();
    });

    test('saveAction round-trips through getHistory', () async {
      final db = openTestDatabase();
      final repo = UndoRepositoryImpl(db);

      final action = _action('a', timestamp: DateTime.utc(2024));
      await repo.saveAction(action);

      final history = await repo.getHistory();
      expect(history, hasLength(1));
      expect(history.first.id, 'a');
      expect(history.first.type, UndoType.delete);
      expect(history.first.sourceMailboxPath, 'INBOX');

      await db.close();
    });

    test('getHistory returns oldest-first within the requested window',
        () async {
      final db = openTestDatabase();
      final repo = UndoRepositoryImpl(db);

      await repo.saveAction(_action('old', timestamp: DateTime.utc(2024)));
      await repo.saveAction(_action('mid', timestamp: DateTime.utc(2024, 6)));
      await repo.saveAction(_action('new', timestamp: DateTime.utc(2024, 12)));

      final history = await repo.getHistory();
      // Oldest-first invariant matches the in-memory UndoService list order.
      expect(history.map((a) => a.id).toList(), ['old', 'mid', 'new']);

      await db.close();
    });

    test('saveAction with existing id replaces the row', () async {
      final db = openTestDatabase();
      final repo = UndoRepositoryImpl(db);

      await repo.saveAction(_action('a', timestamp: DateTime.utc(2024)));
      await repo.saveAction(
        _action('a', type: UndoType.move, timestamp: DateTime.utc(2024, 2)),
      );

      final history = await repo.getHistory();
      expect(history, hasLength(1));
      expect(history.first.type, UndoType.move);

      await db.close();
    });

    test('deleteAction removes only the matching row', () async {
      final db = openTestDatabase();
      final repo = UndoRepositoryImpl(db);

      await repo.saveAction(_action('a', timestamp: DateTime.utc(2024)));
      await repo.saveAction(_action('b', timestamp: DateTime.utc(2024, 2)));

      await repo.deleteAction('a');

      final history = await repo.getHistory();
      expect(history.map((a) => a.id).toList(), ['b']);

      await db.close();
    });

    test('pushAndTrim drops rows beyond maxHistory (oldest first)', () async {
      final db = openTestDatabase();
      final repo = UndoRepositoryImpl(db);

      for (var i = 0; i < 5; i++) {
        await repo.pushAndTrim(
          _action('a$i', timestamp: DateTime.utc(2024, 1, i + 1)),
          maxHistory: 3,
        );
      }

      final history = await repo.getHistory();
      // Only the 3 newest survive; older 'a0'/'a1' were trimmed.
      expect(history.map((a) => a.id).toList(), ['a2', 'a3', 'a4']);

      await db.close();
    });

    test('clearHistory empties the table', () async {
      final db = openTestDatabase();
      final repo = UndoRepositoryImpl(db);

      await repo.saveAction(_action('a', timestamp: DateTime.utc(2024)));
      await repo.saveAction(_action('b', timestamp: DateTime.utc(2024, 2)));

      await repo.clearHistory();

      expect(await repo.getHistory(), isEmpty);

      await db.close();
    });
  });
}
