import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/encrypted_objects/merge.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/mail_object.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/imap/imap_namespace.dart';
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mail_object_store_imap.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';

import 'db_test_helper.dart';
import 'encrypted_objects/test_helpers.dart';
import 'helpers/fake_secure_storage.dart';
import 'helpers/stateful_fake_imap.dart';
import 'recording_app_log_repository.dart';

const _acc = 'acc-1';
const _dataPath = 'SharedInbox/Data';
const _keysPath = 'SharedInbox/Keys';

const _account = Account(
  id: _acc,
  displayName: 'Alice',
  email: 'alice@example.com',
  imapHost: 'imap.example.com',
  smtpHost: 'smtp.example.com',
);

/// One install of the app: its own database, secure storage and store, all
/// talking to the shared fake [server].
class _Device {
  _Device(this.server, {this.background = false, this.unlocked = true});

  final StatefulFakeImapServer server;
  final bool background;

  /// Whether this device holds the collection key.
  bool unlocked;
  final logs = RecordingAppLogRepository();
  final db = openTestDatabase();
  late final accounts = AccountRepositoryImpl(db, FakeSecureStorage());
  late final mailboxes = MailboxRepositoryImpl(
    db,
    accounts,
    imapConnect: (_, __, ___) async => server.connect(),
    namespace: _namespace,
  );
  late final MailObjectStoreImap store = MailObjectStoreImap(
    db,
    accounts,
    mailboxes,
    FakeSecureStorage(),
    imapConnect: (_, __, ___) async => server.connect(),
    namespace: _namespace,
    keyLookup: (_, keyId) =>
        unlocked && constantTimeEquals(keyId, testDeckKey.keyId)
            ? testDeckKey
            : null,
    writeKey: (_, collectionId) =>
        unlocked && collectionId == testDeckKey.collectionId
            ? testDeckKey
            : null,
    appLogger: AppLogger(logs),
    pushPending: !background,
    onStep: (step) async => onStep?.call(step),
  );

  void Function(String step)? onStep;

  static Future<String> _namespace(Object client) =>
      (client as StatefulFakeImapClient).namespace();

  static Future<_Device> open(
    StatefulFakeImapServer server, {
    bool background = false,
    bool unlocked = true,
  }) async {
    final device = _Device(server, background: background, unlocked: unlocked);
    addTearDown(device.db.close);
    await device.accounts.addAccount(_account, 'pw');
    return device;
  }

  /// A folder listing, as the mail sync does before the store runs.
  Future<void> list() => mailboxes.syncMailboxes(_acc);

  Future<void> sync() async {
    await store.sync(_acc);
    await store.waitForIdle();
  }

  Future<MailObject> putNew(
      {String body = 'hello', String itemId = 'i1'}) async {
    final clock = await store.clockFor(_acc);
    final put = await store.put(
      _acc,
      testObject(itemId: itemId, versionId: clock.send(), body: body),
    );
    await store.waitForIdle();
    return put;
  }

  Future<MailObject> putEdit(String itemHmac, String body) async {
    final current = (await store.item(_acc, itemHmac))!;
    final put = await store.put(
      _acc,
      edit(
        base: current.display,
        merge: current.merge,
        clock: await store.clockFor(_acc),
        parts: [_markdown(body)],
      ),
    );
    await store.waitForIdle();
    return put;
  }

  Future<List<MailObjectRow>> rows([
    MailObjectFolder folder = MailObjectFolder.data,
  ]) =>
      (db.select(db.mailObjects)
            ..where((t) => t.folder.equals(folder.name))
            ..orderBy([(t) => OrderingTerm.asc(t.versionId)]))
          .get();

  Future<MailObjectRow?> row(String messageId) =>
      (db.select(db.mailObjects)..where((t) => t.messageId.equals(messageId)))
          .getSingleOrNull();

  Future<Set<String>> appDataFolders() async =>
      {for (final r in await db.select(db.appDataFolders).get()) r.path};

  Future<String?> bodyOf(String itemHmac) async {
    final item = await store.item(_acc, itemHmac);
    if (item == null) return null;
    final parts = item.display.parts;
    return parts.isEmpty ? '' : utf8.decode(parts.first.bytes);
  }

  List<String> events() => [for (final r in logs.rows) r.event];
}

ObjectPart _markdown(String body) => ObjectPart(
      contentType: 'text/markdown; charset=utf-8',
      bytes: Uint8List.fromList(utf8.encode(body)),
    );

