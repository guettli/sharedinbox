import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:meta/meta.dart';

import 'package:sharedinbox/core/encrypted_objects/device_identity.dart';
import 'package:sharedinbox/core/encrypted_objects/device_state.dart';
import 'package:sharedinbox/core/encrypted_objects/envelope.dart';
import 'package:sharedinbox/core/encrypted_objects/hlc.dart';
import 'package:sharedinbox/core/encrypted_objects/inner_mime.dart';
import 'package:sharedinbox/core/encrypted_objects/keys.dart';
import 'package:sharedinbox/core/encrypted_objects/log_segment.dart';
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
Future<bool> _keepAll(String _, MailObject __) async => true;

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
    KeepVanishedKeyMail keepVanishedKeyMail = _keepAll,
    this.appLogger,
    bool pushPending = true,
    DateTime Function()? now,
    this.onStep,
    List<ObjectProjector> projectors = const [],
  })  : _keyLookup = keyLookup,
        _writeKey = writeKey,
        _keepVanishedKey = keepVanishedKeyMail,
        pushEnabled = pushPending,
        now = now ?? DateTime.now,
        _projectors = {for (final p in projectors) p.kind: p},
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
  final KeepVanishedKeyMail _keepVanishedKey;

  /// The projection of each document kind that has one, by kind (#1373).
  final Map<String, ObjectProjector> _projectors;
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
                  t.pendingDelete.equals(false) &
                  t.coveredBy.isNull(),
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
  Future<void> reopen(String accountId) => _exclusive(accountId, () async {
        await openPending(accountId);
        await _reproject(accountId);
      });

  /// Projects again every item of a kind with a projection: fills rows an
  /// older install pulled before its table existed (#1373).
  Future<void> _reproject(String accountId) async {
    if (_projectors.isEmpty) return;
    final hmacs = await (db.selectOnly(db.mailObjects, distinct: true)
          ..addColumns([db.mailObjects.itemHmac])
          ..where(
            db.mailObjects.accountId.equals(accountId) &
                db.mailObjects.folder.equals(MailObjectFolder.data.name) &
                db.mailObjects.kind.isIn(_projectors.keys) &
                db.mailObjects.versionId.isNotNull() &
                db.mailObjects.pendingDelete.equals(false),
          ))
        .map((r) => r.read(db.mailObjects.itemHmac))
        .get();
    for (final hmac in hmacs) {
      if (hmac != null) await _remerge(accountId, hmac);
    }
  }

  @override
  Future<MailObjectItem?> item(String accountId, String itemHmac) async {
    final versions = <ObjectVersion>[];
    final objects = <String, InnerObject>{};
    for (final row in await _itemRows(accountId, itemHmac)) {
      final payload = row.payload;
      if (row.versionId == null || payload == null) continue;
      final object = await _openPayload(accountId, payload);
      if (object == null) continue;
      objects[row.messageId] = object;
      versions.add(await ObjectVersion.of(object, ref: row.messageId));
    }
    final merge = mergeItem(known: versions, incoming: const [], vv: const {});
    final display = merge.display;
    if (display == null) return null;
    return MailObjectItem(
      merge: merge,
      display: objects[display.ref]!,
      versions: [for (final h in merge.distinctHeads) objects[h.ref]!],
    );
  }

  @override
  Stream<List<ConflictItem>> observeConflicts(String accountId) =>
      (db.select(db.mailObjects)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.folder.equals(MailObjectFolder.data.name) &
                  t.conflictOf.isNotNull() &
                  t.pendingDelete.equals(false) &
                  t.coveredBy.isNull(),
            )
            ..orderBy([(t) => OrderingTerm.desc(t.conflictOf)]))
          .watch()
          .map((rows) {
        final byItem = <String, ConflictItem>{};
        for (final r in rows) {
          final hmac = r.itemHmac;
          if (hmac == null) continue;
          byItem.putIfAbsent(
            hmac,
            () => ConflictItem(
              accountId: accountId,
              itemHmac: hmac,
              kind: r.kind,
              displayVersionId: r.conflictOf!,
            ),
          );
        }
        return byItem.values.toList();
      });

  @override
  Future<MailObject> resolve(
    String accountId,
    String itemHmac, {
    required Hlc keep,
  }) =>
      _exclusive(accountId, () => _resolve(accountId, itemHmac, keep));

  @override
  Future<void> keepAll(
    String accountId,
    String itemHmac, {
    required Hlc keep,
  }) =>
      _exclusive(accountId, () async {
        final (current, kept) = await _conflictHead(accountId, itemHmac, keep);
        if (kept.head.deleted) {
          throw const ConflictChangedException(
            'a deletion cannot be kept next to an edit',
          );
        }
        final clock = await clockFor(accountId);
        for (final v in current.versions) {
          if (identical(v, kept) || v.head.deleted) continue;
          await put(accountId, forkObject(v, clock));
        }
        await _resolve(accountId, itemHmac, keep);
      });

  Future<MailObject> _resolve(
    String accountId,
    String itemHmac,
    Hlc keep,
  ) async {
    final (current, kept) = await _conflictHead(accountId, itemHmac, keep);
    final clock = await clockFor(accountId);
    final next = kept.head.deleted
        ? tombstone(base: kept, merge: current.merge, clock: clock)
        : edit(base: kept, merge: current.merge, clock: clock);
    return put(accountId, next);
  }

  /// Item [itemHmac] and its opened distinct head [keep];
  /// [ConflictChangedException] when the item is not in conflict (any more) or [keep] is not one of
  /// its distinct heads.
  Future<(MailObjectItem, InnerObject)> _conflictHead(
    String accountId,
    String itemHmac,
    Hlc keep,
  ) async {
    final current = await item(accountId, itemHmac);
    if (current == null || current.merge.state != MergeState.conflict) {
      throw const ConflictChangedException('the item is not in conflict');
    }
    final i =
        current.merge.distinctHeads.indexWhere((h) => h.versionId == keep);
    if (i < 0) {
      throw ConflictChangedException('$keep is not a head of the item');
    }
    return (current, current.versions[i]);
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
    // And past every own log event (5.4 item 2).
    final maxSeq = db.mailObjectLogEvents.seq.max();
    final ownSeq = await (db.selectOnly(db.mailObjectLogEvents)
          ..addColumns([maxSeq])
          ..where(
            db.mailObjectLogEvents.accountId.equals(accountId) &
                db.mailObjectLogEvents.deviceId.equals(identity.deviceId),
          ))
        .map((r) => r.read(maxSeq))
        .getSingle();
    if (ownSeq != null) clock.advanceSeqPast(ownSeq);
    return _clocks[accountId] ??= clock;
  }

  @override
  Future<MailObject> put(String accountId, InnerObject object) =>
      _put(accountId, object);

  @override
  Future<MailObject> putCovering(
    String accountId,
    InnerObject pack, {
    required List<String> covered,
  }) =>
      _put(accountId, pack, covered: covered);

  /// [put]; the rows [covered] are hidden behind the new row and marked to
  /// be deleted on the server in the same transaction, so a crash leaves
  /// either nothing or both.
  Future<MailObject> _put(
    String accountId,
    InnerObject object, {
    List<String> covered = const [],
  }) async {
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
    if (head.kind == mailObjectBlobKind &&
        (await _itemRows(accountId, hmac)).isNotEmpty) {
      throw StateError('a blob is immutable: ${head.itemId} exists');
    }
    await db.transaction(() async {
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
      if (covered.isEmpty) return;
      await (db.update(db.mailObjects)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.folder.equals(MailObjectFolder.data.name) &
                  t.messageId.isIn(covered),
            ))
          .write(
        MailObjectsCompanion(
          pendingDelete: const Value(true),
          coveredBy: Value(messageId),
        ),
      );
    });
    final vv = {...await _loadVv(accountId, hmac)};
    final device = head.versionId.deviceId;
    final seen = vv[device];
    if (seen == null || head.versionId > seen) vv[device] = head.versionId;
    await _saveVv(accountId, hmac, vv);
    final log = await _remerge(accountId, hmac);
    if (log != null) await _coverLog(accountId, log);
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
  Future<List<MailObject>> rowsOfKind(String accountId, String kind) async => [
        for (final r in await (db.select(db.mailObjects)
              ..where(
                (t) =>
                    t.accountId.equals(accountId) &
                    t.folder.equals(MailObjectFolder.data.name) &
                    t.kind.equals(kind) &
                    t.versionId.isNotNull() &
                    t.pendingDelete.equals(false) &
                    t.coveredBy.isNull(),
              )
              ..orderBy([(t) => OrderingTerm.asc(t.versionId)]))
            .get())
          _toModel(r),
      ];

  @override
  Future<String?> itemHmacOf(
    String accountId,
    String collectionId,
    String itemId,
  ) async {
    final key = _writeKey(accountId, collectionId);
    if (key == null) return null;
    return b64url(await itemHmac(key, itemId));
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
  /// here, or one without a local body) is dropped, and so is a log segment
  /// or pack a pack covers; a head, and a key mail the key lifecycle keeps,
  /// is uploaded again from the local copy, never deleted (5.4, 4.3).
  @protected
  Future<void> markGone(
    String accountId,
    MailObjectFolder folder,
    List<MailObjectRow> gone,
  ) async {
    for (final listed in gone) {
      // As it is now: opening the pull's new mails may have covered it.
      final r = await row(accountId, listed.messageId);
      if (r == null) continue;
      final keep = !r.pendingDelete &&
          r.coveredBy == null &&
          (folder == MailObjectFolder.keys
              ? await _keepVanishedKey(accountId, _toModel(r))
              : r.versionId != null && r.payload != null);
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
  /// folder is made again by the next foreground push). Superseded and
  /// covered rows, and rows whose body was never fetched, are dropped. Local
  /// data is never deleted for a missing folder.
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
      if (r.pendingDelete ||
          r.coveredBy != null ||
          r.payload == null ||
          (folder == MailObjectFolder.keys &&
              !r.pendingUpload &&
              !await _keepVanishedKey(accountId, _toModel(r)))) {
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
    final logs = <String>{};
    for (final MapEntry(key: hmac, value: objects) in incoming.entries) {
      if (await _remerge(accountId, hmac, incoming: objects) case final log?) {
        logs.add(log);
      }
    }
    for (final log in logs) {
      await _coverLog(accountId, log);
    }
  }

  /// Merges item [itemHmac]: its opened rows are known, [incoming] (by
  /// Message-ID) the newly opened ones. Replays are dropped locally,
  /// superseded versions and duplicates marked [MailObjects.pendingDelete],
  /// heads get their head columns and [MailObjects.conflictOf], and the
  /// heads are projected ([_project]). Returns the log of a segment or pack
  /// head, whose covering the caller checks next ([_coverLog]).
  Future<String?> _remerge(
    String accountId,
    String itemHmac, {
    Map<String, InnerObject> incoming = const {},
  }) async {
    final known = <ObjectVersion>[];
    final fresh = <ObjectVersion>[];
    final objects = <String, InnerObject>{};
    final rowsById = <String, MailObjectRow>{};
    for (final r in await _itemRows(accountId, itemHmac)) {
      rowsById[r.messageId] = r;
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
    String? log;
    await db.transaction(() async {
      for (final ref in objects.keys) {
        final messageId = ref;
        if (ignored.contains(messageId)) {
          await dropRow(accountId, messageId);
          continue;
        }
        final object = objects[messageId]!;
        final head = object.head;
        final isHead = heads.contains(messageId);
        // A pack replaced it: it stays marked until the server copy is gone.
        final covered = rowsById[messageId]?.coveredBy != null &&
            rowsById[messageId]!.pendingDelete;
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
            pendingDelete: Value(!isHead || covered),
            conflictOf: Value(isHead && conflict ? display : null),
          ),
        );
        if (isHead) log = await _project(accountId, messageId, object) ?? log;
      }
      await _saveVv(accountId, itemHmac, result.vv);
      await _applyProjector(accountId, itemHmac, result, objects);
    });
    return log;
  }

  /// Hands the merged item to the projector of its kind: the newest head
  /// that is not a tombstone, so an edit racing a delete stays visible as a
  /// conflict (5.4); none once every head is a tombstone.
  Future<void> _applyProjector(
    String accountId,
    String itemHmac,
    MergeResult result,
    Map<String, InnerObject> objects,
  ) async {
    if (result.heads.isEmpty) return;
    final heads = [for (final h in result.heads) objects[h.ref]!];
    final projector = _projectors[heads.last.head.kind];
    if (projector == null) return;
    await projector.apply(
      accountId,
      itemHmac,
      heads.where((h) => !h.head.deleted).lastOrNull,
      conflict: result.state == MergeState.conflict,
    );
  }

  // ── Projections (#1372) ───────────────────────────────────────────────────

  /// Writes what readers query of the head [object] (row [messageId]): the
  /// events of a log segment or pack, the values of a device-state doc.
  /// Returns the log of a segment or pack.
  Future<String?> _project(
    String accountId,
    String messageId,
    InnerObject object,
  ) async {
    if (DeviceStateDoc.of(object) case final doc?) {
      await _projectDeviceState(accountId, doc);
      return null;
    }
    final log = logOfKind(object.head.kind);
    if (log == null) return null;
    final segment = readSegment(object);
    if (segment == null) return null;
    await db.batch((b) {
      b.insertAll(
        db.mailObjectLogEvents,
        [
          for (final e in segment.events)
            MailObjectLogEventsCompanion.insert(
              accountId: accountId,
              log: log,
              deviceId: e.deviceId,
              seq: e.seq,
              hlc: e.hlc.encode(),
              eventJson: jsonEncode(e.json),
              sourceMessageId: messageId,
            ),
        ],
        mode: InsertMode.insertOrIgnore,
      );
    });
    return log;
  }

  /// Stores each value of [doc] unless a newer one of its device is stored.
  Future<void> _projectDeviceState(String accountId, DeviceStateDoc doc) async {
    for (final MapEntry(:key, :value) in doc.values.entries) {
      final stored = await (db.select(db.mailObjectDeviceStates)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.key.equals(key) &
                  t.deviceId.equals(doc.device),
            ))
          .getSingleOrNull();
      final seen = _tryHlc(stored?.hlc);
      if (seen != null && !(value.hlc > seen)) continue;
      await db.into(db.mailObjectDeviceStates).insertOnConflictUpdate(
            MailObjectDeviceStatesCompanion.insert(
              accountId: accountId,
              key: key,
              deviceId: doc.device,
              hlc: value.hlc.encode(),
              valueJson: Value(
                value.value == null ? null : jsonEncode(value.value),
              ),
            ),
          );
    }
  }

  /// Hides the segments and packs of [log] that another pack covers
  /// ([MailObjects.coveredBy]). Of two packs covering the same ranges (a
  /// crash between APPEND and expunge, then a second compaction) the newer
  /// one stays. Only rows of this device are also marked to be deleted on
  /// the server: only the owner deletes (5.4 item 2).
  Future<void> _coverLog(String accountId, String log) async {
    final rows = await (db.select(db.mailObjects)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.folder.equals(MailObjectFolder.data.name) &
                t.kind.isIn([segKind(log), packKind(log)]) &
                t.versionId.isNotNull() &
                t.payload.isNotNull() &
                t.coveredBy.isNull(),
          ))
        .get();
    final heads = <MailObjectRow, SegmentHead>{};
    for (final r in rows) {
      final object = await _openPayload(accountId, r.payload!);
      if (object == null || object.head.deleted) continue;
      try {
        heads[r] = SegmentHead.fromExtra(object.head.extra);
      } on FormatException {
        continue;
      }
    }
    final packs = [
      for (final e in heads.entries)
        if (isPackKind(e.key.kind)) e,
    ];
    if (packs.isEmpty) return;
    final own = (await clockFor(accountId)).deviceId;
    for (final MapEntry(key: r, value: head) in heads.entries) {
      final by = packs.where(
        (p) =>
            p.key.messageId != r.messageId &&
            p.value.coversAll(head) &&
            // Equal coverage: the newer pack wins.
            (!head.coversAll(p.value) ||
                p.key.versionId!.compareTo(r.versionId!) > 0),
      );
      if (by.isEmpty) continue;
      await (db.update(db.mailObjects)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.messageId.equals(r.messageId),
            ))
          .write(
        MailObjectsCompanion(
          coveredBy: Value(by.first.key.messageId),
          pendingDelete:
              head.device == own ? const Value(true) : const Value.absent(),
        ),
      );
    }
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

  /// [pending] split into the rows to upload and the rows to delete on the
  /// server.
  @protected
  ({List<MailObjectRow> uploads, List<MailObjectRow> deletes}) splitPending(
    List<MailObjectRow> pending,
  ) =>
      (
        uploads: [
          for (final r in pending)
            if (r.pendingUpload && !r.pendingDelete && r.payload != null) r,
        ],
        deletes: [
          for (final r in pending)
            if (r.pendingDelete) r,
        ],
      );

  @protected
  Future<bool> stillPending(String accountId, String messageId) async =>
      (await row(accountId, messageId))?.pendingUpload ?? false;

  /// The [deletes] that may go on the server now: a superseded version only
  /// once no upload of its item is pending, a covered segment or pack only
  /// once its pack is confirmed (5.4: APPEND → confirm → expunge).
  @protected
  Future<List<MailObjectRow>> deletableNow(
    String accountId,
    List<MailObjectRow> uploads,
    List<MailObjectRow> deletes,
  ) async {
    final waiting = {
      for (final r in uploads)
        if (await stillPending(accountId, r.messageId)) r.itemHmac,
    };
    return [
      for (final r in deletes)
        if (!(r.itemHmac != null && waiting.contains(r.itemHmac)) &&
            await _packConfirmed(accountId, r))
          r,
    ];
  }

  Future<bool> _packConfirmed(String accountId, MailObjectRow r) async {
    final pack = r.coveredBy;
    if (pack == null) return true;
    final stored = await row(accountId, pack);
    return stored != null && !stored.pendingUpload;
  }

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

  static MailObject _toModel(MailObjectRow row) => mailObjectFromRow(row);
}

/// The [MailObject] of a `mail_objects` row.
MailObject mailObjectFromRow(MailObjectRow row) => MailObject(
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
      coveredBy: row.coveredBy,
      payload: row.payload,
    );
