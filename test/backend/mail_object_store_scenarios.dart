// The backend scenarios both encrypted-object stores pass against a real
// Stalwart (#1370 IMAP, #1371 JMAP): two stores on separate databases act
// as two devices of one account. The server is arranged and inspected over
// IMAP, which shows the same folders as JMAP.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:http/http.dart' as http;
import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/log_segment.dart';
import 'package:sharedinbox/core/encrypted_objects/merge.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/mail_object.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mail_object_blobs.dart';
import 'package:sharedinbox/data/repositories/mail_object_device_state.dart';
import 'package:sharedinbox/data/repositories/mail_object_log.dart';
import 'package:sharedinbox/data/repositories/mail_object_store_base.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';
import 'package:test/test.dart';

import '../unit/db_test_helper.dart';
import '../unit/encrypted_objects/test_helpers.dart';
import '../unit/helpers/fake_secure_storage.dart';
import '../unit/helpers/mail_object_device.dart';
import '../unit/recording_app_log_repository.dart';
import 'localhost_mapping_client.dart';
import 'stalwart_harness.dart';

const objectDataPath = 'SharedInbox/Data';

/// Builds the store of [device].
typedef ObjectStoreFactory = MailObjectStoreBase Function(
  BackendObjectDevice device,
);

/// One install: its own database, secure storage and store.
class BackendObjectDevice with MailObjectDeviceOps {
  BackendObjectDevice(
    this.account,
    this._build, {
    this.appLogger,
    this.blobBudget = blobCacheBudgetBytes,
    AppDatabase? db,
    FakeSecureStorage? storage,
  })  : db = db ?? openTestDatabase(),
        storage = storage ?? FakeSecureStorage() {
    accounts = AccountRepositoryImpl(this.db, this.storage);
    mailboxes = MailboxRepositoryImpl(
      this.db,
      accounts,
      imapConnect: testImapConnect,
      httpClient: httpClient,
    );
    store = _build(this);
  }

  final Account account;
  final ObjectStoreFactory _build;
  final AppLogger? appLogger;
  final int blobBudget;
  @override
  final AppDatabase db;
  final FakeSecureStorage storage;
  late final AccountRepositoryImpl accounts;
  late final MailboxRepositoryImpl mailboxes;
  @override
  late final MailObjectStoreBase store;
  late final log = MailObjectLog(db, store);
  late final blobs = MailObjectBlobStore(db, store, budgetBytes: blobBudget);
  late final state =
      DeviceStateStore(db, store, collectionId: testDeckKey.collectionId);
  bool offline = false;
  void Function(String step)? onStep;

  /// The keys of [testDeckKeys], always unlocked.
  final keys = testDeckKeys(() => true);

  /// HTTP to Stalwart, failing while [offline].
  late final http.Client httpClient = _OfflineClient(() => offline);

  @override
  String get accountId => account.id;

  /// A new store on the same database and secure storage (an app restart).
  BackendObjectDevice restart() => BackendObjectDevice(
        account,
        _build,
        appLogger: appLogger,
        blobBudget: blobBudget,
        db: db,
        storage: storage,
      );

  Future<void> listAndSync() async {
    await mailboxes.syncMailboxes(account.id);
    await sync();
  }

  /// A new item, with an itemId no other run used.
  Future<MailObject> putFresh(String body) =>
      putNew(body: body, itemId: newItemIdForTest());

  Future<void> step(String step) async => onStep?.call(step);

  /// Appends one segment of the `review` log holding events `{n: …}`.
  Future<void> appendEvents(List<int> ns) async {
    await log.append(accountId, _log, testDeckKey.collectionId, [
      for (final n in ns) {'n': n},
    ]);
    await store.waitForIdle();
  }

  /// Compacts this device's `review` segments of this month.
  Future<List<MailObject>> compact() async {
    final packs = await log.compact(accountId, _log, _thisMonth());
    await store.waitForIdle();
    return packs;
  }