StatefulFakeImapServer _server({
  bool uidPlus = true,
  bool headerSearch = true,
  String? namespacePrefix,
  bool gmail = false,
}) =>
    StatefulFakeImapServer(
      uidValidityByFolder: {'INBOX': 1},
      uidPlus: uidPlus,
      headerSearch: headerSearch,
      namespacePrefix: namespacePrefix,
      gmail: gmail,
    );

String _bare(String messageId) => messageId.substring(1, messageId.length - 1);

void main() {
  setUpAll(configureSqliteForTests);

  test('a new object is uploaded with \\Seen into created, registered folders',
      () async {
    final server = _server();
    final a = await _Device.open(server);

    final put = await a.putNew();

    expect(
      server.folderCommands,
      ['CREATE SharedInbox', 'CREATE $_dataPath'],
    );
    final stored = server.messagesIn(_dataPath).single;
    expect(stored.flags, contains(r'\Seen'));
    expect(stored.raw, put.payload);
    expect(stored.messageId, _bare(put.messageId));
    final row = (await a.row(put.messageId))!;
    expect(row.pendingUpload, isFalse);
    expect(row.serverId, '${stored.uid}');
    expect(await a.appDataFolders(), {'SharedInbox', _dataPath});
  });

  test('an account without folders and without local rows is never touched',
      () async {
    final server = _server();
    final a = await _Device.open(server);
    var connects = 0;
    final store = MailObjectStoreImap(
      a.db,
      a.accounts,
      a.mailboxes,
      FakeSecureStorage(),
      imapConnect: (_, __, ___) async {
        connects++;
        return server.connect();
      },
    );

    await store.sync(_acc);

    expect(connects, 0);
    expect(server.folderCommands, isEmpty);
  });

  test('a second device pulls, opens and merges an object', () async {
    final server = _server();
    final a = await _Device.open(server);
    final b = await _Device.open(server);
    final put = await a.putNew(body: 'from A');

    await b.list();
    await b.sync();

    final row = (await b.rows()).single;
    expect(row.versionId, put.versionId);
    expect(row.itemHmac, put.itemHmac);
    expect(row.payload, put.payload);
    expect(await b.bodyOf(put.itemHmac!), 'from A');
    final observed = await b.store.observe(_acc, MailObjectFolder.data).first;
    expect(observed.single.messageId, put.messageId);
    expect(await b.store.open(observed.single), isNotNull);
  });

  test(
      'an edit replaces the old version once confirmed; a delete is a '
      'tombstone that reaches the other device', () async {
    final server = _server();
    final a = await _Device.open(server);
    final b = await _Device.open(server);
    final v1 = await a.putNew(body: 'one');
    await b.list();
    await b.sync();

    final v2 = await a.putEdit(v1.itemHmac!, 'two');

    expect(
      server.messagesIn(_dataPath).map((m) => m.messageId),
      [_bare(v2.messageId)],
    );
    expect((await a.rows()).map((r) => r.messageId), [v2.messageId]);
    expect(jsonDecode((await a.row(v2.messageId))!.parents!), [v1.versionId]);
    await b.sync();
    expect((await b.rows()).map((r) => r.messageId), [v2.messageId]);
    expect(await b.bodyOf(v1.itemHmac!), 'two');

    final gone = await a.store.delete(_acc, v1.itemHmac!);
    await a.store.waitForIdle();

    expect(
      server.messagesIn(_dataPath).map((m) => m.messageId),
      [_bare(gone.messageId)],
    );
    await b.sync();
    final item = (await b.store.item(_acc, v1.itemHmac!))!;
    expect(item.merge.state, MergeState.deleted);
    expect((await b.rows()).single.messageId, gone.messageId);
  });

  test('concurrent edits on two devices are a conflict, never dropped',
      () async {
    final server = _server();
    final a = await _Device.open(server);
    final b = await _Device.open(server);
    final v1 = await a.putNew(body: 'one');
    await b.list();
    await b.sync();

    final fromA = await a.putEdit(v1.itemHmac!, 'A');
    final fromB = await b.putEdit(v1.itemHmac!, 'B');
    await a.sync();

    for (final device in [a, b]) {
      final rows = await device.rows();
      expect(
        rows.map((r) => r.messageId).toSet(),
        {fromA.messageId, fromB.messageId},
      );
      final shown = rows.last.versionId;
      expect(rows.map((r) => r.conflictOf), everyElement(shown));
      final item = (await device.store.item(_acc, v1.itemHmac!))!;
      expect(item.merge.state, MergeState.conflict);
    }
    expect(server.messagesIn(_dataPath), hasLength(2));
  });

  test('without UIDPLUS the APPEND is confirmed by a Message-ID search',
      () async {
    final server = _server(uidPlus: false);
    final a = await _Device.open(server);

    final put = await a.putNew();
    await a.sync();

    final stored = server.messagesIn(_dataPath).single;
    expect((await a.row(put.messageId))!.serverId, '${stored.uid}');
    expect(server.appendCount, 1);
  });

  test(
      'without UIDPLUS and SEARCH HEADER the APPEND is confirmed by '
      'indexing the new UIDs', () async {
    final server = _server(uidPlus: false, headerSearch: false);
    final a = await _Device.open(server);

    final put = await a.putNew();
    await a.sync();

    final stored = server.messagesIn(_dataPath).single;
    expect((await a.row(put.messageId))!.serverId, '${stored.uid}');
    expect(server.appendCount, 1);
  });

  test(
      'without SEARCH HEADER an APPEND whose answer got lost is not '
      'uploaded twice', () async {
    final server = _server(headerSearch: false)..headerSearchAnswersBad = true;
    final a = await _Device.open(server);
    a.onStep = (step) {
      if (step == 'appended') throw StateError('answer lost');
    };

    final put = await a.putNew();
    expect((await a.row(put.messageId))!.pendingUpload, isTrue);
    expect(a.events(), contains('mos.push.failed'));
    a.onStep = null;
    await a.sync();
    await a.sync();

    expect(server.appendCount, 1);
    final stored = server.messagesIn(_dataPath).single;
    final row = (await a.row(put.messageId))!;
    expect(row.pendingUpload, isFalse);
    expect(row.serverId, '${stored.uid}');
  });

  test('a failed APPEND keeps the old version locally and on the server',
      () async {
    final server = _server();
    final a = await _Device.open(server);
    final v1 = await a.putNew(body: 'one');
    server.failBefore =
        (command) => command == 'APPEND' ? StateError('quota') : null;

    final v2 = await a.putEdit(v1.itemHmac!, 'two');

    expect(
      server.messagesIn(_dataPath).map((m) => m.messageId),
      [_bare(v1.messageId)],
    );
    expect((await a.row(v1.messageId))!.pendingDelete, isTrue);
    expect((await a.row(v2.messageId))!.pendingUpload, isTrue);
    server.failBefore = null;
    await a.sync();
    expect(
      server.messagesIn(_dataPath).map((m) => m.messageId),
      [_bare(v2.messageId)],
    );
  });

  group('Gmail', () {
    test('a superseded version goes to Trash and is expunged there', () async {
      final server = _server(gmail: true)..addTrash('[Gmail]/Trash');
      final a = await _Device.open(server);
      final v1 = await a.putNew(body: 'one');

      final v2 = await a.putEdit(v1.itemHmac!, 'two');

      expect(
        server.messagesIn(_dataPath).map((m) => m.messageId),
        [_bare(v2.messageId)],
      );
      expect(server.find(_bare(v1.messageId)), isNull);
      expect(server.messagesIn('[Gmail]/Trash'), isEmpty);
      expect(server.messagesIn(StatefulFakeImapServer.gmailAllMail), isEmpty);
    });

    test('without COPYUID the copy in Trash is found by Message-ID', () async {
      final server = _server(gmail: true)
        ..addTrash('[Gmail]/Trash')
        ..moveAnswersCopyUid = false;
      final a = await _Device.open(server);
      final v1 = await a.putNew(body: 'one');

      await a.putEdit(v1.itemHmac!, 'two');

      expect(server.find(_bare(v1.messageId)), isNull);
    });

    test('without a Trash folder the old version stays and is logged',
        () async {
      final server = _server(gmail: true);
      final a = await _Device.open(server);
      final v1 = await a.putNew(body: 'one');

      final v2 = await a.putEdit(v1.itemHmac!, 'two');

      expect(server.messagesIn(_dataPath), hasLength(2));
      expect(a.events(), contains('mos.gmail_no_trash'));
      expect((await a.rows()).map((r) => r.messageId), [v2.messageId]);
    });
  });

  test(
      'folders go under the NAMESPACE prefix; another device hides and '
      'pulls them', () async {
    final server = _server(namespacePrefix: 'INBOX/');
    final a = await _Device.open(server);
    final b = await _Device.open(server);

    final put = await a.putNew();

    expect(
      server.folderCommands,
      ['CREATE INBOX/SharedInbox', 'CREATE INBOX/SharedInbox/Data'],
    );
    expect(
      await a.appDataFolders(),
      {'INBOX/SharedInbox', 'INBOX/SharedInbox/Data'},
    );
    await b.list();
    expect(
      await b.appDataFolders(),
      {'INBOX/SharedInbox', 'INBOX/SharedInbox/Data'},
    );
    await b.sync();
    expect((await b.rows()).single.messageId, put.messageId);
  });

  test('an unchanged folder is skipped after one STATUS', () async {
    final server = _server();
    final a = await _Device.open(server);
    final b = await _Device.open(server);
    await a.putNew();
    await a.sync();
    server.selects.clear();

    await a.sync();
    expect(server.selects, isNot(contains(_dataPath)));

    await b.list();
    await b.putNew(itemId: 'i2');
    server.selects.clear();
    await a.sync();
    expect(server.selects, contains(_dataPath));
    expect(await a.rows(), hasLength(2));
  });

  test('the background never appends, expunges or creates', () async {
    final server = _server();
    final a = await _Device.open(server);
    final v1 = await a.putNew(body: 'one');
    final kept = await a.putNew(itemId: 'i2');
    final bg = await _Device.open(server, background: true);
    await bg.list();
    await bg.sync();
    final appends = server.appendCount;
    final hits = server.hits.length;

    // A local edit: neither uploaded nor is the old version expunged.
    final v2 = await bg.putEdit(v1.itemHmac!, 'two');
    await bg.sync();
    expect(server.find(_bare(v1.messageId)), isNotNull);
    expect((await bg.row(v2.messageId))!.pendingUpload, isTrue);

    // A head vanished without a tombstone is only marked for re-upload.
    server.expungeElsewhere(_bare(kept.messageId));
    await bg.sync();
    final row = (await bg.row(kept.messageId))!;
    expect(row.pendingUpload, isTrue);
    expect(row.serverId, isNull);

    expect(server.appendCount, appends);
    expect(server.hits, hasLength(hits));

    // Nor does it create a folder for a local write.
    final fresh = _server();
    final alone = await _Device.open(fresh, background: true);
    await alone.putNew();
    await alone.sync();
    expect(fresh.folderCommands, isEmpty);
    expect(fresh.appendCount, 0);
  });

  test('a mail no key opens is kept unopened and opened after reopen',
      () async {
    final server = _server();
    final a = await _Device.open(server);
    final b = await _Device.open(server, unlocked: false);
    final put = await a.putNew(body: 'secret');

    await b.list();
    await b.sync();
    final row = (await b.rows()).single;
    expect(row.versionId, isNull);
    expect(row.payload, isNotNull);
    expect(await b.store.item(_acc, put.itemHmac!), isNull);
    await expectLater(b.putNew(), throwsA(isA<NoWriteKeyException>()));

    b.unlocked = true;
    await b.store.reopen(_acc);

    expect((await b.rows()).single.versionId, put.versionId);
    expect(await b.bodyOf(put.itemHmac!), 'secret');
  });

  test('a body over 256 KiB is fetched on demand', () async {
    final server = _server();
    final a = await _Device.open(server);
    final b = await _Device.open(server);
    final put = await a.putNew(body: 'x' * (300 * 1024));

    await b.list();
    await b.sync();
    final row =
        (await b.store.observe(_acc, MailObjectFolder.data).first).single;
    expect(row.payload, isNull);
    expect(row.sizeBytes, greaterThan(mailObjectEagerBodyLimit));

    final fetched = (await b.store.fetchBody(row))!;

    expect(fetched.payload, put.payload);
    expect(fetched.versionId, put.versionId);
  });

  test('keys folder: raw mails round-trip, idempotent by Message-ID', () async {
    final server = _server();
    final a = await _Device.open(server);
    final b = await _Device.open(server);
    final mail = Uint8List.fromList(
      ascii.encode(
        'Message-ID: <key-1@sharedinbox.invalid>\r\n'
        'Subject: SharedInbox key\r\n\r\nkey material\r\n',
      ),
    );

    await a.store.appendRaw(_acc, mail);
    await a.store.appendRaw(_acc, mail);
    await a.store.waitForIdle();

    expect(server.appendCount, 1);
    expect(server.messagesIn(_keysPath).single.raw, mail);
    await b.list();
    await b.sync();
    final pulled =
        (await b.store.observe(_acc, MailObjectFolder.keys).first).single;
    expect(pulled.payload, mail);
    expect(pulled.itemHmac, isNull);

    await a.store.deleteRaw(_acc, '<key-1@sharedinbox.invalid>');
    await a.store.waitForIdle();

    expect(server.messagesIn(_keysPath), isEmpty);
    expect(await a.rows(MailObjectFolder.keys), isEmpty);
    await expectLater(
      a.store.appendRaw(_acc, Uint8List.fromList(ascii.encode('x'))),
      throwsArgumentError,
    );
  });

  test('a mail vanished without a tombstone is uploaded again, byte for byte',
      () async {
    final server = _server();
    final a = await _Device.open(server);
    final put = await a.putNew();
    server.expungeElsewhere(_bare(put.messageId));

    await a.sync();

    expect(server.messagesIn(_dataPath).single.raw, put.payload);
    expect(server.appendCount, 2);
    expect(a.events(), contains('mos.vanished_reupload'));
    expect((await a.row(put.messageId))!.pendingUpload, isFalse);
  });

  test('a UIDVALIDITY change loses nothing and uploads nothing again',
      () async {
    final server = _server();
    final a = await _Device.open(server);
    await a.putNew();
    await a.putNew(itemId: 'i2');
    await a.sync();

    server.renumberFolder(_dataPath, 777, reverse: true);
    await a.sync();

    expect(server.appendCount, 2);
    expect(a.events(), isNot(contains('mos.vanished_reupload')));
    final byId = {
      for (final m in server.messagesIn(_dataPath)) '<${m.messageId}>': m.uid,
    };
    for (final row in await a.rows()) {
      expect(row.serverId, '${byId[row.messageId]}');
    }
  });

  test('a missing folder is made again and the heads are uploaded again',
      () async {
    final server = _server();
    final a = await _Device.open(server);
    final put = await a.putNew();
    server.deleteFolder(_dataPath);

    await a.sync();

    expect(server.messagesIn(_dataPath).single.raw, put.payload);
    expect(a.events(), contains('mos.folder_missing_reupload'));
    expect((await a.row(put.messageId))!.pendingUpload, isFalse);
  });

  test('a duplicate UID of one version is expunged', () async {
    final server = _server();
    final a = await _Device.open(server);
    final put = await a.putNew();
    server.append(_dataPath, put.payload!, flags: [r'\Seen']);

    await a.sync();
    await a.sync();

    expect(server.messagesIn(_dataPath), hasLength(1));
    expect(await a.rows(), hasLength(1));
  });

  test('mails that are no objects are left alone', () async {
    final server = _server();
    final a = await _Device.open(server);
    await a.putNew();
    server.append(
      _dataPath,
      Uint8List.fromList(
        ascii.encode('Message-ID: <x@test>\r\nSubject: hi\r\n\r\nhi\r\n'),
      ),
    );

    await a.sync();

    expect(await a.rows(), hasLength(1));
    expect(server.messagesIn(_dataPath), hasLength(2));
  });

  group('parsePersonalNamespace', () {
    test('reads the first personal prefix', () {
      expect(
        parsePersonalNamespace('NAMESPACE (("INBOX." ".")) NIL NIL'),
        'INBOX.',
      );
      expect(
        parsePersonalNamespace('* NAMESPACE (("" "/")("Other/" "/")) NIL NIL'),
        '',
      );
    });

    test('NIL is no prefix; another answer is none', () {
      expect(parsePersonalNamespace('NAMESPACE NIL NIL NIL'), '');
      expect(parsePersonalNamespace('CAPABILITY IMAP4rev1'), isNull);
    });
  });

  test('imapAppDataFolderPaths matches under the NAMESPACE prefix only', () {
    expect(
      imapAppDataFolderPaths(
        [
          'INBOX',
          'INBOX.SharedInbox',
          'INBOX.SharedInbox.Data',
          'INBOX.Work.SharedInbox',
        ],
        '.',
        prefix: 'INBOX.',
      ),
      {'INBOX.SharedInbox', 'INBOX.SharedInbox.Data'},
    );
  });

  test('NoWriteKeyException names the collection', () {
    expect(
      const NoWriteKeyException('deck-1').toString(),
      contains('deck-1'),
    );
  });
}
