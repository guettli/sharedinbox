import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:meta/meta.dart';

import 'package:sharedinbox/core/encrypted_objects/device_identity.dart';
import 'package:sharedinbox/core/encrypted_objects/envelope.dart';
import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/merge.dart';
import 'package:sharedinbox/core/encrypted_objects/object_mail.dart';
import 'package:sharedinbox/core/encrypted_objects/wire.dart';
import 'package:sharedinbox/core/models/account.dart' as account_model;
import 'package:sharedinbox/core/models/mail_object.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/core/storage/secure_storage.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/mail_object_devices_db.dart';

/// Bodies up to this size are fetched with the headers; larger ones (blobs)
/// on demand ([MailObjectStore.fetchBody], ENCRYPTED-OBJECTS.md 5.5).
const mailObjectEagerBodyLimit = 256 * 1024;

/// [SyncStates.resourceType] of the pull checkpoint of [folder]. Its JSON
/// shape depends on the transport.
String mailObjectCheckpointKey(MailObjectFolder folder) => 'mos:${folder.name}';

// No key until the key lifecycle (#1366) provides them.
CollectionKey? _noKey(String _, Uint8List __) => null;
CollectionKey? _noWriteKey(String _, String __) => null;

/// The transport-independent part of a [MailObjectStore] (#1370, #1371):
/// local-first writes, open and merge, the version vector, the HLC, and what
/// a mail gone from the server means. A subclass pulls and pushes over its
/// transport ([syncAccount]) and fetches bodies ([fetchRawBody]).
///
/// One sync per account at a time. With [pushEnabled] false (the
/// WorkManager isolate) a subclass only pulls; a vanished head is only
/// marked for re-upload.
abstract class MailObjectStoreBase implements MailObjectStore {
  MailObjectStoreBase(
    this.db,
    this.accounts,
    this.mailboxes,
    SecureStorage storage, {
    CollectionKeyLookup keyLookup = _noKey,
    WriteKeyLookup writeKey = _noWriteKey,
    this.appLogger,
    bool pushPending = true,
    DateTime Function()? now,
    this.onStep,
  })  : _keyLookup = keyLookup,
        _writeKey = writeKey,
        pushEnabled = pushPending,
        now = now ?? DateTime.now,
        _resolver = DeviceIdentityResolver(storage, MailObjectDevicesDb(db));

  @protected
  final AppDatabase db;
  @protected
  final AccountRepository accounts;
  @protected
  final MailboxRepository mailboxes;
  @protected
  final AppLogger? appLogger;

  /// False in the WorkManager isolate: pull only.
  @protected
  final bool pushEnabled;
  @protected
  final DateTime Function() now;

  /// Test seam: called before and after a server write.
  @protected
  final Future<void> Function(String step)? onStep;

  final CollectionKeyLookup _keyLookup;
  final WriteKeyLookup _writeKey;
  final DeviceIdentityResolver _resolver;
  final Map<String, HlcClock> _clocks = {};

  // ── Transport ─────────────────────────────────────────────────────────────

  /// Pulls (and in the foreground pushes) both folders of [account]; a
  /// no-op for an account of another transport.
  @protected
  Future<void> syncAccount(account_model.Account account);

  /// The raw RFC 5322 bytes of [row] from the server; null when the server
  /// does not have them (any more).
  @protected
  Future<Uint8List?> fetchRawBody(
    account_model.Account account,
    MailObject row,
  );

  /// The largest envelope [put] may seal for [accountId].
  @protected
  Future<int> maxEnvelopeBytesFor(String accountId) async => maxEnvelopeBytes;

  // ── Observe and open ──────────────────────────────────────────────────────

