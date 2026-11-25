import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/encrypted_objects/merge.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/mail_object.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart' show MailObjectsCompanion;
import 'package:sharedinbox/data/imap/imap_namespace.dart';
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mail_object_store_imap.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';

import 'db_test_helper.dart';
import 'helpers/fake_secure_storage.dart';
import 'helpers/mail_object_device.dart';
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
class _Device with MailObjectDeviceOps, ListingObjectDevice {
  _Device(
    this.server, {
    this.background = false,
    this.unlocked = true,
    this.projectors = const [],
  });

  final StatefulFakeImapServer server;
  final bool background;
  final List<ObjectProjector> projectors;

  /// Whether this device holds the collection key.
  bool unlocked;
  final logs = RecordingAppLogRepository();
  @override
  final db = openTestDatabase();
  @override
  String get accountId => _acc;
  late final accounts = AccountRepositoryImpl(db, FakeSecureStorage());
  late final mailboxes = MailboxRepositoryImpl(
    db,
    accounts,
    imapConnect: (_, __, ___) async => server.connect(),
    namespace: _namespace,
  );
  late final _keys = testDeckKeys(() => unlocked);
  @override
  late final MailObjectStoreImap store = MailObjectStoreImap(
    db,
    accounts,
    mailboxes,
    FakeSecureStorage(),
    imapConnect: (_, __, ___) async => server.connect(),
    namespace: _namespace,
    keyLookup: _keys.keyLookup,
    writeKey: _keys.writeKey,
    keepVanishedKeyMail: (_, row) async => keepKeyMail?.call(row) ?? true,
    appLogger: AppLogger(logs),
    pushPending: !background,
    onStep: (step) async => onStep?.call(step),
    projectors: projectors,
  );

  void Function(String step)? onStep;

  /// The key lifecycle's say on a vanished key mail; null keeps all.
  bool Function(MailObject row)? keepKeyMail;

  static Future<String> _namespace(Object client) =>
      (client as StatefulFakeImapClient).namespace();

  static Future<_Device> open(
    StatefulFakeImapServer server, {
    bool background = false,
    bool unlocked = true,
    List<ObjectProjector> projectors = const [],
  }) async {
    final device = _Device(
      server,
      background: background,
      unlocked: unlocked,
      projectors: projectors,
    );
    addTearDown(device.db.close);
    await device.accounts.addAccount(_account, 'pw');
    return device;
  }

  /// A folder listing, as the mail sync does before the store runs.
  @override
  Future<void> list() => mailboxes.syncMailboxes(_acc);

  List<String> events() => [for (final r in logs.rows) r.event];
}

/// [FakeObjectServer] over the fake IMAP server.
class _ImapView implements FakeObjectServer {
  _ImapView(this.server);

  final StatefulFakeImapServer server;

  @override
  void addElsewhere(String path, Uint8List raw) =>
      server.append(path, raw, flags: [r'\Seen']);

  @override
  List<Uint8List> rawIn(String path) =>
      [for (final m in server.messagesIn(path)) m.raw!];

