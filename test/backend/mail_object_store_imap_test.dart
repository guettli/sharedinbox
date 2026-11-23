// Backend tests for MailObjectStoreImap against a real Stalwart (#1370):
// two stores on separate databases act as two devices of one account.
// Run via: task test-backend

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/encrypted_objects/merge.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/mail_object.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mail_object_store_imap.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';
import 'package:test/test.dart';

import '../unit/db_test_helper.dart';
import '../unit/encrypted_objects/test_helpers.dart';
import '../unit/helpers/fake_secure_storage.dart';
import '../unit/recording_app_log_repository.dart';
import 'stalwart_harness.dart';

const _dataPath = 'SharedInbox/Data';

void main() {
  late PoolImapAccount pool;

  setUpAll(() {
    configureSqliteForTests();
    pool = PoolImapAccount();
  });

  Future<T> withClient<T>(Future<T> Function(imap.ImapClient c) body) async {
    final client = await pool.connect();
    try {
      return await body(client);
    } finally {
      await client.logout();
    }
  }

  // An earlier run's folders go, subfolders first.
  setUp(
    () => withClient((c) async {
      for (final path in [
        _dataPath,
        'SharedInbox/Keys',
        'SharedInbox',
        'SharedInboxMoved',
      ]) {
        try {
          await c.deleteMailbox(
            imap.Mailbox(
              encodedName: path,
              encodedPath: path,
              flags: const [],
              pathSeparator: '/',
            ),
          );
        } catch (_) {
          // Not there.
        }
      }
    }),
  );

  /// The Message-IDs and raw bytes in the Data folder, by UID.
  Future<Map<String, Uint8List>> onServer() => withClient((c) async {
        await c.selectMailboxByPath(_dataPath);
        final uids = (await c.uidSearchMessages(searchCriteria: 'ALL'))
                .matchingSequence
                ?.toList() ??
            const <int>[];
        if (uids.isEmpty) return {};
        final fetched = await c.uidFetchMessages(
          imap.MessageSequence.fromIds(uids, isUid: true),
          '(UID BODY.PEEK[])',
        );
        return {
          for (final m in fetched.messages)
            m.getHeaderValue('Message-ID')!.trim(): switch (m.mimeData) {
              final imap.BinaryMimeData d => d.data,
              final imap.TextMimeData t => utf8.encode(t.text),
              _ => Uint8List(0),
            },
        };
      });

  Future<_Device> device({AppLogger? appLogger}) async {
    final d = _Device(pool.account, appLogger: appLogger);
    addTearDown(d.db.close);
    await d.accounts.addAccount(pool.account, pool.user.password);
    return d;
  }

  test('create, edit and delete reach the other device; the tombstone stays',
      () async {
    final a = await device();
    final b = await device();

    final v1 = await a.putNew('one');
    expect((await onServer()).keys, [v1.messageId]);
    await b.listAndSync();
    expect(await b.body(v1.itemHmac!), 'one');

    final v2 = await a.putEdit(v1.itemHmac!, 'two');
    expect((await onServer()).keys, [v2.messageId]);
    await b.listAndSync();
    expect(await b.body(v1.itemHmac!), 'two');
    expect(await b.messageIds(), [v2.messageId]);

    final gone = await a.store.delete('test', v1.itemHmac!);
    await a.store.waitForIdle();
    expect((await onServer()).keys, [gone.messageId]);
    await b.listAndSync();
    expect(
      (await b.store.item('test', v1.itemHmac!))!.merge.state,
      MergeState.deleted,
    );
  });

  test(
      'an edit is uploaded although an older version of the item (same '
      'item HMAC) is on the server', () async {
    final a = await device();
    final v1 = await a.putNew('one');

    // Offline: two edits stay local.
    a.offline = true;
    final v2 = await a.putEdit(v1.itemHmac!, 'two');
    final v3 = await a.putEdit(v1.itemHmac!, 'three');
    expect((await onServer()).keys, [v1.messageId]);
    expect(
      (await a.store.observe('test', MailObjectFolder.data).first)
          .map((o) => o.messageId),
      [v3.messageId],
    );

    a.offline = false;
    await a.sync();

    expect((await onServer()).keys, [v3.messageId]);
    expect(await a.messageIds(), [v3.messageId]);
    expect(v2.itemHmac, v3.itemHmac);
  });

  test('a crash between APPEND and EXPUNGE is repaired by the next sync',
      () async {
    final a = await device();
    final b = await device();
    final v1 = await a.putNew('one');
    a.onStep = (step) {
      if (step == 'appended') throw const SocketException('crash');
    };

    final v2 = await a.putEdit(v1.itemHmac!, 'two');

    expect((await onServer()).keys.toSet(), {v1.messageId, v2.messageId});
    // Another device sees the old version as superseded.
    await b.listAndSync();
    expect(await b.body(v1.itemHmac!), 'two');

    // The app starts again: a new store on the same database.
    final restarted = a.restart();
    await restarted.store.sync('test');
    await restarted.store.waitForIdle();

    expect((await onServer()).keys, [v2.messageId]);
    expect(await restarted.messageIds(), [v2.messageId]);
  });

  test('a failed create keeps the old version locally and on the server',
      () async {
    final a = await device();
    final b = await device();
    final v1 = await a.putNew('one');
    a.onStep = (step) {
      if (step == 'append') throw StateError('APPEND refused');
    };

    final v2 = await a.putEdit(v1.itemHmac!, 'two');

    expect((await onServer()).keys, [v1.messageId]);
    expect((await a.row(v1.messageId))!.pendingDelete, isTrue);
    await b.listAndSync();
    expect(await b.body(v1.itemHmac!), 'one');

    a.onStep = null;
    await a.sync();
    expect((await onServer()).keys, [v2.messageId]);
  });

  test(
      'an object deleted on the server without a tombstone is uploaded '
      'again, byte for byte, with a warning', () async {
    final logs = RecordingAppLogRepository();
    final a = await device(appLogger: AppLogger(logs));
    final v1 = await a.putNew('one');
    await withClient((c) async {
      await c.selectMailboxByPath(_dataPath);
      final uids =
          (await c.uidSearchMessages(searchCriteria: 'ALL')).matchingSequence!;
      await c.uidMarkDeleted(uids);
      await c.uidExpunge(uids);
    });

    await a.sync();

    final server = await onServer();
    expect(server.keys, [v1.messageId]);
    expect(server[v1.messageId], v1.payload);
    expect(
      logs.rows.map((r) => r.event),
      contains('mos.vanished_reupload'),
    );
  });

  test('a UIDVALIDITY change loses nothing and uploads nothing twice',
      () async {
    final logs = RecordingAppLogRepository();
    final a = await device(appLogger: AppLogger(logs));
    final v1 = await a.putNew('one');
    await a.sync();
    final before = await withClient(
      (c) async => (await c.selectMailboxByPath(_dataPath)).uidValidity,
    );
    // Stalwart gives a renamed folder a new UIDVALIDITY.
    await withClient((c) async {
      final box = (await c.listMailboxes(recursive: true))
          .firstWhere((m) => m.path == _dataPath);
      await c.renameMailbox(box, 'SharedInboxMoved');
      await c.renameMailbox(
        imap.Mailbox(
          encodedName: 'SharedInboxMoved',
          encodedPath: 'SharedInboxMoved',
          flags: const [],
          pathSeparator: '/',
        ),
        _dataPath,
      );
    });
    final after = await withClient(
      (c) async => (await c.selectMailboxByPath(_dataPath)).uidValidity,
    );
    expect(after, isNot(before));

    await a.sync();

    expect((await onServer()).keys, [v1.messageId]);
    expect(
      logs.rows.map((r) => r.event),
      isNot(contains('mos.vanished_reupload')),
    );
    final row = (await a.row(v1.messageId))!;
    expect(row.serverId, isNotNull);
    expect(row.pendingUpload, isFalse);
  });

  test('a missing folder is made again and the heads are uploaded again',
      () async {
    final logs = RecordingAppLogRepository();
    final a = await device(appLogger: AppLogger(logs));
    final v1 = await a.putNew('one');
    await withClient(
      (c) async => c.deleteMailbox(
        (await c.listMailboxes(recursive: true))
            .firstWhere((m) => m.path == _dataPath),
      ),
    );

    await a.sync();

    final server = await onServer();
    expect(server.keys, [v1.messageId]);
    expect(server[v1.messageId], v1.payload);
    expect(
      logs.rows.map((r) => r.event),
      contains('mos.folder_missing_reupload'),
    );
  });
}

