import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/encrypted_objects/entry_object.dart';
import 'package:sharedinbox/core/encrypted_objects/envelope.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/entry.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/entry_projector.dart';
import 'package:sharedinbox/data/repositories/entry_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mail_object_store_imap.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';

import 'db_test_helper.dart';
import 'encrypted_objects/test_helpers.dart';
import 'helpers/fake_secure_storage.dart';
import 'helpers/stateful_fake_imap.dart';

const _acc = 'acc-1';

const _account = Account(
  id: _acc,
  displayName: 'Alice',
  email: 'alice@example.com',
  imapHost: 'imap.example.com',
  smtpHost: 'smtp.example.com',
);

/// One install: its own database and store with the entry projection, all
/// talking to the shared fake [server].
class _Device {
  _Device(this.server, {this.unlocked = true});

  final StatefulFakeImapServer server;

  /// Whether this device holds the personal collection key.
  bool unlocked;
  bool offline = false;
  final db = openTestDatabase();
  final storage = FakeSecureStorage();
  late final accounts = AccountRepositoryImpl(db, storage);
  late final mailboxes = MailboxRepositoryImpl(
    db,
    accounts,
    imapConnect: (_, __, ___) async => _connect(),
    namespace: _namespace,
  );
  late final store = MailObjectStoreImap(
    db,
    accounts,
    mailboxes,
    storage,
    imapConnect: (_, __, ___) async => _connect(),
    namespace: _namespace,
    keyLookup: (_, keyId) =>
        unlocked && constantTimeEquals(keyId, testPersonalKey.keyId)
            ? testPersonalKey
            : null,
    writeKey: (_, collectionId) =>
        unlocked && collectionId == personalCollectionId
            ? testPersonalKey
            : null,
    projectors: [EntryProjector(db)],
  );
  late final repo = EntryRepositoryImpl(db, store);

  StatefulFakeImapClient _connect() {
    if (offline) throw StateError('offline');
    return server.connect();
  }

  static Future<String> _namespace(Object client) =>
      (client as StatefulFakeImapClient).namespace();

  static Future<_Device> open(
    StatefulFakeImapServer server, {
    bool unlocked = true,
  }) async {
    final device = _Device(server, unlocked: unlocked);
    addTearDown(() async {
      await device.store.waitForIdle();
      await device.db.close();
    });
    await device.accounts.addAccount(_account, 'pw');
    return device;
  }

  /// The folder listing the mail sync runs first, then the store's sync.
  Future<void> sync() async {
    await mailboxes.syncMailboxes(_acc);
    await store.sync(_acc);
    await store.waitForIdle();
  }

  Future<List<Entry>> entries({String query = ''}) =>
      repo.observeEntries(_acc, query: query).first;

  Future<Entry> create(String body, {String? title}) async {
    final entry = await repo.create(_acc, title: title, body: body);
    await store.waitForIdle();
    return entry;
  }

  Future<void> update(String itemId, String body, {String? title}) async {
    await repo.update(_acc, itemId, title: title, body: body);
    await store.waitForIdle();
  }
}

StatefulFakeImapServer _server() =>
    StatefulFakeImapServer(uidValidityByFolder: {'INBOX': 1});