  @override
  int get uploadCount => server.appendCount;
}

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
    expect(stored.messageId, bareMessageId(put.messageId));
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
    await expectSecondDevicePulls(
      await _Device.open(server),
      await _Device.open(server),
    );
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
      [bareMessageId(v2.messageId)],
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
      [bareMessageId(gone.messageId)],
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

  test(
      'a kind whose heads merge by themselves is never a conflict; its '
      'projector gets every head', () async {
    final server = _server();
    final projector = _MergingProjector();
    final a = await _Device.open(server, projectors: [projector]);
    final b = await _Device.open(server, projectors: [projector]);
    final v1 = await a.putNew(body: 'one');
    await b.list();
    await b.sync();

    await a.putEdit(v1.itemHmac!, 'A');
    await b.putEdit(v1.itemHmac!, 'B');
    await a.sync();

    final rows = await a.rows();
    expect(rows, hasLength(2));
    expect(rows.map((r) => r.conflictOf), everyElement(isNull));
    expect(await a.store.observeConflicts(_acc).first, isEmpty);
    final last = projector.calls.last;
    expect(last.conflict, isFalse);
    expect(last.heads, hasLength(2));
    final item = (await a.store.item(_acc, v1.itemHmac!))!;
    expect(item.merge.state, MergeState.conflict);
    expect(item.heads, hasLength(2));
  });

  for (final (headerSearch, how) in [
    (true, 'a Message-ID search'),
    (false, 'indexing the new UIDs (no SEARCH HEADER)'),
  ]) {
    test('without UIDPLUS the APPEND is confirmed by $how', () async {
      final server = _server(uidPlus: false, headerSearch: headerSearch);
      final a = await _Device.open(server);

      final put = await a.putNew();
      await a.sync();

      final stored = server.messagesIn(_dataPath).single;
      expect((await a.row(put.messageId))!.serverId, '${stored.uid}');
      expect(server.appendCount, 1);
    });
  }

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
      [bareMessageId(v1.messageId)],
    );
    expect((await a.row(v1.messageId))!.pendingDelete, isTrue);
    expect((await a.row(v2.messageId))!.pendingUpload, isTrue);
    server.failBefore = null;
    await a.sync();
    expect(
      server.messagesIn(_dataPath).map((m) => m.messageId),
      [bareMessageId(v2.messageId)],
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
        [bareMessageId(v2.messageId)],
      );
      expect(server.find(bareMessageId(v1.messageId)), isNull);
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

      expect(server.find(bareMessageId(v1.messageId)), isNull);
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
    expect(server.find(bareMessageId(v1.messageId)), isNotNull);
    expect((await bg.row(v2.messageId))!.pendingUpload, isTrue);

    // A head vanished without a tombstone is only marked for re-upload.
    server.expungeElsewhere(bareMessageId(kept.messageId));
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

  test(
      'a body is filed under its authenticated item, not the item the '
      'server named in the header fetch', () async {
    final server = _server();
    final a = await _Device.open(server);
    final b = await _Device.open(server, unlocked: false);
    final itemA = await a.putNew(body: 'from A');
    final itemB = await a.putNew(body: 'from B');
    await b.list();
    await b.sync();
    // The server answered the header fetch of A's mail with B's item: that
    // is all the itemHmac column of an unopened row comes from.
    await (b.db.update(b.db.mailObjects)
          ..where((t) => t.messageId.equals(itemA.messageId)))
        .write(MailObjectsCompanion(itemHmac: Value(itemB.itemHmac)));

    b.unlocked = true;
    await b.store.reopen(_acc);

    expect(await b.bodyOf(itemB.itemHmac!), 'from B');
    expect(await b.bodyOf(itemA.itemHmac!), 'from A');
    expect((await b.row(itemA.messageId))!.itemHmac, itemA.itemHmac);
    expect(b.events(), contains('mos.item_header_mismatch'));
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
    await expectKeyMailsRoundTrip(
      await _Device.open(server),
      await _Device.open(server),
      _ImapView(server),
    );
  });

  test(
      'a vanished key mail is uploaded again only if the key lifecycle '
      'keeps it, also for a missing keys folder', () async {
    final server = _server();
    final a = await _Device.open(server);
    Uint8List keyMail(String id) => Uint8List.fromList(
          ascii.encode('Message-ID: <$id@sharedinbox.invalid>\r\n\r\nk\r\n'),
        );
    await a.store.appendRaw(_acc, keyMail('own'));
    await a.store.appendRaw(_acc, keyMail('loser'));
    await a.store.waitForIdle();
    a.keepKeyMail = (row) => row.messageId == '<own@sharedinbox.invalid>';

    server
      ..expungeElsewhere('own@sharedinbox.invalid')
      ..expungeElsewhere('loser@sharedinbox.invalid');
    await a.sync();

    expect(
      server.messagesIn(_keysPath).map((m) => m.messageId),
      ['own@sharedinbox.invalid'],
    );
    expect(
      [for (final r in await a.rows(MailObjectFolder.keys)) r.messageId],
      ['<own@sharedinbox.invalid>'],
    );

    await a.store.appendRaw(_acc, keyMail('loser'));
    await a.store.waitForIdle();
    server.deleteFolder(_keysPath);
    await a.sync();

    expect(
      server.messagesIn(_keysPath).map((m) => m.messageId),
      ['own@sharedinbox.invalid'],
    );
  });

  test('a mail vanished without a tombstone is uploaded again, byte for byte',
      () async {
    final server = _server();
    final a = await _Device.open(server);
    final put = await a.putNew();
    server.expungeElsewhere(bareMessageId(put.messageId));

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
    await expectDuplicateRemoved(await _Device.open(server), _ImapView(server));
  });

  test('mails that are no objects are left alone', () async {
    final server = _server();
    await expectNonObjectsLeftAlone(
      await _Device.open(server),
      _ImapView(server),
    );
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

/// A projector of the test kind whose heads merge by themselves (like
/// `card-batch`); records its calls.
class _MergingProjector extends ObjectProjector {
  final calls = <({bool conflict, List<InnerObject> heads})>[];

  @override
  String get kind => 'entry';

  @override
  bool get mergesHeads => true;

  @override
  Future<void> apply(
    String accountId,
    String itemHmac,
    ProjectedItem item,
  ) async =>
      calls.add((conflict: item.conflict, heads: item.heads));
}