/// One install: its own database, secure storage and store.
class _Device {
  _Device(this.account, {this.appLogger, AppDatabase? db, this.storage})
      : db = db ?? openTestDatabase() {
    accounts = AccountRepositoryImpl(
      this.db,
      storage ??= FakeSecureStorage(),
    );
    mailboxes = MailboxRepositoryImpl(
      this.db,
      accounts,
      imapConnect: testImapConnect,
    );
    store = MailObjectStoreImap(
      this.db,
      accounts,
      mailboxes,
      storage!,
      imapConnect: (a, u, p) => offline
          ? Future.error(const SocketException('offline'))
          : testImapConnect(a, u, p),
      keyLookup: (_, keyId) =>
          constantTimeEquals(keyId, testDeckKey.keyId) ? testDeckKey : null,
      writeKey: (_, collectionId) =>
          collectionId == testDeckKey.collectionId ? testDeckKey : null,
      appLogger: appLogger,
      onStep: (step) async => onStep?.call(step),
    );
  }

  final Account account;
  final AppLogger? appLogger;
  final AppDatabase db;
  FakeSecureStorage? storage;
  late final AccountRepositoryImpl accounts;
  late final MailboxRepositoryImpl mailboxes;
  late final MailObjectStoreImap store;
  bool offline = false;
  void Function(String step)? onStep;

