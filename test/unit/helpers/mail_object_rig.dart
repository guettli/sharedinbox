import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mail_object_blobs.dart';
import 'package:sharedinbox/data/repositories/mail_object_device_state.dart';
import 'package:sharedinbox/data/repositories/mail_object_log.dart';
import 'package:sharedinbox/data/repositories/mail_object_store_base.dart';
import 'package:sharedinbox/data/repositories/mail_object_store_imap.dart';
import 'package:sharedinbox/data/repositories/mail_object_store_jmap.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';

import '../db_test_helper.dart';
import '../encrypted_objects/test_helpers.dart';
import '../recording_app_log_repository.dart';
import 'fake_secure_storage.dart';
import 'mail_object_device.dart';
import 'stateful_fake_imap.dart';
import 'stateful_fake_jmap.dart';

/// The transports the log, blob and device-state suites (#1372) run on.
enum ObjectTransport { imap, imapNoUidPlus, jmap }

const rigAccountId = 'acc-rig';
const rigDataPath = 'SharedInbox/Data';

/// One fake mail server of [transport], shared by the devices of a test.
class ObjectRig implements FakeObjectServer {
  ObjectRig(this.transport)
      : imap = transport == ObjectTransport.jmap
            ? null
            : StatefulFakeImapServer(
                uidValidityByFolder: {'INBOX': 1},
                uidPlus: transport == ObjectTransport.imap,
              ),
        jmap =
            transport == ObjectTransport.jmap ? StatefulFakeJmapServer() : null;

  final ObjectTransport transport;
  final StatefulFakeImapServer? imap;
  final StatefulFakeJmapServer? jmap;

  Account get account => transport == ObjectTransport.jmap
      ? const Account(
          id: rigAccountId,
          displayName: 'Alice',
          email: 'alice@example.com',
          type: AccountType.jmap,
          jmapUrl: fakeJmapUrl,
        )
      : const Account(
          id: rigAccountId,
          displayName: 'Alice',
          email: 'alice@example.com',
          imapHost: 'imap.example.com',
          smtpHost: 'smtp.example.com',
        );

  /// The step after an upload reached the server.
  String get created =>
      transport == ObjectTransport.jmap ? 'imported' : 'appended';

  /// A new device; [budgetBytes] is its blob cache budget.
  Future<RigDevice> device({
    bool background = false,
    int budgetBytes = blobCacheBudgetBytes,
  }) async {
    final d = RigDevice(this, background: background, budgetBytes: budgetBytes);
    addTearDown(d.db.close);
    await d.accounts.addAccount(account, 'pw');
    return d;
  }

  /// The Message-IDs (with angle brackets) in the Data folder.
  List<String> dataIds() => [
        if (imap case final s?)
          for (final m in s.messagesIn(rigDataPath)) '<${m.messageId}>',
        if (jmap case final s?)
          for (final m in s.messagesIn(rigDataPath)) '<${m.messageId}>',
      ];

  /// Another client removes [messageId] (with angle brackets) for good.
  void removeElsewhere(String messageId) {
    final bare = bareMessageId(messageId);
    imap?.expungeElsewhere(bare);
    jmap?.destroyElsewhere(bare);
  }

  @override
  void addElsewhere(String path, Uint8List raw) {
    imap?.append(path, raw, flags: [r'\Seen']);
    jmap?.addElsewhere(path, raw);
  }

  @override
  List<Uint8List> rawIn(String path) => [
        if (imap case final s?)
          for (final m in s.messagesIn(path)) m.raw!,
        ...?jmap?.rawIn(path),
      ];

  @override
  int get uploadCount => imap?.appendCount ?? jmap!.uploadCount;
}

/// One install on an [ObjectRig]: database, secure storage, store and the
/// services of #1372.
class RigDevice with MailObjectDeviceOps {
  RigDevice(
    this.rig, {
    this.background = false,
    this.budgetBytes = blobCacheBudgetBytes,
    AppDatabase? db,
    FakeSecureStorage? storage,
  })  : db = db ?? openTestDatabase(),
        storage = storage ?? FakeSecureStorage();

  final ObjectRig rig;
  final bool background;
  final int budgetBytes;
  @override
  final AppDatabase db;
  final FakeSecureStorage storage;
  final logs = RecordingAppLogRepository();
  bool offline = false;
  void Function(String step)? onStep;
  DateTime clock = DateTime.utc(2026, 11, 2);

  @override
  String get accountId => rigAccountId;

  late final accounts = AccountRepositoryImpl(db, storage);
  late final MailboxRepositoryImpl mailboxes = rig.jmap == null
      ? MailboxRepositoryImpl(
          db,
          accounts,
          imapConnect: (_, __, ___) async => rig.imap!.connect(),
          namespace: _namespace,
        )
      : MailboxRepositoryImpl(db, accounts, httpClient: rig.jmap!.client);
  final _keys = testDeckKeys(() => true);

  @override
  late final MailObjectStoreBase store = rig.jmap == null
      ? MailObjectStoreImap(
          db,
          accounts,
          mailboxes,
          storage,
          imapConnect: (_, __, ___) async {
            if (offline) throw StateError('offline');
            return rig.imap!.connect();
          },
          namespace: _namespace,
          keyLookup: _keys.keyLookup,
          writeKey: _keys.writeKey,
          appLogger: AppLogger(logs),
          pushPending: !background,
          onStep: _step,
        )
      : MailObjectStoreJmap(
          db,
          accounts,
          mailboxes,
          storage,
          httpClient: rig.jmap!.client,
          keyLookup: _keys.keyLookup,
          writeKey: _keys.writeKey,
          appLogger: AppLogger(logs),
          pushPending: !background,
          onStep: _step,
        );

  late final log = MailObjectLog(db, store);
  late final blobs = MailObjectBlobStore(
    db,
    store,
    budgetBytes: budgetBytes,
    now: () => clock = clock.add(const Duration(seconds: 1)),
  );
  late final state =
      DeviceStateStore(db, store, collectionId: testDeckKey.collectionId);

  Future<void> _step(String step) async => onStep?.call(step);

  static Future<String> _namespace(Object client) =>
      (client as StatefulFakeImapClient).namespace();

  /// A new store on the same database and secure storage (an app restart;
  /// [background]: the WorkManager isolate).
  RigDevice restart({bool background = false}) => RigDevice(
        rig,
        background: background,
        budgetBytes: budgetBytes,
        db: db,
        storage: storage,
      );

  /// The folder listing the mail sync runs before the store, then a sync.
  Future<void> listAndSync() async {
    await mailboxes.syncMailboxes(accountId);
    await sync();
  }

  /// Appends one segment of [log] holding events `{n: …}` and waits for the
  /// push it kicks.
  Future<void> appendEvents(String log, List<int> ns) async {
    await this.log.append(accountId, log, testDeckKey.collectionId, [
      for (final n in ns) {'n': n},
    ]);
    await store.waitForIdle();
  }

  /// The `n` of every event of [log], in reading order.
  Future<List<Object?>> eventNs(String log) async => [
        for (final e in await this.log.events(accountId, log)) e.json['n'],
      ];

  List<String> events() => [for (final r in logs.rows) r.event];
}
