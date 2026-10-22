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
      final db = await openTestDatabaseWithAccounts(const ['acc-1']);
      final repo = UndoRepositoryImpl(db);

      expect(await repo.getHistory(), isEmpty);

      await db.close();
    });

    test('saveAction round-trips through getHistory', () async {
      final db = await openTestDatabaseWithAccounts(const ['acc-1']);
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

    test('saveAction keeps undoneAt', () async {
      final db = await openTestDatabaseWithAccounts(const ['acc-1']);
      final repo = UndoRepositoryImpl(db);

      final undoneAt = DateTime.utc(2024, 1, 1, 12, 30);
      await repo.saveAction(
        _action('a', timestamp: DateTime.utc(2024)).withUndoneAt(undoneAt),
      );
      await repo.saveAction(_action('b', timestamp: DateTime.utc(2024, 2)));

      final history = await repo.getHistory();
      expect(history.first.undoneAt, undoneAt);
      expect(history.last.undoneAt, isNull);

      await db.close();
    });

    test('setUndoneAt sets and clears the mark, keeping the row', () async {
      final db = await openTestDatabaseWithAccounts(const ['acc-1']);
      final repo = UndoRepositoryImpl(db);
      await repo.saveAction(_action('a', timestamp: DateTime.utc(2024)));

      final undoneAt = DateTime.utc(2024, 1, 2);
      await repo.setUndoneAt('a', undoneAt);
      var stored = (await repo.getHistory()).single;
      expect(stored.undoneAt, undoneAt);
      expect(stored.emailIds, ['e1']);
      expect(stored.destinationMailboxPath, 'Trash');

      await repo.setUndoneAt('a', null);
      stored = (await repo.getHistory()).single;
      expect(stored.undoneAt, isNull);

      await db.close();
    });

    test('setUndoneAt on a missing row inserts nothing', () async {
      final db = await openTestDatabaseWithAccounts(const ['acc-1']);
      final repo = UndoRepositoryImpl(db);

      await repo.setUndoneAt('gone', DateTime.utc(2024));

      expect(await repo.getHistory(), isEmpty);
      await db.close();
    });

    test('getHistory returns oldest-first within the requested window',
        () async {
      final db = await openTestDatabaseWithAccounts(const ['acc-1']);
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
      final db = await openTestDatabaseWithAccounts(const ['acc-1']);
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
      final db = await openTestDatabaseWithAccounts(const ['acc-1']);
      final repo = UndoRepositoryImpl(db);

      await repo.saveAction(_action('a', timestamp: DateTime.utc(2024)));
      await repo.saveAction(_action('b', timestamp: DateTime.utc(2024, 2)));

      await repo.deleteAction('a');

      final history = await repo.getHistory();
      expect(history.map((a) => a.id).toList(), ['b']);

      await db.close();
    });

    test('pushAndTrim drops rows beyond maxHistory (oldest first)', () async {
      final db = await openTestDatabaseWithAccounts(const ['acc-1']);
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

    test('getHistory honours a larger limit and returns the newest window',
        () async {
      final db = await openTestDatabaseWithAccounts(const ['acc-1']);
      final repo = UndoRepositoryImpl(db);

      for (var i = 0; i < 30; i++) {
        await repo.saveAction(
          _action('a$i', timestamp: DateTime.utc(2024, 1, i + 1)),
        );
      }

      // A limit above the default 10 loads more of the persisted history.
      final history = await repo.getHistory(limit: 25);
      expect(history, hasLength(25));
      // Oldest-first within the newest-25 window (a5..a29), a0..a4 excluded.
      expect(history.first.id, 'a5');
      expect(history.last.id, 'a29');

      await db.close();
    });

    test('clearHistory empties the table', () async {
      final db = await openTestDatabaseWithAccounts(const ['acc-1']);
      final repo = UndoRepositoryImpl(db);

      await repo.saveAction(_action('a', timestamp: DateTime.utc(2024)));
      await repo.saveAction(_action('b', timestamp: DateTime.utc(2024, 2)));

      await repo.clearHistory();

      expect(await repo.getHistory(), isEmpty);

      await db.close();
    });
  });
}
