// Backend tests for MailObjectStoreJmap against a real Stalwart (#1371): the
// scenarios of the IMAP store, over JMAP, plus what only JMAP has.
// Run via: task test-backend

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/mail_object.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/entry_projector.dart';
import 'package:sharedinbox/data/repositories/mail_object_store_base.dart';
import 'package:sharedinbox/data/repositories/mail_object_store_jmap.dart';
import 'package:test/test.dart';

import '../unit/db_test_helper.dart';
import '../unit/recording_app_log_repository.dart';
import 'mail_object_store_scenarios.dart';
import 'stalwart_harness.dart';

MailObjectStoreJmap _store(BackendObjectDevice d) => MailObjectStoreJmap(
      d.db,
      d.accounts,
      d.mailboxes,
      d.storage,
      httpClient: d.httpClient,
      keyLookup: d.keys.keyLookup,
      writeKey: d.keys.writeKey,
      appLogger: d.appLogger,
      onStep: d.step,
      projectors: [EntryProjector(d.db)],
    );

void main() {
  late PoolImapAccount pool;
  late Account account;

  setUpAll(() {
    configureSqliteForTests();
    pool = PoolImapAccount();
    account = pool.user.jmapAccount(id: 'test-jmap', env: pool.env);
  });

  mailObjectStoreScenarios(
    pool: () => pool,
    account: () => account,
    build: _store,
    create: 'import',
    created: 'imported',
  );

  Future<(BackendObjectDevice, RecordingAppLogRepository)> device() async {
    final logs = RecordingAppLogRepository();
    final d = BackendObjectDevice(account, _store, appLogger: AppLogger(logs));
    addTearDown(d.db.close);
    await d.accounts.addAccount(account, pool.user.password);
    return (d, logs);
  }

  test('a lost checkpoint loses nothing and uploads nothing twice', () async {
    final (a, logs) = await device();
    final v1 = await a.putFresh('one');
    await a.sync();
    await (a.db.delete(a.db.syncStates)
          ..where(
            (t) => t.resourceType.isIn([
              for (final f in MailObjectFolder.values)
                mailObjectCheckpointKey(f),
            ]),
          ))
        .go();

    await a.sync();

    await expectOnServerOnce(pool, a, logs, v1.messageId);
  });

  test('a state the server cannot calculate from lists the folder again',
      () async {
    final (a, logs) = await device();
    final v1 = await a.putFresh('one');
    await a.sync();
    final key = mailObjectCheckpointKey(MailObjectFolder.data);
    final stored = (await (a.db.select(a.db.syncStates)
              ..where((t) => t.resourceType.equals(key)))
            .getSingle())
        .state;
    final mailboxId =
        RegExp(r'"mailboxId":"([^"]+)"').firstMatch(stored)!.group(1);
    await (a.db.update(a.db.syncStates)
          ..where((t) => t.resourceType.equals(key)))
        .write(
      SyncStatesCompanion(
        state: Value(
          '{"mailboxId":"$mailboxId","queryState":"zzzz",'
          '"emailState":"zzzz"}',
        ),
      ),
    );

    await a.sync();

    await expectOnServerOnce(pool, a, logs, v1.messageId);
    expect(logs.rows.map((r) => r.event), contains('mos.full_resync'));
  });
}
