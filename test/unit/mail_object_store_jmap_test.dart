import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/encrypted_objects/envelope.dart';
import 'package:sharedinbox/core/encrypted_objects/merge.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/mail_object.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mail_object_store_jmap.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';

import 'db_test_helper.dart';
import 'helpers/fake_secure_storage.dart';
import 'helpers/mail_object_device.dart';
import 'helpers/stateful_fake_jmap.dart';
import 'recording_app_log_repository.dart';

const _acc = 'acc-j';
const _dataPath = 'SharedInbox/Data';

const _account = Account(
  id: _acc,
  displayName: 'Alice',
  email: 'alice@example.com',
  type: AccountType.jmap,
  jmapUrl: fakeJmapUrl,
);

/// One install of the app on the shared fake [server].
class _Device with MailObjectDeviceOps, ListingObjectDevice {
  _Device(this.server, {this.background = false});

  final StatefulFakeJmapServer server;
  final bool background;
  bool unlocked = true;
  final logs = RecordingAppLogRepository();
  @override
  final db = openTestDatabase();
  @override
  String get accountId => _acc;
  late final accounts = AccountRepositoryImpl(db, FakeSecureStorage());
  late final mailboxes =
      MailboxRepositoryImpl(db, accounts, httpClient: server.client);
  late final _keys = testDeckKeys(() => unlocked);
  @override
  late final MailObjectStoreJmap store = MailObjectStoreJmap(
    db,
    accounts,
    mailboxes,
    FakeSecureStorage(),
    httpClient: server.client,
    keyLookup: _keys.keyLookup,
    writeKey: _keys.writeKey,
    appLogger: AppLogger(logs),
    pushPending: !background,
    onStep: (step) async => onStep?.call(step),
  );

  void Function(String step)? onStep;

  static Future<_Device> open(
    StatefulFakeJmapServer server, {
    bool background = false,
  }) async {
    final device = _Device(server, background: background);
    addTearDown(device.db.close);
    await device.accounts.addAccount(_account, 'pw');
    return device;
  }

  /// A mailbox listing, as the mail sync does before the store runs.
  @override
  Future<void> list() => mailboxes.syncMailboxes(_acc);

  List<String> events() => [for (final r in logs.rows) r.event];
}

List<String> _ids(StatefulFakeJmapServer server, [String path = _dataPath]) => [
      for (final m in server.messagesIn(path)) '<${m.messageId}>',
    ];

