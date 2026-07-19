import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/data/db/local_sieve_repository.dart';

import 'db_test_helper.dart';

void main() {
  configureSqliteForTests();

  group('LocalSieveRepository', () {
    test('listScripts returns empty list for new account', () async {
      final db = openTestDatabase();
      final repo = LocalSieveRepository(db);
      final scripts = await repo.listScripts('acc-1');
      expect(scripts, isEmpty);
      await db.close();
    });

    test('saveScript creates and retrieves a script', () async {
      final db = openTestDatabase();
      final repo = LocalSieveRepository(db);
      final saved = await repo.saveScript(
        'acc-1',
        name: 'My filter',
        content: 'require ["fileinto"]; fileinto "Archive";',
      );
      expect(saved.name, 'My filter');
      expect(saved.isActive, false);

      final scripts = await repo.listScripts('acc-1');
      expect(scripts, hasLength(1));
      expect(scripts.first.name, 'My filter');
      expect(scripts.first.isActive, false);

      await db.close();
    });

    test('getScriptContent returns saved content', () async {
      final db = openTestDatabase();
      final repo = LocalSieveRepository(db);
      const content = 'require ["fileinto"]; fileinto "Archive";';
      final saved = await repo.saveScript(
        'acc-1',
        name: 'Test',
        content: content,
      );

      final loaded = await repo.getScriptContent('acc-1', saved.blobId);
      expect(loaded, content);

      await db.close();
    });

    test('saveScript with id updates existing script', () async {
      final db = openTestDatabase();
      final repo = LocalSieveRepository(db);
      final created = await repo.saveScript(
        'acc-1',
        name: 'Old name',
        content: 'stop;',
      );

      await repo.saveScript(
        'acc-1',
        id: created.id,
        name: 'New name',
        content: 'keep;',
      );

      final scripts = await repo.listScripts('acc-1');
      expect(scripts, hasLength(1));
      expect(scripts.first.name, 'New name');

      final content = await repo.getScriptContent('acc-1', created.blobId);
      expect(content, 'keep;');

      await db.close();
    });

    test('deleteScript removes the script', () async {
      final db = openTestDatabase();
      final repo = LocalSieveRepository(db);
      final saved = await repo.saveScript(
        'acc-1',
        name: 'To delete',
        content: 'stop;',
      );

      await repo.deleteScript('acc-1', saved.id);

      final scripts = await repo.listScripts('acc-1');
      expect(scripts, isEmpty);

      await db.close();
    });

    test('activateScript sets one script active, deactivates others', () async {
      final db = openTestDatabase();
      final repo = LocalSieveRepository(db);
      final s1 = await repo.saveScript(
        'acc-1',
        name: 'Script 1',
        content: 'stop;',
      );
      final s2 = await repo.saveScript(
        'acc-1',
        name: 'Script 2',
        content: 'keep;',
      );

      await repo.activateScript('acc-1', s1.id);
      var scripts = await repo.listScripts('acc-1');
      expect(scripts.firstWhere((s) => s.id == s1.id).isActive, true);
      expect(scripts.firstWhere((s) => s.id == s2.id).isActive, false);

      await repo.activateScript('acc-1', s2.id);
      scripts = await repo.listScripts('acc-1');
      expect(scripts.firstWhere((s) => s.id == s1.id).isActive, false);
      expect(scripts.firstWhere((s) => s.id == s2.id).isActive, true);

      await db.close();
    });

    test('deactivateScript clears active flag on all scripts', () async {
      final db = openTestDatabase();
      final repo = LocalSieveRepository(db);
      final s1 = await repo.saveScript(
        'acc-1',
        name: 'Script 1',
        content: 'stop;',
      );
      final s2 = await repo.saveScript(
        'acc-1',
        name: 'Script 2',
        content: 'keep;',
      );
      await repo.activateScript('acc-1', s1.id);

      await repo.deactivateScript('acc-1');

      final scripts = await repo.listScripts('acc-1');
      expect(scripts.firstWhere((s) => s.id == s1.id).isActive, false);
      expect(scripts.firstWhere((s) => s.id == s2.id).isActive, false);

      await db.close();
    });

    test('deactivateScript only touches the given account', () async {
      final db = openTestDatabase();
      final repo = LocalSieveRepository(db);
      final s1 = await repo.saveScript('acc-1', name: 'A', content: 'stop;');
      final s2 = await repo.saveScript('acc-2', name: 'B', content: 'keep;');
      await repo.activateScript('acc-1', s1.id);
      await repo.activateScript('acc-2', s2.id);

      await repo.deactivateScript('acc-1');

      final acc1Scripts = await repo.listScripts('acc-1');
      final acc2Scripts = await repo.listScripts('acc-2');
      expect(acc1Scripts.first.isActive, false);
      expect(acc2Scripts.first.isActive, true);

      await db.close();
    });

    test('scripts are isolated per account', () async {
      final db = openTestDatabase();
      final repo = LocalSieveRepository(db);
      await repo.saveScript('acc-1', name: 'Filter A', content: 'stop;');
      await repo.saveScript('acc-2', name: 'Filter B', content: 'keep;');

      final acc1Scripts = await repo.listScripts('acc-1');
      expect(acc1Scripts, hasLength(1));
      expect(acc1Scripts.first.name, 'Filter A');

      final acc2Scripts = await repo.listScripts('acc-2');
      expect(acc2Scripts, hasLength(1));
      expect(acc2Scripts.first.name, 'Filter B');

      await db.close();
    });
  });
}
