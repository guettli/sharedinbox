import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/merge.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:sharedinbox/core/models/mail_object.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/mail_object_store_base.dart';

import '../encrypted_objects/test_helpers.dart';

/// What every encrypted-object store suite (IMAP and JMAP, unit and
/// backend) does with one device: write, sync and look at its rows.
/// Shared so the suites only hold what differs per transport.
mixin MailObjectDeviceOps {
  AppDatabase get db;
  MailObjectStoreBase get store;
  String get accountId;

  Future<void> sync() async {
    await store.sync(accountId);
    await store.waitForIdle();
  }

  Future<MailObject> putNew({
    String body = 'hello',
    String itemId = 'i1',
  }) async {
    final clock = await store.clockFor(accountId);
    final put = await store.put(
      accountId,
      testObject(itemId: itemId, versionId: clock.send(), body: body),
    );
    await store.waitForIdle();
    return put;
  }

  Future<MailObject> putEdit(String itemHmac, String body) async {
    final current = (await store.item(accountId, itemHmac))!;
    final put = await store.put(
      accountId,
      edit(
        base: current.display,
        merge: current.merge,
        clock: await store.clockFor(accountId),
        parts: [markdownPart(body)],
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

  Future<List<String>> messageIds() async => [
        for (final r in await db.select(db.mailObjects).get()) r.messageId,
      ];

  Future<Set<String>> appDataFolders() async =>
      {for (final r in await db.select(db.appDataFolders).get()) r.path};

  Future<String?> bodyOf(String itemHmac) async {
    final item = await store.item(accountId, itemHmac);
    if (item == null) return null;
    final parts = item.display.parts;
    return parts.isEmpty ? '' : utf8.decode(parts.first.bytes);
  }
}

ObjectPart markdownPart(String body) => ObjectPart(
      contentType: 'text/markdown; charset=utf-8',
      bytes: Uint8List.fromList(utf8.encode(body)),
    );

/// The key lookups of a device that holds [testDeckKey] and
/// [testPersonalKey] while [unlocked].
({
  CollectionKey? Function(String, Uint8List) keyLookup,
  CollectionKey? Function(String, String) writeKey,
}) testDeckKeys(bool Function() unlocked) => (
      keyLookup: (_, keyId) => !unlocked()
          ? null
          : _testKeys
              .where((k) => constantTimeEquals(keyId, k.keyId))
              .firstOrNull,
      writeKey: (_, collectionId) => !unlocked()
          ? null
          : _testKeys.where((k) => k.collectionId == collectionId).firstOrNull,
    );

final _testKeys = [testDeckKey, testPersonalKey];

/// A Message-ID without its angle brackets.
String bareMessageId(String messageId) =>
    messageId.substring(1, messageId.length - 1);

/// What the shared store scenarios need of a fake mail server.
abstract interface class FakeObjectServer {
  /// Another client stores [raw] in the folder at [path].
  void addElsewhere(String path, Uint8List raw);

  /// The raw mails in the folder at [path].
  List<Uint8List> rawIn(String path);

  /// Uploads (IMAP APPEND, JMAP `Email/import`) so far.
  int get uploadCount;
}

/// A device of the shared store scenarios: [list] is the mail sync's folder
/// listing that runs before the store.
mixin ListingObjectDevice on MailObjectDeviceOps {
  Future<void> list();
}

const _dataPath = 'SharedInbox/Data';
const _keysPath = 'SharedInbox/Keys';
const _keyMailId = '<key-1@sharedinbox.invalid>';

/// A second device pulls, opens and merges what [a] wrote.
Future<MailObjectRow> expectSecondDevicePulls(
  ListingObjectDevice a,
  ListingObjectDevice b,
) async {
  final put = await a.putNew(body: 'from A');

  await b.list();
  await b.sync();

  final row = (await b.rows()).single;
  expect(row.versionId, put.versionId);
  expect(row.itemHmac, put.itemHmac);
  expect(row.payload, put.payload);
  expect(await b.bodyOf(put.itemHmac!), 'from A');
  final observed = b.store.observe(b.accountId, MailObjectFolder.data);
  final shown = (await observed.first).single;
  expect(shown.messageId, put.messageId);
  expect(await b.store.open(shown), isNotNull);
  return row;
}

/// Keys folder: raw mails round-trip, idempotent by Message-ID, and
/// `deleteRaw` removes them on the server.
Future<void> expectKeyMailsRoundTrip(
  ListingObjectDevice a,
  ListingObjectDevice b,
  FakeObjectServer server,
) async {
  final mail = Uint8List.fromList(
    ascii.encode(
      'Message-ID: $_keyMailId\r\n'
      'Subject: SharedInbox key\r\n\r\nkey material\r\n',
    ),
  );

  await a.store.appendRaw(a.accountId, mail);
  await a.store.appendRaw(a.accountId, mail);
  await a.store.waitForIdle();

  expect(server.uploadCount, 1);
  expect(server.rawIn(_keysPath).single, mail);
  await b.list();
  await b.sync();
  final pulled =
      (await b.store.observe(b.accountId, MailObjectFolder.keys).first).single;
  expect(pulled.payload, mail);
  expect(pulled.itemHmac, isNull);

  await a.store.deleteRaw(a.accountId, _keyMailId);
  await a.store.waitForIdle();

  expect(server.rawIn(_keysPath), isEmpty);
  expect(await a.rows(MailObjectFolder.keys), isEmpty);
  await expectLater(
    a.store.appendRaw(a.accountId, Uint8List.fromList(ascii.encode('x'))),
    throwsArgumentError,
  );
}

/// A second server copy of one version is removed; one row stays.
Future<void> expectDuplicateRemoved(
  MailObjectDeviceOps a,
  FakeObjectServer server,
) async {
  final put = await a.putNew();
  server.addElsewhere(_dataPath, put.payload!);

  await a.sync();
  await a.sync();

  expect(server.rawIn(_dataPath), hasLength(1));
  expect(await a.rows(), hasLength(1));
}

/// A mail in the data folder that is no object is left alone.
Future<void> expectNonObjectsLeftAlone(
  MailObjectDeviceOps a,
  FakeObjectServer server,
) async {
  await a.putNew();
  server.addElsewhere(
    _dataPath,
    Uint8List.fromList(
      ascii.encode('Message-ID: <x@test>\r\nSubject: hi\r\n\r\nhi\r\n'),
    ),
  );

  await a.sync();

  expect(await a.rows(), hasLength(1));
  expect(server.rawIn(_dataPath), hasLength(2));
}
