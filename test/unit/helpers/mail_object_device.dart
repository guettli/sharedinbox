import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show OrderingTerm;
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

/// The key lookups of a device that holds [testDeckKey] while [unlocked].
({
  CollectionKey? Function(String, Uint8List) keyLookup,
  CollectionKey? Function(String, String) writeKey,
}) testDeckKeys(bool Function() unlocked) => (
      keyLookup: (_, keyId) =>
          unlocked() && constantTimeEquals(keyId, testDeckKey.keyId)
              ? testDeckKey
              : null,
      writeKey: (_, collectionId) =>
          unlocked() && collectionId == testDeckKey.collectionId
              ? testDeckKey
              : null,
    );

/// A Message-ID without its angle brackets.
String bareMessageId(String messageId) =>
    messageId.substring(1, messageId.length - 1);