void main() {
  test('create, edit and delete update the projection', () async {
    final a = await _Device.open(_server());
    final created = await a.create('Buy milk\nand eggs');
    expect(created.title, isNull);
    expect(created.displayTitle, 'Buy milk');
    expect((await a.entries()).single.body, 'Buy milk\nand eggs');

    await a.update(created.itemId, 'Body', title: 'Shopping');
    final edited = (await a.entries()).single;
    expect(edited.title, 'Shopping');
    expect(edited.body, 'Body');
    expect(edited.versionId, isNot(created.versionId));
    expect(
      await a.repo.entry(_acc, created.itemId),
      isA<Entry>().having((e) => e.title, 'title', 'Shopping'),
    );

    await a.repo.delete(_acc, created.itemId);
    await a.store.waitForIdle();
    expect(await a.entries(), isEmpty);
    expect(await a.repo.entry(_acc, created.itemId), isNull);
  });

  test('the list is newest first', () async {
    final a = await _Device.open(_server());
    await a.create('one');
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await a.create('two');
    expect([for (final e in await a.entries()) e.body], ['two', 'one']);
  });

  test('an edit keeps the fields another device wrote', () async {
    final server = _server();
    final a = await _Device.open(server);
    final b = await _Device.open(server);
    final clock = await b.store.clockFor(_acc);
    final itemId = newItemId();
    await b.store.put(
      _acc,
      InnerObject(
        head: ObjectHead(
          itemId: itemId,
          collectionId: personalCollectionId,
          versionId: clock.send(),
          kind: entryKind,
          extra: const {
            'title': 'Plan',
            'tags': ['work'],
            'date': '2026-11-23',
            'task': {'done': false, 'due': '2026-12-01'},
            'links': ['<m1@example.com>'],
            'later': 'kept',
          },
        ),
        parts: [
          ObjectPart(
            contentType: 'text/markdown; charset=utf-8',
            bytes: Uint8List.fromList(utf8.encode('old')),
          ),
        ],
      ),
    );
    await b.store.waitForIdle();
    await b.sync();
    await a.sync();
    expect((await a.entries()).single.tags, ['work']);

    await a.update(itemId, 'new', title: 'Plan 2');
    await a.sync();
    await b.sync();
    for (final d in [a, b]) {
      final e = (await d.entries()).single;
      expect(e.title, 'Plan 2');
      expect(e.body, 'new');
      expect(e.tags, ['work']);
      expect(e.date, '2026-11-23');
      expect(e.task!.due, '2026-12-01');
      expect(e.links, ['<m1@example.com>']);
    }
    final hmac = (await b.entries()).single.itemHmac;
    expect(
      (await b.store.item(_acc, hmac))!.display.head.extra['later'],
      'kept',
    );
  });

  test('search matches title and body, case-insensitive, escaping LIKE',
      () async {
    final a = await _Device.open(_server());
    await a.create('100% done');
    await a.create('100 percent');
    await a.create('a_b');
    await a.create('axb');
    await a.create(r'back\slash');
    await a.create('body text', title: 'Milk run');

    Future<List<String>> find(String q) async =>
        [for (final e in await a.entries(query: q)) e.displayTitle]..sort();

    expect(await find('%'), ['100% done']);
    expect(await find('_'), ['a_b']);
    expect(await find(r'\'), [r'back\slash']);
    expect(await find('MILK'), ['Milk run']);
    expect(await find('body'), ['Milk run']);
    expect(await find('  '), hasLength(6));
    expect(await find('nothing'), isEmpty);
  });

  test('two heads show a conflict; an edit resolves it', () async {
    final server = _server();
    final a = await _Device.open(server);
    final b = await _Device.open(server);
    final created = await a.create('base');
    await a.sync();
    await b.sync();

    await a.update(created.itemId, 'from A');
    await b.update(created.itemId, 'from B');
    await a.sync();
    await b.sync();
    await a.sync();
    for (final d in [a, b]) {
      expect((await d.entries()).single.hasConflict, isTrue);
    }

    await b.update(created.itemId, 'merged');
    final resolved = (await b.entries()).single;
    expect(resolved.hasConflict, isFalse);
    expect(resolved.body, 'merged');
    await b.sync();
    await a.sync();
    final onA = (await a.entries()).single;
    expect(onA.hasConflict, isFalse);
    expect(onA.body, 'merged');
  });

  test('an edit racing a delete stays visible as a conflict', () async {
    final server = _server();
    final a = await _Device.open(server);
    final b = await _Device.open(server);
    final created = await a.create('base');
    await a.sync();
    await b.sync();

    await a.update(created.itemId, 'edited');
    await b.repo.delete(_acc, created.itemId);
    await b.store.waitForIdle();
    await a.sync();
    await b.sync();
    await a.sync();
    for (final d in [a, b]) {
      final e = (await d.entries()).single;
      expect(e.hasConflict, isTrue);
      expect(e.body, 'edited');
    }
  });

  test('a pulled tombstone removes the row', () async {
    final server = _server();
    final a = await _Device.open(server);
    final b = await _Device.open(server);
    final created = await a.create('to go');
    await a.sync();
    await b.sync();
    expect(await b.entries(), hasLength(1));

    await a.repo.delete(_acc, created.itemId);
    await a.store.waitForIdle();
    await a.sync();
    await b.sync();
    expect(await b.entries(), isEmpty);
  });

  test('reopen fills the projection: after an unlock, and a missing row',
      () async {
    final server = _server();
    final a = await _Device.open(server);
    final b = await _Device.open(server, unlocked: false);
    await a.create('secret');
    await a.sync();

    await b.sync();
    expect(await b.entries(), isEmpty);
    b.unlocked = true;
    await b.store.reopen(_acc);
    expect((await b.entries()).single.body, 'secret');

    // A row an older install pulled before the table existed.
    await b.db.delete(b.db.entries).go();
    expect(await b.entries(), isEmpty);
    await b.store.reopen(_acc);
    expect((await b.entries()).single.body, 'secret');
  });

  test('a locked device cannot create', () async {
    final a = await _Device.open(_server(), unlocked: false);
    expect(
      () => a.repo.create(_acc, body: 'x'),
      throwsA(isA<NoWriteKeyException>()),
    );
  });

  test('offline create is visible in under 100 ms', () async {
    final a = await _Device.open(_server());
    a.offline = true;
    // Warm up: the first write resolves the device identity and clock.
    await a.create('warm-up');

    final shown = a.repo
        .observeEntries(_acc)
        .firstWhere((l) => l.any((e) => e.body == 'offline note'));
    final watch = Stopwatch()..start();
    await a.repo.create(_acc, body: 'offline note');
    await shown;
    watch.stop();
    // ignore: avoid_print
    print('offline create visible after ${watch.elapsedMilliseconds} ms');
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 100)));
    expect(await a.entries(), hasLength(2));
  });
}