  /// A new store on the same database and secure storage (an app restart).
  _Device restart() =>
      _Device(account, appLogger: appLogger, db: db, storage: storage);

  Future<void> sync() async {
    await store.sync(account.id);
    await store.waitForIdle();
  }

  Future<void> listAndSync() async {
    await mailboxes.syncMailboxes(account.id);
    await sync();
  }

  Future<MailObject> putNew(String body) async {
    final clock = await store.clockFor(account.id);
    final put = await store.put(
      account.id,
      testObject(
        itemId: newItemIdForTest(),
        versionId: clock.send(),
        body: body,
      ),
    );
    await store.waitForIdle();
    return put;
  }

  Future<MailObject> putEdit(String itemHmac, String body) async {
    final current = (await store.item(account.id, itemHmac))!;
    final put = await store.put(
      account.id,
      edit(
        base: current.display,
        merge: current.merge,
        clock: await store.clockFor(account.id),
        parts: [
          ObjectPart(
            contentType: 'text/markdown; charset=utf-8',
            bytes: Uint8List.fromList(utf8.encode(body)),
          ),
        ],
      ),
    );
    await store.waitForIdle();
    return put;
  }

  Future<String?> body(String itemHmac) async {
    final item = await store.item(account.id, itemHmac);
    if (item == null) return null;
    return utf8.decode(item.display.parts.first.bytes);
  }

  Future<List<String>> messageIds() async => [
        for (final r in await db.select(db.mailObjects).get()) r.messageId,
      ];

  Future<MailObjectRow?> row(String messageId) =>
      (db.select(db.mailObjects)..where((t) => t.messageId.equals(messageId)))
          .getSingleOrNull();
}

var _items = 0;

/// A fresh itemId per test, so a test never sees another run's item.
String newItemIdForTest() =>
    'item-${DateTime.now().microsecondsSinceEpoch}-${_items++}';