  @override
  Stream<List<MailObject>> observe(String accountId, MailObjectFolder folder) =>
      (db.select(db.mailObjects)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.folder.equals(folder.name) &
                  t.pendingDelete.equals(false),
            )
            ..orderBy([(t) => OrderingTerm.asc(t.messageId)]))
          .watch()
          .map((rows) => rows.map(_toModel).toList());

  @override
  Future<InnerObject?> open(MailObject object) {
    final payload = object.payload;
    if (payload == null || object.folder != MailObjectFolder.data) {
      return Future.value();
    }
    return _openPayload(object.accountId, payload);
  }

  Future<InnerObject?> _openPayload(String accountId, Uint8List payload) async {
    try {
      final mail = parseObjectMail(payload);
      final opened = await openObject(
        blob: mail.blob,
        itemHmacFromHeader: mail.itemHmac,
        keyLookup: (keyId) => _keyLookup(accountId, keyId),
      );
      return opened.object;
    } on EnvelopeException {
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> reopen(String accountId) =>
      _exclusive(accountId, () => openPending(accountId));

  @override
  Future<MailObjectItem?> item(String accountId, String itemHmac) async {
    final versions = <ObjectVersion>[];
    final objects = <String, InnerObject>{};
    for (final row in await _itemRows(accountId, itemHmac)) {
      if (row.versionId == null) continue;
      final object = await _openPayload(accountId, row.payload!);
      if (object == null) continue;
      objects[row.messageId] = object;
      versions.add(await ObjectVersion.of(object, ref: row.messageId));
    }
    final merge = mergeItem(known: versions, incoming: const [], vv: const {});
    final display = merge.display;
    if (display == null) return null;
    return MailObjectItem(merge: merge, display: objects[display.ref]!);
  }

  // ── Clock and writes ──────────────────────────────────────────────────────

  @override
  Future<HlcClock> clockFor(String accountId) async {
    final cached = _clocks[accountId];
    if (cached != null) return cached;
    final identity = await _resolver.resolve(accountId);
    final clock = HlcClock(
      identity.deviceId,
      nowMs: () => now().millisecondsSinceEpoch,
      high: identity.hlcHigh,
      seqHigh: identity.seqHigh,
    );
    // Past every own version seen here, before the first write (5.3).
    final rows = await (db.select(db.mailObjects)
          ..where(
            (t) => t.accountId.equals(accountId) & t.versionId.isNotNull(),
          ))
        .get();
    clock.advancePast([
      for (final r in rows)
        if (_tryHlc(r.versionId) case final hlc?)
          if (hlc.deviceId == identity.deviceId) hlc,
    ]);
    return _clocks[accountId] ??= clock;
  }

  @override
  Future<MailObject> put(String accountId, InnerObject object) async {
    final head = object.head;
    final key = _writeKey(accountId, head.collectionId);
    if (key == null) throw NoWriteKeyException(head.collectionId);
    final sealed = await sealObject(
      key: key,
      object: object,
      maxBytes: await maxEnvelopeBytesFor(accountId),
    );
    final messageId = newMessageId();
    final mail = buildObjectMail(
      messageId: messageId,
      itemHmac: sealed.itemHmac,
      blob: sealed.blob,
      date: now(),
    );
    final hmac = b64url(sealed.itemHmac);
    await db.into(db.mailObjects).insert(
          MailObjectsCompanion.insert(
            accountId: accountId,
            folder: MailObjectFolder.data.name,
            messageId: messageId,
            itemHmac: Value(hmac),
            itemId: Value(head.itemId),
            versionId: Value(head.versionId.encode()),
            parents: Value(_encodeParents(head.parents)),
            kind: Value(head.kind),
            collectionId: Value(head.collectionId),
            sizeBytes: Value(mail.length),
            pendingUpload: const Value(true),
            payload: Value(mail),
          ),
        );
    final vv = {...await _loadVv(accountId, hmac)};
    final device = head.versionId.deviceId;
    final seen = vv[device];
    if (seen == null || head.versionId > seen) vv[device] = head.versionId;
    await _saveVv(accountId, hmac, vv);
    await _remerge(accountId, hmac);
    final clock = await clockFor(accountId);
    if (device == clock.deviceId) clock.advancePast([head.versionId]);
    await _resolver.recordHighWater(
      accountId,
      DeviceIdentity(
        deviceId: clock.deviceId,
        hlcHigh: clock.high,
        seqHigh: clock.seqHigh,
      ),
    );
    _kickPush(accountId);
    return _toModel((await row(accountId, messageId))!);
  }

  @override
  Future<MailObject> delete(String accountId, String itemHmac) async {
    final current = await item(accountId, itemHmac);
    if (current == null) throw StateError('unknown item');
    return put(
      accountId,
      tombstone(
        base: current.display,
        merge: current.merge,
        clock: await clockFor(accountId),
      ),
    );
  }

  @override
  Future<MailObject> appendRaw(String accountId, Uint8List mail) async {
    final messageId =
        imap.MimeMessage.parseFromData(mail).getHeaderValue('Message-ID');
    if (messageId == null || messageId.trim().isEmpty) {
      throw ArgumentError.value(mail, 'mail', 'has no Message-ID');
    }
    final id = messageId.trim();
    final existing = await row(accountId, id);
    if (existing != null) return _toModel(existing);
    await db.into(db.mailObjects).insert(
          MailObjectsCompanion.insert(
            accountId: accountId,
            folder: MailObjectFolder.keys.name,
            messageId: id,
            sizeBytes: Value(mail.length),
            pendingUpload: const Value(true),
            payload: Value(mail),
          ),
        );
    _kickPush(accountId);
    return _toModel((await row(accountId, id))!);
  }

  @override
  Future<void> deleteRaw(String accountId, String messageId) async {
    await (db.update(db.mailObjects)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.folder.equals(MailObjectFolder.keys.name) &
                t.messageId.equals(messageId),
          ))
        .write(const MailObjectsCompanion(pendingDelete: Value(true)));
    _kickPush(accountId);
  }

  @override
  Future<MailObject?> fetchBody(MailObject object) async {
    if (object.payload != null || object.serverId == null) return object;
    final accountId = object.accountId;
    final account = await accounts.getAccount(accountId);
    if (account == null) return object;
    final payload = await fetchRawBody(account, object);
    if (payload == null) return object;
    await (db.update(db.mailObjects)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.messageId.equals(object.messageId),
          ))
        .write(MailObjectsCompanion(payload: Value(payload)));
    if (object.folder == MailObjectFolder.data) {
      await _exclusive(
        accountId,
        () => openPending(accountId, only: {object.messageId}),
      );
    }
    final stored = await row(accountId, object.messageId);
    return stored == null ? null : _toModel(stored);
  }

  // ── Sync ──────────────────────────────────────────────────────────────────

  @override
  Future<void> sync(String accountId) => _exclusive(accountId, () async {
        final account = await accounts.getAccount(accountId);
        if (account == null) return;
        await syncAccount(account);
      });

  /// Tail of the running sync per account (as in `NoteRepositoryImpl`).
  final Map<String, Future<void>> _accountTails = {};

  Future<T> _exclusive<T>(String accountId, Future<T> Function() body) {
    final previous = _accountTails[accountId];
    final run = previous == null ? body() : previous.then((_) => body());
    final tail = run.then<void>((_) {}, onError: (Object _) {});
    _accountTails[accountId] = tail;
    unawaited(
      tail.whenComplete(() {
        _accountTails.removeWhere(
          (k, v) => k == accountId && identical(v, tail),
        );
      }),
    );
    return run;
  }

  /// Completes once every sync started so far has finished.
  @visibleForTesting
  Future<void> waitForIdle() async {
    while (_accountTails.isNotEmpty) {
      await Future.wait(_accountTails.values.toList());
    }
  }

  /// Syncs right after a local write. Offline is fine: the row stays
  /// pending for the next cycle.
  void _kickPush(String accountId) {
    if (!pushEnabled) return;
    unawaited(
      sync(accountId).catchError((Object e) {
        unawaited(
          appLogger?.info(
            'mos.push.deferred',
            'Encrypted object saved locally; it is uploaded on the next sync',
            accountId: accountId,
            data: {'error': e.toString()},
          ),
        );
      }),
    );
  }

  // ── Gone from the server ──────────────────────────────────────────────────

  /// Rows the server once had that have no server id: a full listing that
  /// did not find them by Message-ID means they are gone.
  @protected
  Future<List<MailObjectRow>> unlocatedRows(
    String accountId,
    MailObjectFolder folder,
  ) =>
      (db.select(db.mailObjects)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.folder.equals(folder.name) &
                  t.serverId.isNull() &
                  t.pendingUpload.equals(false) &
                  t.pendingDelete.equals(false),
            ))
          .get();

  /// Mails gone from the server. A superseded version (or one no key opens
  /// here) is dropped; a head, and a key mail, is uploaded again from the
  /// local copy, never deleted (5.4, 4.3).
  @protected
  Future<void> markGone(
    String accountId,
    MailObjectFolder folder,
    List<MailObjectRow> gone,
  ) async {
    for (final r in gone) {
      final keep = !r.pendingDelete &&
          (folder == MailObjectFolder.keys || r.versionId != null);
      if (!keep) {
        await dropRow(accountId, r.messageId);
        continue;
      }
      await (db.update(db.mailObjects)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.messageId.equals(r.messageId),
            ))
          .write(
        const MailObjectsCompanion(
          serverId: Value(null),
          pendingUpload: Value(true),
        ),
      );
      unawaited(
        appLogger?.warn(
          'mos.vanished_reupload',
          'An encrypted object vanished from the server without a '
              'tombstone; it is uploaded again from the local copy',
          accountId: accountId,
          data: {'folder': folder.name, 'messageId': r.messageId},
        ),
      );
    }
  }

  /// Every server id of [folder] is stale: the rows lose theirs.
  @protected
  Future<void> forgetServerIds(String accountId, MailObjectFolder folder) =>
      (db.update(db.mailObjects)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) & t.folder.equals(folder.name),
            ))
          .write(const MailObjectsCompanion(serverId: Value(null)));

  /// The folder ([where] names it in the log) is gone on the server while
  /// rows exist: they all lose their server id and are uploaded again (the
  /// folder is made again by the next foreground push). Superseded rows, and
  /// rows whose body was never fetched, are dropped. Local data is never
  /// deleted for a missing folder.
  @protected
  Future<void> folderGone(
    String accountId,
    MailObjectFolder folder,
    String where,
  ) async {
    await forgetServerIds(accountId, folder);
    await clearCheckpoint(accountId, folder);
    var reupload = 0;
    for (final r in await rows(accountId, folder)) {
      if (r.pendingDelete || r.payload == null) {
        await dropRow(accountId, r.messageId);
        continue;
      }
      reupload++;
      await (db.update(db.mailObjects)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.messageId.equals(r.messageId),
            ))
          .write(const MailObjectsCompanion(pendingUpload: Value(true)));
    }
    unawaited(
      appLogger?.warn(
        'mos.folder_missing_reupload',
        'An encrypted-object folder is missing on the server; it is made '
            'again and the local objects are uploaded again',
        accountId: accountId,
        data: {'folder': folder.name, 'path': where, 'reupload': reupload},
      ),
    );
  }

  // ── Open and merge ───────────────────────────────────────────────────────

  /// Opens the data rows no key opened so far ([only]: just these) and
  /// merges their items.
  @protected
  Future<void> openPending(String accountId, {Set<String>? only}) async {
    if (only != null && only.isEmpty) return;
    final pending = await (db.select(db.mailObjects)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.folder.equals(MailObjectFolder.data.name) &
                t.versionId.isNull() &
                t.payload.isNotNull(),
          ))
        .get();
    final incoming = <String, Map<String, InnerObject>>{};
    for (final r in pending) {
      if (only != null && !only.contains(r.messageId)) continue;
      final hmac = r.itemHmac;
      if (hmac == null) continue;
      final object = await _openPayload(accountId, r.payload!);
      if (object == null) continue;
      (incoming[hmac] ??= {})[r.messageId] = object;
    }
    for (final MapEntry(key: hmac, value: objects) in incoming.entries) {
      await _remerge(accountId, hmac, incoming: objects);
    }
  }

  /// Merges item [itemHmac]: its opened rows are known, [incoming] (by
  /// Message-ID) the newly opened ones. Replays are dropped locally,
  /// superseded versions and duplicates marked [MailObjects.pendingDelete],
  /// heads get their head columns and [MailObjects.conflictOf].
  Future<void> _remerge(
    String accountId,
    String itemHmac, {
    Map<String, InnerObject> incoming = const {},
  }) async {
    final known = <ObjectVersion>[];
    final fresh = <ObjectVersion>[];
    final objects = <String, InnerObject>{};
    for (final r in await _itemRows(accountId, itemHmac)) {
      final object = incoming[r.messageId];
      if (object != null) {
        objects[r.messageId] = object;
        fresh.add(await ObjectVersion.of(object, ref: r.messageId));
        continue;
      }
      if (r.versionId == null || r.payload == null) continue;
      final opened = await _openPayload(accountId, r.payload!);
      if (opened == null) continue;
      objects[r.messageId] = opened;
      known.add(await ObjectVersion.of(opened, ref: r.messageId));
    }
    final result = mergeItem(
      known: known,
      incoming: fresh,
      vv: await _loadVv(accountId, itemHmac),
    );
    final display = result.display?.versionId.encode();
    final conflict = result.state == MergeState.conflict;
    final heads = {for (final h in result.heads) h.ref};
    final ignored = {for (final v in result.ignored) v.ref};
    await db.transaction(() async {
      for (final ref in objects.keys) {
        final messageId = ref;
        if (ignored.contains(messageId)) {
          await dropRow(accountId, messageId);
          continue;
        }
        final head = objects[messageId]!.head;
        final isHead = heads.contains(messageId);
        await (db.update(db.mailObjects)
              ..where(
                (t) =>
                    t.accountId.equals(accountId) &
                    t.messageId.equals(messageId),
              ))
            .write(
          MailObjectsCompanion(
            itemId: Value(head.itemId),
            versionId: Value(head.versionId.encode()),
            parents: Value(_encodeParents(head.parents)),
            kind: Value(head.kind),
            collectionId: Value(head.collectionId),
            // Not a head: superseded, or a duplicate of an accepted version.
            pendingDelete: Value(!isHead),
            conflictOf: Value(isHead && conflict ? display : null),
          ),
        );
      }
      await _saveVv(accountId, itemHmac, result.vv);
    });
  }

  // ── Push helpers ──────────────────────────────────────────────────────────

  /// The rows of [folder] to upload or to delete on the server, oldest
  /// version first.
  @protected
  Future<List<MailObjectRow>> pendingRows(
    String accountId,
    MailObjectFolder folder,
  ) =>
      (db.select(db.mailObjects)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.folder.equals(folder.name) &
                  (t.pendingUpload.equals(true) | t.pendingDelete.equals(true)),
            )
            ..orderBy([(t) => OrderingTerm.asc(t.versionId)]))
          .get();

  @protected
  Future<bool> stillPending(String accountId, String messageId) async =>
      (await row(accountId, messageId))?.pendingUpload ?? false;

  /// Marks [messageId] as on the server under [serverId] (null: the upload
  /// went through, but its id could not be learned; the next pull finds it).
  @protected
  Future<void> markConfirmed(
    String accountId,
    String messageId,
    String? serverId,
  ) =>
      (db.update(db.mailObjects)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) & t.messageId.equals(messageId),
            ))
          .write(
        MailObjectsCompanion(
          pendingUpload: const Value(false),
          serverId: Value(serverId),
        ),
      );

  @protected
  void logPushFailed(
    String accountId,
    MailObjectRow row,
    String op,
    Object e,
  ) {
    unawaited(
      appLogger?.warn(
        'mos.push.failed',
        'Could not $op an encrypted object on the server; retrying on the '
            'next sync',
        accountId: accountId,
        data: {
          'folder': row.folder,
          'messageId': row.messageId,
          'error': e.toString(),
        },
      ),
    );
  }

  // ── DB helpers ────────────────────────────────────────────────────────────

  @protected
  Future<MailObjectRow?> row(String accountId, String messageId) =>
      (db.select(db.mailObjects)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) & t.messageId.equals(messageId),
            ))
          .getSingleOrNull();

  @protected
  Future<List<MailObjectRow>> rows(
    String accountId,
    MailObjectFolder folder,
  ) =>
      (db.select(db.mailObjects)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) & t.folder.equals(folder.name),
            ))
          .get();

  Future<List<MailObjectRow>> _itemRows(String accountId, String itemHmac) =>
      (db.select(db.mailObjects)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.folder.equals(MailObjectFolder.data.name) &
                  t.itemHmac.equals(itemHmac),
            ))
          .get();

  /// Whether [folder] has local rows ([onServer]: ones the server had).
  @protected
  Future<bool> hasRows(
    String accountId,
    MailObjectFolder folder, {
    bool onServer = false,
  }) async =>
      (await (db.select(db.mailObjects)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.folder.equals(folder.name) &
                  (onServer
                      ? t.pendingUpload.equals(false)
                      : const Constant(true)),
            )
            ..limit(1))
          .getSingleOrNull()) !=
      null;

  @protected
  Future<void> dropRow(String accountId, String messageId) =>
      (db.delete(db.mailObjects)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) & t.messageId.equals(messageId),
            ))
          .go();

  Future<VersionVector> _loadVv(String accountId, String itemHmac) async {
    final stored = await (db.select(db.mailObjectClocks)
          ..where(
            (t) => t.accountId.equals(accountId) & t.itemHmac.equals(itemHmac),
          ))
        .getSingleOrNull();
    if (stored == null) return const {};
    try {
      final json = jsonDecode(stored.vvJson) as Map<String, dynamic>;
      return {
        for (final MapEntry(:key, :value) in json.entries)
          if (_tryHlc(value as String?) case final hlc?) key: hlc,
      };
    } on FormatException {
      return const {};
    }
  }

  Future<void> _saveVv(
    String accountId,
    String itemHmac,
    VersionVector vv,
  ) =>
      db.into(db.mailObjectClocks).insertOnConflictUpdate(
            MailObjectClocksCompanion.insert(
              accountId: accountId,
              itemHmac: itemHmac,
              vvJson: jsonEncode({
                for (final MapEntry(:key, :value) in vv.entries)
                  key: value.encode(),
              }),
            ),
          );

  /// The checkpoint JSON of [folder], or null when none is stored (or it
  /// does not parse).
  @protected
  Future<Map<String, dynamic>?> loadCheckpointJson(
    String accountId,
    MailObjectFolder folder,
  ) =>
      loadState(accountId, mailObjectCheckpointKey(folder));

  @protected
  Future<void> saveCheckpointJson(
    String accountId,
    MailObjectFolder folder,
    Map<String, Object?> checkpoint,
  ) =>
      saveState(accountId, mailObjectCheckpointKey(folder), checkpoint);

  @protected
  Future<void> clearCheckpoint(String accountId, MailObjectFolder folder) =>
      (db.delete(db.syncStates)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.resourceType.equals(mailObjectCheckpointKey(folder)),
            ))
          .go();

  /// The JSON object stored under [resourceType], or null.
  @protected
  Future<Map<String, dynamic>?> loadState(
    String accountId,
    String resourceType,
  ) async {
    final stored = await (db.select(db.syncStates)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.resourceType.equals(resourceType),
          ))
        .getSingleOrNull();
    if (stored == null) return null;
    try {
      return jsonDecode(stored.state) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  @protected
  Future<void> saveState(
    String accountId,
    String resourceType,
    Map<String, Object?> state,
  ) =>
      db.into(db.syncStates).insertOnConflictUpdate(
            SyncStatesCompanion.insert(
              accountId: accountId,
              resourceType: resourceType,
              state: jsonEncode(state),
              syncedAt: now(),
            ),
          );

  static String _encodeParents(List<Hlc> parents) =>
      jsonEncode([for (final p in parents) p.encode()]);

  static Hlc? _tryHlc(String? encoded) {
    if (encoded == null) return null;
    try {
      return Hlc.parse(encoded);
    } on FormatException {
      return null;
    }
  }

  static MailObject _toModel(MailObjectRow row) => MailObject(
        accountId: row.accountId,
        folder: MailObjectFolder.values.byName(row.folder),
        messageId: row.messageId,
        itemHmac: row.itemHmac,
        itemId: row.itemId,
        versionId: row.versionId,
        parents: row.parents == null
            ? const []
            : List<String>.from(jsonDecode(row.parents!) as List),
        kind: row.kind,
        collectionId: row.collectionId,
        serverId: row.serverId,
        sizeBytes: row.sizeBytes,
        pendingUpload: row.pendingUpload,
        pendingDelete: row.pendingDelete,
        conflictOf: row.conflictOf,
        payload: row.payload,
      );
}