void main() {
  setUpAll(configureSqliteForTests);

  test('a new object is uploaded and imported with \$seen into new mailboxes',
      () async {
    final server = StatefulFakeJmapServer();
    final a = await _Device.open(server);

    final put = await a.putNew();

    final stored = server.messagesIn(_dataPath).single;
    expect(stored.raw, put.payload);
    expect(stored.messageId, bareMessageId(put.messageId));
    final row = (await a.row(put.messageId))!;
    expect(row.pendingUpload, isFalse);
    expect(row.serverId, stored.id);
    expect(server.uploads, 1);
    expect(
      await a.appDataFolders(),
      {server.mailboxIdOf('SharedInbox'), server.mailboxIdOf(_dataPath)},
    );
    expect(stored.keywords, {r'$seen'});
  });

  test('an account without folders and without local rows is never touched',
      () async {
    final server = StatefulFakeJmapServer();
    final a = await _Device.open(server);

    await a.sync();

    expect(server.requests, isEmpty);
  });

  test('a second device pulls, opens and merges an object', () async {
    final server = StatefulFakeJmapServer();
    final row = await expectSecondDevicePulls(
      await _Device.open(server),
      await _Device.open(server),
    );
    expect(row.serverId, server.messagesIn(_dataPath).single.id);
  });

  test(
      'an edit destroys the old version in a request of its own after the '
      'import; a delete is a tombstone that reaches the other device',
      () async {
    final server = StatefulFakeJmapServer();
    final a = await _Device.open(server);
    final b = await _Device.open(server);
    final v1 = await a.putNew(body: 'one');
    await b.list();
    await b.sync();
    server.requests.clear();

    final v2 = await a.putEdit(v1.itemHmac!, 'two');

    expect(_ids(server), [v2.messageId]);
    for (final request in server.requests) {
      expect(
        request.contains('Email/import') && request.contains('Email/set'),
        isFalse,
      );
    }
    final calls = server.calls;
    expect(
      calls.indexOf('Email/set'),
      greaterThan(calls.indexOf('Email/import')),
    );
    expect((await a.rows()).map((r) => r.messageId), [v2.messageId]);
    await b.sync();
    expect((await b.rows()).map((r) => r.messageId), [v2.messageId]);
    expect(await b.bodyOf(v1.itemHmac!), 'two');

    final gone = await a.store.delete(_acc, v1.itemHmac!);
    await a.store.waitForIdle();

    expect(_ids(server), [gone.messageId]);
    await b.sync();
    final item = (await b.store.item(_acc, v1.itemHmac!))!;
    expect(item.merge.state, MergeState.deleted);
  });

  test('a pull after the first asks only for the changes, page by page',
      () async {
    final server = StatefulFakeJmapServer()..changesPage = 1;
    final a = await _Device.open(server);
    final b = await _Device.open(server);
    final v1 = await a.putNew(body: 'one');
    final kept = await a.putNew(itemId: 'i2');
    await b.list();
    await b.sync();
    server.requests.clear();

    final v2 = await a.putEdit(v1.itemHmac!, 'two');
    server.destroyElsewhere(bareMessageId(kept.messageId));
    server.requests.clear();
    final listings = server.listings;
    await b.sync();

    expect(server.listings, listings);
    expect(server.calls, contains('Email/queryChanges'));
    expect(
      server.calls.where((c) => c == 'Email/changes').length,
      greaterThan(1),
    );
    expect(await b.bodyOf(v1.itemHmac!), 'two');
    expect((await b.rows()).map((r) => r.messageId), contains(v2.messageId));
    // A head destroyed without a tombstone is uploaded again by b.
    expect(server.find(bareMessageId(kept.messageId)), isNotNull);
    expect(b.events(), contains('mos.vanished_reupload'));
  });

  for (final error in ['cannotCalculateChanges', 'tooManyChanges']) {
    test('$error: a full listing, nothing lost, nothing uploaded twice',
        () async {
      final server = StatefulFakeJmapServer();
      final a = await _Device.open(server);
      final b = await _Device.open(server);
      await a.putNew();
      await a.putNew(itemId: 'i2');
      await b.list();
      await b.sync();
      final fromA = await a.putNew(itemId: 'i3');
      final imports = server.importCount;

      server.changesError = error;
      await a.sync();
      await b.sync();
      server.changesError = null;
      await b.sync();

      expect(server.importCount, imports);
      expect(server.messagesIn(_dataPath), hasLength(3));
      expect(b.events(), contains('mos.full_resync'));
      expect(b.events(), isNot(contains('mos.vanished_reupload')));
      expect((await b.row(fromA.messageId))!.serverId, isNotNull);
      expect(await b.rows(), hasLength(3));
    });
  }

  test('a lost history (cannotCalculateChanges for old states) lists again',
      () async {
    final server = StatefulFakeJmapServer();
    final a = await _Device.open(server);
    final put = await a.putNew();
    await a.sync();
    server.forgetHistory();

    await a.sync();

    expect(a.events(), contains('mos.full_resync'));
    expect(server.importCount, 1);
    expect((await a.row(put.messageId))!.pendingUpload, isFalse);
  });

  test('a refused import keeps the old version locally and on the server',
      () async {
    final server = StatefulFakeJmapServer();
    final a = await _Device.open(server);
    final v1 = await a.putNew(body: 'one');
    server.importError = 'overQuota';

    final v2 = await a.putEdit(v1.itemHmac!, 'two');

    expect(_ids(server), [v1.messageId]);
    expect((await a.row(v1.messageId))!.pendingDelete, isTrue);
    expect((await a.row(v2.messageId))!.pendingUpload, isTrue);
    expect(a.events(), contains('mos.push.failed'));
    expect(server.calls, isNot(contains('Email/set')));
    server.importError = null;
    await a.sync();
    expect(_ids(server), [v2.messageId]);
  });

  test('a version the server has already is confirmed by its Message-ID',
      () async {
    final server = StatefulFakeJmapServer();
    final a = await _Device.open(server);
    await a.putNew();
    a.onStep = (step) {
      if (step == 'import') throw StateError('offline for a moment');
    };
    final put = await a.putNew(itemId: 'i2');
    // An earlier import landed, unseen by the listing so far.
    final copy = server.add(_dataPath, put.payload!);
    server.unlisted.add(copy.id);
    a.onStep = null;
    final imports = server.importCount;

    await a.sync();

    expect(server.importCount, imports);
    final row = (await a.row(put.messageId))!;
    expect(row.pendingUpload, isFalse);
    expect(row.serverId, copy.id);
  });

  test('alreadyExists confirms with the existing id', () async {
    final server = StatefulFakeJmapServer()
      ..refuseHeaderFilter = true
      ..dedupeImports = true;
    final a = await _Device.open(server);
    await a.putNew();
    // The answer to the import is lost, and the listing does not show the
    // new email yet.
    a.onStep = (step) {
      if (step != 'imported') return;
      server.unlisted
          .addAll([for (final m in server.messagesIn(_dataPath)) m.id]);
      throw StateError('answer lost');
    };
    final put = await a.putNew(itemId: 'i2');
    expect((await a.row(put.messageId))!.pendingUpload, isTrue);
    a.onStep = null;

    await a.sync();

    final stored = server.find(bareMessageId(put.messageId))!;
    expect(server.messagesIn(_dataPath), hasLength(2));
    final row = (await a.row(put.messageId))!;
    expect(row.pendingUpload, isFalse);
    expect(row.serverId, stored.id);
  });

  test('the size limit of the server bounds what put accepts', () async {
    final server = StatefulFakeJmapServer(maxSizeUpload: 64 * 1024);
    final a = await _Device.open(server);
    final big = 'x' * (100 * 1024);

    // Unknown limit: written, but never sent to a server that refuses it.
    final early = await a.putNew(body: big);
    expect((await a.row(early.messageId))!.pendingUpload, isTrue);
    expect(a.events(), contains('mos.push.too_large'));
    expect(server.importCount, 0);

    // Known now: refused locally.
    await expectLater(
      a.putNew(body: big, itemId: 'i2'),
      throwsA(isA<ObjectTooLargeException>()),
    );
    final small = await a.putNew(itemId: 'i3');
    expect((await a.row(small.messageId))!.pendingUpload, isFalse);
  });

  test('mailObjectEnvelopeLimit leaves room for base64 and the headers', () {
    expect(mailObjectEnvelopeLimit(100), 0);
    expect(mailObjectEnvelopeLimit(1 << 30), maxEnvelopeBytes);
    final limit = mailObjectEnvelopeLimit(64 * 1024);
    expect(limit, lessThan(64 * 1024 * 3 ~/ 4));
    expect(limit, greaterThan(40 * 1024));
  });

  test('the background never uploads, destroys or creates', () async {
    final server = StatefulFakeJmapServer();
    final a = await _Device.open(server);
    final v1 = await a.putNew(body: 'one');
    final kept = await a.putNew(itemId: 'i2');
    final bg = await _Device.open(server, background: true);
    await bg.list();
    await bg.sync();
    server.requests.clear();

    final v2 = await bg.putEdit(v1.itemHmac!, 'two');
    await bg.sync();
    expect(server.find(bareMessageId(v1.messageId)), isNotNull);
    expect((await bg.row(v2.messageId))!.pendingUpload, isTrue);

    server.destroyElsewhere(bareMessageId(kept.messageId));
    await bg.sync();
    final row = (await bg.row(kept.messageId))!;
    expect(row.pendingUpload, isTrue);
    expect(row.serverId, isNull);

    for (final write in ['Email/import', 'Email/set', 'Mailbox/set']) {
      expect(server.calls, isNot(contains(write)));
    }
    expect(server.uploads, 2);

    final fresh = StatefulFakeJmapServer();
    final alone = await _Device.open(fresh, background: true);
    await alone.putNew();
    await alone.sync();
    expect(fresh.calls, isNot(contains('Mailbox/set')));
    expect(fresh.uploads, 0);
  });

  test('a mail no key opens is kept unopened and opened after reopen',
      () async {
    final server = StatefulFakeJmapServer();
    final a = await _Device.open(server);
    final b = await _Device.open(server)
      ..unlocked = false;
    final put = await a.putNew(body: 'secret');

    await b.list();
    await b.sync();
    expect((await b.rows()).single.versionId, isNull);
    await expectLater(b.putNew(), throwsA(isA<NoWriteKeyException>()));

    b.unlocked = true;
    await b.store.reopen(_acc);

    expect(await b.bodyOf(put.itemHmac!), 'secret');
  });

  test('a body over 256 KiB is fetched on demand', () async {
    final server = StatefulFakeJmapServer();
    final a = await _Device.open(server);
    final b = await _Device.open(server);
    final put = await a.putNew(body: 'x' * (300 * 1024));

    await b.list();
    final downloads = server.downloads;
    await b.sync();
    expect(server.downloads, downloads);
    final row =
        (await b.store.observe(_acc, MailObjectFolder.data).first).single;
    expect(row.payload, isNull);

    final fetched = (await b.store.fetchBody(row))!;

    expect(fetched.payload, put.payload);
    expect(fetched.versionId, put.versionId);
  });

  test('keys folder: raw mails round-trip, idempotent by Message-ID', () async {
    final server = StatefulFakeJmapServer();
    await expectKeyMailsRoundTrip(
      await _Device.open(server),
      await _Device.open(server),
      server,
    );
  });

  test('a mail destroyed without a tombstone is uploaded again, byte for byte',
      () async {
    final server = StatefulFakeJmapServer();
    final a = await _Device.open(server);
    final put = await a.putNew();
    server.destroyElsewhere(bareMessageId(put.messageId));

    await a.sync();

    expect(server.messagesIn(_dataPath).single.raw, put.payload);
    expect(server.importCount, 2);
    expect(a.events(), contains('mos.vanished_reupload'));
  });

  test('a lost checkpoint loses nothing and uploads nothing again', () async {
    final server = StatefulFakeJmapServer();
    final a = await _Device.open(server);
    await a.putNew();
    await a.putNew(itemId: 'i2');
    await a.db.delete(a.db.syncStates).go();

    await a.sync();

    expect(server.importCount, 2);
    expect(a.events(), isNot(contains('mos.vanished_reupload')));
    for (final row in await a.rows()) {
      expect(row.serverId, server.find(bareMessageId(row.messageId))!.id);
    }
  });

  test('a missing mailbox is made again and the heads are uploaded again',
      () async {
    final server = StatefulFakeJmapServer();
    final a = await _Device.open(server);
    final put = await a.putNew();
    final old = server.mailboxIdOf(_dataPath);
    server.deleteMailbox(_dataPath);

    await a.sync();

    expect(server.mailboxIdOf(_dataPath), isNot(old));
    expect(server.messagesIn(_dataPath).single.raw, put.payload);
    expect(a.events(), contains('mos.folder_missing_reupload'));
    expect((await a.row(put.messageId))!.pendingUpload, isFalse);
  });

  test('a duplicate email of one version is destroyed', () async {
    final server = StatefulFakeJmapServer();
    await expectDuplicateRemoved(await _Device.open(server), server);
  });

  test('mails that are no objects are left alone', () async {
    final server = StatefulFakeJmapServer();
    await expectNonObjectsLeftAlone(await _Device.open(server), server);
  });

  test('an IMAP account is not synced by the JMAP store', () async {
    final server = StatefulFakeJmapServer();
    final a = await _Device.open(server);
    await a.accounts.addAccount(
      const Account(
        id: 'imap-1',
        displayName: 'Bob',
        email: 'bob@example.com',
        imapHost: 'imap.example.com',
        smtpHost: 'smtp.example.com',
      ),
      'pw',
    );

    await a.store.sync('imap-1');

    expect(server.requests, isEmpty);
  });
}