  /// The `n` of every `review` event, in reading order.
  Future<List<Object?>> eventNs() async => [
        for (final e in await log.events(accountId, _log)) e.json['n'],
      ];
}

const _log = 'review';

String _thisMonth() =>
    periodOf(Hlc(DateTime.now().millisecondsSinceEpoch, 0, 'any'));

class _OfflineClient extends http.BaseClient {
  _OfflineClient(this._offline);

  final bool Function() _offline;
  final _inner = LocalhostMappingClient();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (_offline()) return Future.error(const SocketException('offline'));
    return _inner.send(request);
  }
}

var _items = 0;

/// A fresh itemId per test, so a test never sees another run's item.
String newItemIdForTest() =>
    'item-${DateTime.now().microsecondsSinceEpoch}-${_items++}';

/// Registers the scenarios for the store [build] makes, on the account
/// [account] gives (read after `setUpAll`). [create] and [created] are the
/// store's steps around its upload (`append`/`appended` on IMAP).
void mailObjectStoreScenarios({
  required PoolImapAccount Function() pool,
  required Account Function() account,
  required ObjectStoreFactory build,
  required String create,
  required String created,
}) {
  Future<T> withClient<T>(Future<T> Function(imap.ImapClient c) body) =>
      withObjectClient(pool(), body);

  // An earlier run's folders go, subfolders first.
  setUp(() => withClient(deleteObjectFolders));

  /// The Message-IDs and raw bytes in the Data folder.
  Future<Map<String, Uint8List>> onServer() => withClient(objectDataOnServer);

  Future<BackendObjectDevice> device({
    AppLogger? appLogger,
    int blobBudget = blobCacheBudgetBytes,
  }) async {
    final d = BackendObjectDevice(
      account(),
      build,
      appLogger: appLogger,
      blobBudget: blobBudget,
    );
    addTearDown(d.db.close);
    await d.accounts.addAccount(account(), pool().user.password);
    return d;
  }

  test('create, edit and delete reach the other device; the tombstone stays',
      () async {
    final a = await device();
    final b = await device();

    final v1 = await a.putFresh('one');
    expect((await onServer()).keys, [v1.messageId]);
    await b.listAndSync();
    expect(await b.bodyOf(v1.itemHmac!), 'one');

    final v2 = await a.putEdit(v1.itemHmac!, 'two');
    expect((await onServer()).keys, [v2.messageId]);
    await b.listAndSync();
    expect(await b.bodyOf(v1.itemHmac!), 'two');
    expect(await b.messageIds(), [v2.messageId]);

    final gone = await a.store.delete(a.accountId, v1.itemHmac!);
    await a.store.waitForIdle();
    expect((await onServer()).keys, [gone.messageId]);
    await b.listAndSync();
    expect(
      (await b.store.item(b.accountId, v1.itemHmac!))!.merge.state,
      MergeState.deleted,
    );
  });

  test(
      'an edit is uploaded although an older version of the item (same '
      'item HMAC) is on the server', () async {
    final a = await device();
    final v1 = await a.putFresh('one');

    // Offline: two edits stay local.
    a.offline = true;
    final v2 = await a.putEdit(v1.itemHmac!, 'two');
    final v3 = await a.putEdit(v1.itemHmac!, 'three');
    expect((await onServer()).keys, [v1.messageId]);
    expect(
      (await a.store.observe(a.accountId, MailObjectFolder.data).first)
          .map((o) => o.messageId),
      [v3.messageId],
    );

    a.offline = false;
    await a.sync();

    expect((await onServer()).keys, [v3.messageId]);
    expect(await a.messageIds(), [v3.messageId]);
    expect(v2.itemHmac, v3.itemHmac);
  });

  test(
      'a crash between the upload and the delete is repaired by the next '
      'sync', () async {
    final a = await device();
    final b = await device();
    final v1 = await a.putFresh('one');
    a.onStep = (step) {
      if (step == created) throw const SocketException('crash');
    };

    final v2 = await a.putEdit(v1.itemHmac!, 'two');

    expect((await onServer()).keys.toSet(), {v1.messageId, v2.messageId});
    // Another device sees the old version as superseded.
    await b.listAndSync();
    expect(await b.bodyOf(v1.itemHmac!), 'two');

    // The app starts again: a new store on the same database.
    final restarted = a.restart();
    await restarted.sync();

    expect((await onServer()).keys, [v2.messageId]);
    expect(await restarted.messageIds(), [v2.messageId]);
  });

  test('a failed create keeps the old version locally and on the server',
      () async {
    final a = await device();
    final b = await device();
    final v1 = await a.putFresh('one');
    a.onStep = (step) {
      if (step == create) throw StateError('create refused');
    };

    final v2 = await a.putEdit(v1.itemHmac!, 'two');

    expect((await onServer()).keys, [v1.messageId]);
    expect((await a.row(v1.messageId))!.pendingDelete, isTrue);
    await b.listAndSync();
    expect(await b.bodyOf(v1.itemHmac!), 'one');

    a.onStep = null;
    await a.sync();
    expect((await onServer()).keys, [v2.messageId]);
  });

  test(
      'an object deleted on the server without a tombstone is uploaded '
      'again, byte for byte, with a warning', () async {
    final logs = RecordingAppLogRepository();
    final a = await device(appLogger: AppLogger(logs));
    final v1 = await a.putFresh('one');
    await withClient((c) async {
      await c.selectMailboxByPath(objectDataPath);
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

  test('a missing folder is made again and the heads are uploaded again',
      () async {
    final logs = RecordingAppLogRepository();
    final a = await device(appLogger: AppLogger(logs));
    final v1 = await a.putFresh('one');
    await withClient(
      (c) async => c.deleteMailbox(
        (await c.listMailboxes(recursive: true))
            .firstWhere((m) => m.path == objectDataPath),
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

  test(
      'log segments are compacted into one pack (#1372): the server holds '
      'only the pack, the other device reads the same events and uploads '
      'nothing again', () async {
    final logsB = RecordingAppLogRepository();
    final a = await device();
    final b = await device(appLogger: AppLogger(logsB));
    await a.appendEvents([1, 2]);
    await a.appendEvents([3]);
    await a.appendEvents([4]);
    await a.sync();
    expect(await onServer(), hasLength(3));
    await b.listAndSync();
    expect(await b.eventNs(), [1, 2, 3, 4]);

    final pack = (await a.compact()).single;
    await a.sync();

    expect((await onServer()).keys, [pack.messageId]);
    await b.sync();
    await b.sync();
    expect(await b.eventNs(), [1, 2, 3, 4]);
    expect((await onServer()).keys, [pack.messageId]);
    expect(
      logsB.rows.map((r) => r.event),
      isNot(contains('mos.vanished_reupload')),
    );
    expect(await a.eventNs(), [1, 2, 3, 4]);
  });

  test(
      'a crash between the pack upload and the expunge (#1372): after a '
      'restart there is exactly one pack and the segments are gone', () async {
    final a = await device();
    final b = await device();
    await a.appendEvents([1]);
    await a.appendEvents([2]);
    a.onStep = (step) {
      if (step == created) throw const SocketException('crash');
    };

    final pack = (await a.compact()).single;

    expect(await onServer(), hasLength(3));
    await b.listAndSync();
    expect(await b.eventNs(), [1, 2]);

    final restarted = a.restart();
    await restarted.sync();

    expect((await onServer()).keys, [pack.messageId]);
    expect(await restarted.eventNs(), [1, 2]);
    final row = (await restarted.row(pack.messageId))!;
    expect(row.pendingUpload, isFalse);
    expect(row.serverId, isNotNull);
    await b.sync();
    expect(await b.eventNs(), [1, 2]);
    expect(await b.messageIds(), [pack.messageId]);
  });

  test(
      'a blob over 256 KiB (#1372) is fetched on demand on the other device '
      'and fetched again after an eviction', () async {
    final a = await device();
    final b = await device(blobBudget: 500 * 1024);
    final image = Uint8List(400 * 1024)..fillRange(0, 400 * 1024, 7);
    final itemId =
        await a.blobs.putBlob(a.accountId, _deck, image, 'image/png');
    await a.store.waitForIdle();

    await b.listAndSync();
    final pulled = (await b.rows()).single;
    expect(pulled.payload, isNull);
    expect(pulled.sizeBytes, greaterThan(mailObjectEagerBodyLimit));
    expect((await b.blobs.blob(b.accountId, _deck, itemId))!.bytes, image);
    expect((await b.row(pulled.messageId))!.payload, isNotNull);

    final other = await a.blobs.putBlob(
      a.accountId,
      _deck,
      Uint8List(300 * 1024)..fillRange(0, 300 * 1024, 9),
      'image/png',
    );
    await a.store.waitForIdle();
    await b.sync();
    expect(await b.blobs.blob(b.accountId, _deck, other), isNotNull);
    expect((await b.row(pulled.messageId))!.payload, isNull);

    expect((await b.blobs.blob(b.accountId, _deck, itemId))!.bytes, image);
  });

  test(
      "two devices' device-state docs (#1372) converge to the value with the "
      'highest HLC per key, an unset key included', () async {
    final a = await device();
    final b = await device();
    await a.state.set(a.accountId, 'theme', 'dark');
    await a.state.set(a.accountId, 'deck', 'd1');
    await a.store.waitForIdle();
    await b.listAndSync();
    await b.state.set(b.accountId, 'theme', 'light');
    await b.state.set(b.accountId, 'deck', null);
    await b.state.set(b.accountId, 'only-b', 1);
    await b.store.waitForIdle();
    await a.listAndSync();
    await a.state.set(a.accountId, 'only-a', true);
    await a.state.set(a.accountId, 'theme', 'blue');
    await a.store.waitForIdle();
    await b.sync();

    const expected = {'theme': 'blue', 'only-b': 1, 'only-a': true};
    for (final d in [a, b]) {
      expect(await d.state.watch(d.accountId).first, expected);
      expect(await d.state.get(d.accountId, 'deck'), isNull);
    }
    // One doc per device on the server, one version each.
    expect((await onServer()).keys, hasLength(2));
  });
}

const _deck = 'deck-1';

/// [body] with a logged-in IMAP client of [pool]'s user.
Future<T> withObjectClient<T>(
  PoolImapAccount pool,
  Future<T> Function(imap.ImapClient c) body,
) async {
  final client = await pool.connect();
  try {
    return await body(client);
  } finally {
    await client.logout();
  }
}

/// Deletes the store's folders (and the rename scratch folder).
Future<void> deleteObjectFolders(imap.ImapClient c) async {
  for (final path in [
    objectDataPath,
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
}

/// The Message-IDs and raw bytes in the Data folder.
Future<Map<String, Uint8List>> objectDataOnServer(imap.ImapClient c) async {
  await c.selectMailboxByPath(objectDataPath);
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
}

/// [messageId] is the only mail in the Data folder, confirmed on [d], and
/// nothing was uploaded again for having vanished.
Future<void> expectOnServerOnce(
  PoolImapAccount pool,
  BackendObjectDevice d,
  RecordingAppLogRepository logs,
  String messageId,
) async {
  expect((await withObjectClient(pool, objectDataOnServer)).keys, [messageId]);
  expect(
    logs.rows.map((r) => r.event),
    isNot(contains('mos.vanished_reupload')),
  );
  final row = (await d.row(messageId))!;
  expect(row.serverId, isNotNull);
  expect(row.pendingUpload, isFalse);
}
