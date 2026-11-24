// Backend tests for MailObjectStoreImap against a real Stalwart (#1370):
// two stores on separate databases act as two devices of one account.
// Run via: task test-backend

import 'dart:io';

import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/repositories/entry_projector.dart';
import 'package:sharedinbox/data/repositories/mail_object_store_imap.dart';
import 'package:test/test.dart';

import '../unit/db_test_helper.dart';
import '../unit/recording_app_log_repository.dart';
import 'mail_object_store_scenarios.dart';
import 'stalwart_harness.dart';

MailObjectStoreImap _store(BackendObjectDevice d) => MailObjectStoreImap(
      d.db,
      d.accounts,
      d.mailboxes,
      d.storage,
      imapConnect: (a, u, p) => d.offline
          ? Future.error(const SocketException('offline'))
          : testImapConnect(a, u, p),
      keyLookup: d.keys.keyLookup,
      writeKey: d.keys.writeKey,
      appLogger: d.appLogger,
      onStep: d.step,
      projectors: [EntryProjector(d.db)],
    );

void main() {
  late PoolImapAccount pool;

  setUpAll(() {
    configureSqliteForTests();
    pool = PoolImapAccount();
  });

  mailObjectStoreScenarios(
    pool: () => pool,
    account: () => pool.account,
    build: _store,
    create: 'append',
    created: 'appended',
  );

  test('a UIDVALIDITY change loses nothing and uploads nothing twice',
      () async {
    final logs = RecordingAppLogRepository();
    final a = BackendObjectDevice(
      pool.account,
      _store,
      appLogger: AppLogger(logs),
    );
    addTearDown(a.db.close);
    await a.accounts.addAccount(pool.account, pool.user.password);
    final v1 = await a.putFresh('one');
    await a.sync();
    Future<int?> uidValidity() => withObjectClient(
          pool,
          (c) async =>
              (await c.selectMailboxByPath(objectDataPath)).uidValidity,
        );
    final before = await uidValidity();
    // Stalwart gives a renamed folder a new UIDVALIDITY.
    await withObjectClient(pool, (c) async {
      final box = (await c.listMailboxes(recursive: true))
          .firstWhere((m) => m.path == objectDataPath);
      await c.renameMailbox(box, 'SharedInboxMoved');
      await c.renameMailbox(
        imap.Mailbox(
          encodedName: 'SharedInboxMoved',
          encodedPath: 'SharedInboxMoved',
          flags: const [],
          pathSeparator: '/',
        ),
        objectDataPath,
      );
    });
    expect(await uidValidity(), isNot(before));

    await a.sync();

    await expectOnServerOnce(pool, a, logs, v1.messageId);
  });
}
