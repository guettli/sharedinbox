import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

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
import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:sharedinbox/data/imap/imap_errors.dart';
import 'package:sharedinbox/data/imap/imap_expunge.dart';
import 'package:sharedinbox/data/imap/imap_namespace.dart';
import 'package:sharedinbox/data/imap/mail_object_folders.dart';
import 'package:sharedinbox/data/imap/message_id_search.dart';
import 'package:sharedinbox/data/imap/missing_folder.dart';
import 'package:sharedinbox/data/repositories/mail_object_devices_db.dart';
import 'package:sharedinbox/data/repositories/mailbox_state_writer.dart';

/// Bodies up to this size are fetched with the headers; larger ones (blobs)
/// on demand ([MailObjectStore.fetchBody], ENCRYPTED-OBJECTS.md 5.5).
const mailObjectEagerBodyLimit = 256 * 1024;

/// [SyncStates.resourceType] of the pull checkpoint of [folder]:
/// `{uidValidity, lastUid, uidNext, messages}`.
String mailObjectCheckpointKey(MailObjectFolder folder) => 'mos:${folder.name}';

const _headerFetch = '(UID RFC822.SIZE BODY.PEEK[HEADER.FIELDS '
    '(MESSAGE-ID X-SHAREDINBOX-ITEM X-SHAREDINBOX-SCHEMA)])';
const _fetchChunk = 100;

// No key until the key lifecycle (#1366) provides them.
CollectionKey? _noKey(String _, Uint8List __) => null;
CollectionKey? _noWriteKey(String _, String __) => null;

/// Where the store's folders live on the server of one account.
class _Layout {
  const _Layout(this.prefix, this.separator);

  final String prefix;
  final String separator;

  String path(MailObjectFolder folder) =>
      mailObjectFolderPath(folder, prefix: prefix, separator: separator);
}

/// One new UID as its header fetch named it.
typedef _Indexed = ({
  int uid,
  String messageId,
  String? itemHmac,
  String? schema,
  int size,
});

/// The checkpoint of one folder.
typedef _Checkpoint = ({
  int uidValidity,
  int lastUid,
  int? uidNext,
  int messages
});

/// [MailObjectStore] for IMAP accounts (#1370). JMAP accounts are a no-op
/// until #1371.
///
/// One sync per account at a time ([_exclusive]). With [pushPending] false
/// (the WorkManager isolate) it only pulls: no APPEND, no expunge, no
/// CREATE; a vanished head is only marked for re-upload.
class MailObjectStoreImap implements MailObjectStore {
  MailObjectStoreImap(
    this._db,
    this._accounts,
    this._mailboxes,
    SecureStorage storage, {
    ImapConnectFn imapConnect = connectImap,
    ImapNamespaceFn namespace = imapNamespaceFromServer,
    CollectionKeyLookup keyLookup = _noKey,
    WriteKeyLookup writeKey = _noWriteKey,
    AppLogger? appLogger,
    bool pushPending = true,
    DateTime Function()? now,
    @visibleForTesting Future<void> Function(String step)? onStep,
  })  : _imapConnect = imapConnect,
        _namespace = namespace,
        _keyLookup = keyLookup,
        _writeKey = writeKey,
        _appLogger = appLogger,
        _pushEnabled = pushPending,
        _now = now ?? DateTime.now,
        _onStep = onStep,
        _resolver = DeviceIdentityResolver(storage, MailObjectDevicesDb(_db));

  final AppDatabase _db;
  final AccountRepository _accounts;
  final MailboxRepository _mailboxes;
  final ImapConnectFn _imapConnect;
  final ImapNamespaceFn _namespace;
  final CollectionKeyLookup _keyLookup;
  final WriteKeyLookup _writeKey;
  final AppLogger? _appLogger;
  final bool _pushEnabled;
  final DateTime Function() _now;
  final Future<void> Function(String step)? _onStep;
  final DeviceIdentityResolver _resolver;
  final Map<String, HlcClock> _clocks = {};

  // ── Observe and open ──────────────────────────────────────────────────────

  @override
  Stream<List<MailObject>> observe(String accountId, MailObjectFolder folder) =>
      (_db.select(_db.mailObjects)
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
      _exclusive(accountId, () => _openPending(accountId));

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
      nowMs: () => _now().millisecondsSinceEpoch,
      high: identity.hlcHigh,
      seqHigh: identity.seqHigh,
    );
    // Past every own version seen here, before the first write (5.3).
    final rows = await (_db.select(_db.mailObjects)
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
    final sealed = await sealObject(key: key, object: object);
    final messageId = newMessageId();
    final mail = buildObjectMail(
      messageId: messageId,
      itemHmac: sealed.itemHmac,
      blob: sealed.blob,
      date: _now(),
    );
    final hmac = b64url(sealed.itemHmac);
    await _db.into(_db.mailObjects).insert(
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
    return _toModel((await _row(accountId, messageId))!);
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
    final existing = await _row(accountId, id);
    if (existing != null) return _toModel(existing);
    await _db.into(_db.mailObjects).insert(
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
    return _toModel((await _row(accountId, id))!);
  }

  @override
  Future<void> deleteRaw(String accountId, String messageId) async {
    await (_db.update(_db.mailObjects)
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
    final uid = int.tryParse(object.serverId ?? '');
    if (object.payload != null || uid == null) return object;
    final accountId = object.accountId;
    final account = await _accounts.getAccount(accountId);
    if (account == null) return object;
    final client = await _connect(account);
    try {
      final layout = await _layout(accountId, client);
      await client.selectMailboxByPath(layout.path(object.folder));
      final raw = await _fetchRaw(client, [uid]);
      final payload = raw[uid];
      if (payload == null) return object;
      await (_db.update(_db.mailObjects)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.messageId.equals(object.messageId),
            ))
          .write(MailObjectsCompanion(payload: Value(payload)));
    } finally {
      await closeImapClient(client);
    }
    if (object.folder == MailObjectFolder.data) {
      await _exclusive(
        accountId,
        () => _openPending(accountId, only: {object.messageId}),
      );
    }
    final row = await _row(accountId, object.messageId);
    return row == null ? null : _toModel(row);
  }

  // ── Sync ──────────────────────────────────────────────────────────────────

  @override
  Future<void> sync(String accountId) =>
      _exclusive(accountId, () => _sync(accountId));

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
    if (!_pushEnabled) return;
    unawaited(
      sync(accountId).catchError((Object e) {
        unawaited(
          _appLogger?.info(
            'mos.push.deferred',
            'Encrypted object saved locally; it is uploaded on the next sync',
            accountId: accountId,
            data: {'error': e.toString()},
          ),
        );
      }),
    );
  }

  Future<imap.ImapClient> _connect(account_model.Account account) async {
    final password = await _accounts.getPassword(account.id);
    final username =
        account.username.isNotEmpty ? account.username : account.email;
    return _imapConnect(account, username, password);
  }

  Future<_Layout> _layout(String accountId, [imap.ImapClient? client]) async {
    final prefix = client == null
        ? await storedImapNamespacePrefix(_db, accountId)
        : await imapNamespacePrefix(_db, accountId, client, _namespace);
    final separator = await MailboxStateWriter(_db).imapSeparator(accountId);
    return _Layout(prefix, separator);
  }

  Future<void> _sync(String accountId) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null || account.type != account_model.AccountType.imap) {
      return;
    }
    final recorded = {
      for (final r in await (_db.select(_db.appDataFolders)
            ..where((t) => t.accountId.equals(accountId)))
          .get())
        r.path,
    };
    final stored = await _layout(accountId);
    final active = [
      for (final folder in MailObjectFolder.values)
        if (recorded.contains(stored.path(folder)) ||
            await _hasRows(accountId, folder))
          folder,
    ];
    // No folder of ours and nothing to upload: no connection, no folder.
    if (active.isEmpty) return;
    final client = await _connect(account);
    try {
      final layout = await _layout(accountId, client);
      for (final folder in active) {
        await _syncFolder(client, accountId, folder, layout);
      }
    } finally {
      await closeImapClient(client);
    }
  }

  Future<void> _syncFolder(
    imap.ImapClient client,
    String accountId,
    MailObjectFolder folder,
    _Layout layout,
  ) async {
    final path = layout.path(folder);
    final pulled = await _pull(client, accountId, folder, path);
    if (folder == MailObjectFolder.data && pulled != null) {
      await _openPending(accountId, only: pulled.inserted);
    }
    if (pulled != null && pulled.trusted) {
      await _handleVanished(accountId, folder, pulled.vanished);
    }
    if (!_pushEnabled) return;
    await _push(client, accountId, folder, layout, exists: pulled != null);
  }

  /// Pulls [folder] at [path]. Null when the folder is missing on the
  /// server. [inserted] are the Message-IDs of the rows it added,
  /// [vanished] the index rows whose UID is gone; [trusted] is false for a
  /// listing that cannot be right (no UID although the folder has mail).
  Future<
      ({
        Set<String> inserted,
        List<MailObjectUidRow> vanished,
        bool trusted,
      })?> _pull(
    imap.ImapClient client,
    String accountId,
    MailObjectFolder folder,
    String path,
  ) async {
    final imap.Mailbox status;
    try {
      status = await client.statusMailbox(
        imap.Mailbox(
          encodedName: path,
          encodedPath: path,
          flags: const [],
          pathSeparator: '/',
        ),
        const [
          imap.StatusFlags.uidValidity,
          imap.StatusFlags.uidNext,
          imap.StatusFlags.messages,
        ],
      );
    } catch (e) {
      if (!isImapMailboxNotFound(e)) rethrow;
      // Nothing the server had: nothing to protect (a first upload makes
      // the folder in the push).
      if (!await _hasRows(accountId, folder, onServer: true)) return null;
      if (!await appFolderGone(
        client,
        path,
        e,
        accountId: accountId,
        event: 'mos.select_failed_kept',
        message: 'Could not open an encrypted-object folder; the server did '
            'not say NONEXISTENT and still lists it: the local objects are '
            'kept',
        appLogger: _appLogger,
      )) {
        rethrow;
      }
      await _folderGone(accountId, folder, path);
      return null;
    }
    final uidValidity = status.uidValidity ?? 0;
    final checkpoint = await _loadCheckpoint(accountId, folder);
    if (checkpoint != null &&
        checkpoint.uidValidity == uidValidity &&
        checkpoint.uidNext == status.uidNext &&
        checkpoint.messages == status.messagesExists) {
      return (
        inserted: const <String>{},
        vanished: const <MailObjectUidRow>[],
        trusted: true,
      );
    }
    await client.selectMailboxByPath(path);
    if (checkpoint != null && checkpoint.uidValidity != uidValidity) {
      await _forgetUids(accountId, folder);
    }
    final serverUids = (await client.uidSearchMessages(searchCriteria: 'ALL'))
            .matchingSequence
            ?.toList() ??
        const <int>[];
    final trusted = serverUids.isNotEmpty || status.messagesExists == 0;
    final index = await _index(accountId, folder);
    final known = {for (final r in index) r.uid};
    final serverSet = serverUids.toSet();
    final fresh = [
      for (final uid in serverUids)
        if (!known.contains(uid)) uid,
    ];
    final indexed = await _indexUids(
      client,
      accountId,
      folder,
      uidValidity,
      fresh,
    );
    final inserted = await _adopt(
      client,
      accountId,
      folder,
      indexed,
      serverSet,
    );
    await _saveCheckpoint(
      accountId,
      folder,
      (
        uidValidity: uidValidity,
        lastUid: serverUids.fold(0, math.max),
        uidNext: status.uidNext,
        messages: status.messagesExists,
      ),
    );
    return (
      inserted: inserted,
      vanished: trusted
          ? [
              for (final r in index)
                if (r.uidValidity == uidValidity && !serverSet.contains(r.uid))
                  r,
            ]
          : const <MailObjectUidRow>[],
      trusted: trusted,
    );
  }

  /// Fetches the headers and sizes of [uids] and records them in the
  /// index.
  Future<List<_Indexed>> _indexUids(
    imap.ImapClient client,
    String accountId,
    MailObjectFolder folder,
    int uidValidity,
    List<int> uids,
  ) async {
    final out = <_Indexed>[];
    for (var i = 0; i < uids.length; i += _fetchChunk) {
      final chunk = uids.sublist(i, math.min(i + _fetchChunk, uids.length));
      final fetched = await client.uidFetchMessages(
        imap.MessageSequence.fromIds(chunk, isUid: true),
        _headerFetch,
      );
      for (final msg in fetched.messages) {
        final uid = msg.uid;
        if (uid == null) continue;
        final entry = (
          uid: uid,
          messageId: msg.getHeaderValue('Message-ID')?.trim() ?? '',
          itemHmac: msg.getHeaderValue(itemHeader)?.trim(),
          schema: msg.getHeaderValue(schemaHeader)?.trim(),
          size: msg.size ?? 0,
        );
        out.add(entry);
        await _db.into(_db.mailObjectUids).insertOnConflictUpdate(
              MailObjectUidsCompanion.insert(
                accountId: accountId,
                folder: folder.name,
                uidValidity: uidValidity,
                uid: uid,
                messageId: entry.messageId,
                itemHmac: Value(entry.itemHmac),
                sizeBytes: Value(entry.size),
              ),
            );
      }
    }
    return out;
  }

  /// Matches the newly indexed mails to local rows by Message-ID (a version
  /// uploaded before, or seen before a UIDVALIDITY change) and stores the
  /// others. Mails that are not objects are left alone. Returns the
  /// Message-IDs of the rows added.
  Future<Set<String>> _adopt(
    imap.ImapClient client,
    String accountId,
    MailObjectFolder folder,
    List<_Indexed> indexed,
    Set<int> serverUids,
  ) async {
    final inserted = <String>{};
    final toInsert = <_Indexed>[];
    for (final entry in indexed) {
      if (entry.messageId.isEmpty) continue;
      if (folder == MailObjectFolder.data &&
          (entry.itemHmac == null || entry.schema != objectMailSchema)) {
        continue;
      }
      final existing = await _row(accountId, entry.messageId);
      if (existing == null) {
        if (toInsert.every((e) => e.messageId != entry.messageId)) {
          toInsert.add(entry);
        }
        continue;
      }
      final cached = int.tryParse(existing.serverId ?? '');
      // A second UID of the same version: a duplicate, expunged by a
      // foreground sync.
      if (cached != null && serverUids.contains(cached)) continue;
      await _confirm(accountId, existing.messageId, entry.uid);
    }
    final eager = [
      for (final e in toInsert)
        if (e.size <= mailObjectEagerBodyLimit) e.uid,
    ];
    final bodies = <int, Uint8List>{};
    for (var i = 0; i < eager.length; i += _fetchChunk) {
      bodies.addAll(
        await _fetchRaw(
          client,
          eager.sublist(i, math.min(i + _fetchChunk, eager.length)),
        ),
      );
    }
    for (final e in toInsert) {
      await _db.into(_db.mailObjects).insertOnConflictUpdate(
            MailObjectsCompanion.insert(
              accountId: accountId,
              folder: folder.name,
              messageId: e.messageId,
              itemHmac: Value(e.itemHmac),
              serverId: Value('${e.uid}'),
              sizeBytes: Value(e.size),
              payload: Value(bodies[e.uid]),
            ),
          );
      inserted.add(e.messageId);
    }
    return inserted;
  }

  /// The raw RFC 5322 bytes of [uids] of the selected folder, by UID.
  Future<Map<int, Uint8List>> _fetchRaw(
    imap.ImapClient client,
    List<int> uids,
  ) async {
    if (uids.isEmpty) return const {};
    final fetched = await client.uidFetchMessages(
      imap.MessageSequence.fromIds(uids, isUid: true),
      '(UID BODY.PEEK[])',
    );
    return {
      for (final msg in fetched.messages)
        if (msg.uid case final uid?)
          if (_rawBytes(msg) case final bytes?) uid: bytes,
    };
  }

  static Uint8List? _rawBytes(imap.MimeMessage msg) {
    final data = msg.mimeData;
    if (data is imap.BinaryMimeData) return data.data;
    if (data is imap.TextMimeData) return utf8.encode(data.text);
    return null;
  }

  /// A UIDVALIDITY change: every UID is stale. The index goes and the rows
  /// lose their UID; the rescan finds them again by Message-ID.
  Future<void> _forgetUids(String accountId, MailObjectFolder folder) async {
    await (_db.delete(_db.mailObjectUids)
          ..where(
            (t) => t.accountId.equals(accountId) & t.folder.equals(folder.name),
          ))
        .go();
    await (_db.update(_db.mailObjects)
          ..where(
            (t) => t.accountId.equals(accountId) & t.folder.equals(folder.name),
          ))
        .write(const MailObjectsCompanion(serverId: Value(null)));
  }

  /// Mails gone from the server. A superseded version (or one no key opens
  /// here) is dropped; a head, and a key mail, is uploaded again from the
  /// local copy, never deleted (5.4, 4.3). Rows without a UID that a full
  /// listing did not find count as vanished too.
  Future<void> _handleVanished(
    String accountId,
    MailObjectFolder folder,
    List<MailObjectUidRow> vanished,
  ) async {
    final gone = <MailObjectRow>[];
    for (final entry in vanished) {
      await (_db.delete(_db.mailObjectUids)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.folder.equals(folder.name) &
                  t.uid.equals(entry.uid),
            ))
          .go();
      final row = await _row(accountId, entry.messageId);
      if (row == null || row.serverId != '${entry.uid}') continue;
      gone.add(row);
    }
    gone.addAll(
      await (_db.select(_db.mailObjects)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.folder.equals(folder.name) &
                  t.serverId.isNull() &
                  t.pendingUpload.equals(false) &
                  t.pendingDelete.equals(false),
            ))
          .get(),
    );
    for (final row in gone) {
      final keep = !row.pendingDelete &&
          (folder == MailObjectFolder.keys || row.versionId != null);
      if (!keep) {
        await _dropRow(accountId, row.messageId);
        continue;
      }
      await (_db.update(_db.mailObjects)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.messageId.equals(row.messageId),
            ))
          .write(
        const MailObjectsCompanion(
          serverId: Value(null),
          pendingUpload: Value(true),
        ),
      );
      unawaited(
        _appLogger?.warn(
          'mos.vanished_reupload',
          'An encrypted object vanished from the server without a '
              'tombstone; it is uploaded again from the local copy',
          accountId: accountId,
          data: {'folder': folder.name, 'messageId': row.messageId},
        ),
      );
    }
  }

  /// The folder is gone on the server while rows exist: they all lose
  /// their UID and are uploaded again (the folder is made again by the next
  /// foreground push). Superseded rows, and rows whose body was never
  /// fetched, are dropped. Local data is never deleted for a missing
  /// folder.
  Future<void> _folderGone(
    String accountId,
    MailObjectFolder folder,
    String path,
  ) async {
    await _forgetUids(accountId, folder);
    await _clearCheckpoint(accountId, folder);
    var reupload = 0;
    for (final row in await _rows(accountId, folder)) {
      if (row.pendingDelete || row.payload == null) {
        await _dropRow(accountId, row.messageId);
        continue;
      }
      reupload++;
      await (_db.update(_db.mailObjects)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.messageId.equals(row.messageId),
            ))
          .write(const MailObjectsCompanion(pendingUpload: Value(true)));
    }
    unawaited(
      _appLogger?.warn(
        'mos.folder_missing_reupload',
        'An encrypted-object folder is missing on the server; it is made '
            'again and the local objects are uploaded again',
        accountId: accountId,
        data: {'folder': folder.name, 'path': path, 'reupload': reupload},
      ),
    );
  }

  // ── Open and merge ───────────────────────────────────────────────────────

  /// Opens the data rows no key opened so far ([only]: just these) and
  /// merges their items.
  Future<void> _openPending(String accountId, {Set<String>? only}) async {
    if (only != null && only.isEmpty) return;
    final rows = await (_db.select(_db.mailObjects)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.folder.equals(MailObjectFolder.data.name) &
                t.versionId.isNull() &
                t.payload.isNotNull(),
          ))
        .get();
    final incoming = <String, Map<String, InnerObject>>{};
    for (final row in rows) {
      if (only != null && !only.contains(row.messageId)) continue;
      final hmac = row.itemHmac;
      if (hmac == null) continue;
      final object = await _openPayload(accountId, row.payload!);
      if (object == null) continue;
      (incoming[hmac] ??= {})[row.messageId] = object;
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
    for (final row in await _itemRows(accountId, itemHmac)) {
      final object = incoming[row.messageId];
      if (object != null) {
        objects[row.messageId] = object;
        fresh.add(await ObjectVersion.of(object, ref: row.messageId));
        continue;
      }
      if (row.versionId == null || row.payload == null) continue;
      final opened = await _openPayload(accountId, row.payload!);
      if (opened == null) continue;
      objects[row.messageId] = opened;
      known.add(await ObjectVersion.of(opened, ref: row.messageId));
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
    await _db.transaction(() async {
      for (final ref in objects.keys) {
        final messageId = ref;
        if (ignored.contains(messageId)) {
          await _dropRow(accountId, messageId);
          continue;
        }
        final head = objects[messageId]!.head;
        final isHead = heads.contains(messageId);
        await (_db.update(_db.mailObjects)
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

  // ── Push (foreground only) ────────────────────────────────────────────────

  Future<void> _push(
    imap.ImapClient client,
    String accountId,
    MailObjectFolder folder,
    _Layout layout, {
    required bool exists,
  }) async {
    final pending = await (_db.select(_db.mailObjects)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.folder.equals(folder.name) &
                (t.pendingUpload.equals(true) | t.pendingDelete.equals(true)),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.versionId)]))
        .get();
    final duplicates =
        exists ? await _duplicateUids(accountId, folder) : const <int>[];
    if (pending.isEmpty && duplicates.isEmpty) return;
    final uploads = [
      for (final r in pending)
        if (r.pendingUpload && !r.pendingDelete && r.payload != null) r,
    ];
    final deletes = [
      for (final r in pending)
        if (r.pendingDelete) r,
    ];
    final path = layout.path(folder);
    if (!exists) {
      if (uploads.isEmpty) {
        // No folder: no server copy left to delete.
        for (final row in deletes) {
          await _dropRow(accountId, row.messageId);
        }
        return;
      }
      await _mailboxes.registerAppDataFolders(
        accountId,
        await ensureMailObjectFolder(
          client,
          folder,
          prefix: layout.prefix,
          separator: layout.separator,
        ),
      );
    }
    final box = await client.selectMailboxByPath(path);
    final uidValidity = box.uidValidity ?? 0;
    for (final row in uploads) {
      try {
        await _upload(client, accountId, folder, path, uidValidity, row);
      } catch (e) {
        if (isImapConnectionLost(e)) rethrow;
        _logPushFailed(accountId, row, 'upload', e);
      }
    }
    final waiting = {
      for (final r in uploads)
        if (await _stillPending(accountId, r.messageId)) r.itemHmac,
    };
    for (final row in deletes) {
      // Only once the version superseding it is confirmed.
      if (row.itemHmac != null && waiting.contains(row.itemHmac)) continue;
      try {
        final uids = await _serverUids(
          client,
          accountId,
          folder,
          uidValidity,
          row.messageId,
        );
        if (uids.isNotEmpty) {
          await _expunge(client, accountId, folder, path, uids, [
            row.messageId,
          ]);
        }
        await _dropRow(accountId, row.messageId);
      } catch (e) {
        if (isImapConnectionLost(e)) rethrow;
        _logPushFailed(accountId, row, 'delete', e);
      }
    }
    if (duplicates.isNotEmpty) {
      await _expunge(client, accountId, folder, path, duplicates.toList(), []);
    }
  }

  Future<bool> _stillPending(String accountId, String messageId) async =>
      (await _row(accountId, messageId))?.pendingUpload ?? false;

  /// APPENDs [row] unless the server has the version already (by its
  /// Message-ID, never the item HMAC), and records its UID.
  Future<void> _upload(
    imap.ImapClient client,
    String accountId,
    MailObjectFolder folder,
    String path,
    int uidValidity,
    MailObjectRow row,
  ) async {
    final existing = await _serverUids(
      client,
      accountId,
      folder,
      uidValidity,
      row.messageId,
    );
    if (existing.isNotEmpty) {
      await _confirm(
        accountId,
        row.messageId,
        existing.first,
        uidValidity: uidValidity,
      );
      return;
    }
    await _onStep?.call('append');
    final result = await client.appendMessageText(
      utf8.decode(row.payload!),
      flags: const [r'\Seen'],
      targetMailboxPath: path,
    );
    await _onStep?.call('appended');
    int? uid;
    try {
      uid = result.responseCodeAppendUid?.targetSequence.toList().firstOrNull;
    } catch (_) {
      // A malformed APPENDUID: confirm by Message-ID below.
    }
    if (uid == null) {
      // No UIDPLUS: find the copy by Message-ID, or, without a usable
      // SEARCH HEADER, by indexing the new UIDs.
      final found = await _serverUids(
        client,
        accountId,
        folder,
        uidValidity,
        row.messageId,
        scan: true,
      );
      uid = found.firstOrNull;
    }
    await _confirm(accountId, row.messageId, uid, uidValidity: uidValidity);
  }

  /// UIDs of the selected [folder] holding [messageId]: by SEARCH HEADER and
  /// by the index. With [scan], UIDs missing from the index are indexed
  /// first when the search found nothing.
  Future<List<int>> _serverUids(
    imap.ImapClient client,
    String accountId,
    MailObjectFolder folder,
    int uidValidity,
    String messageId, {
    bool scan = false,
  }) async {
    final uids = <int>{};
    for (final criteria in messageIdSearchCriteria(messageId)) {
      try {
        final found = await client.uidSearchMessages(searchCriteria: criteria);
        final hits = found.matchingSequence?.toList() ?? const <int>[];
        uids.addAll(hits);
        if (hits.isNotEmpty) break;
      } catch (e) {
        // A server refusing HEADER search: the index answers.
        if (isImapConnectionLost(e)) rethrow;
        break;
      }
    }
    if (uids.isEmpty && scan) {
      final serverUids = (await client.uidSearchMessages(searchCriteria: 'ALL'))
              .matchingSequence
              ?.toList() ??
          const <int>[];
      final known = {for (final r in await _index(accountId, folder)) r.uid};
      await _indexUids(client, accountId, folder, uidValidity, [
        for (final uid in serverUids)
          if (!known.contains(uid)) uid,
      ]);
    }
    for (final r in await _index(accountId, folder)) {
      if (r.messageId == messageId && r.uidValidity == uidValidity) {
        uids.add(r.uid);
      }
    }
    return uids.toList()..sort();
  }

  /// Deletes [uids] of the selected [folder] for good (Gmail: via Trash)
  /// and drops them from the index. On Gmail without a `\Trash` folder they
  /// stay on the server (harmless: the merge keeps them superseded).
  Future<void> _expunge(
    imap.ImapClient client,
    String accountId,
    MailObjectFolder folder,
    String path,
    List<int> uids,
    List<String> messageIds,
  ) async {
    if (isGmailImap(client)) {
      final done = await moveToTrashAndExpunge(
        client,
        uids,
        sourcePath: path,
        messageIds: messageIds,
      );
      if (!done) {
        unawaited(
          _appLogger?.warn(
            'mos.gmail_no_trash',
            'Gmail has no Trash folder: a superseded encrypted object stays '
                'on the server',
            accountId: accountId,
            data: {'folder': folder.name, 'uids': uids.length},
          ),
        );
        return;
      }
    } else {
      await deleteAndExpungeUids(client, uids);
    }
    await (_db.delete(_db.mailObjectUids)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.folder.equals(folder.name) &
                t.uid.isIn(uids),
          ))
        .go();
  }

  /// Extra UIDs of a version the index has more than once (the row keeps
  /// its own UID).
  Future<List<int>> _duplicateUids(
    String accountId,
    MailObjectFolder folder,
  ) async {
    final byId = <String, List<int>>{};
    for (final r in await _index(accountId, folder)) {
      if (r.messageId.isEmpty) continue;
      (byId[r.messageId] ??= []).add(r.uid);
    }
    final extra = <int>[];
    for (final MapEntry(key: messageId, value: uids) in byId.entries) {
      if (uids.length < 2) continue;
      final row = await _row(accountId, messageId);
      final keep = int.tryParse(row?.serverId ?? '') ?? (uids..sort()).first;
      extra.addAll(uids.where((u) => u != keep));
    }
    return extra;
  }

  /// Marks [messageId] as on the server under [uid] (null: APPEND OK, but
  /// the UID could not be learned; the next pull finds it).
  Future<void> _confirm(
    String accountId,
    String messageId,
    int? uid, {
    int? uidValidity,
  }) async {
    await (_db.update(_db.mailObjects)
          ..where(
            (t) =>
                t.accountId.equals(accountId) & t.messageId.equals(messageId),
          ))
        .write(
      MailObjectsCompanion(
        pendingUpload: const Value(false),
        serverId: Value(uid?.toString()),
      ),
    );
    final row = await _row(accountId, messageId);
    if (uid == null || uidValidity == null || row == null) return;
    await _db.into(_db.mailObjectUids).insertOnConflictUpdate(
          MailObjectUidsCompanion.insert(
            accountId: accountId,
            folder: row.folder,
            uidValidity: uidValidity,
            uid: uid,
            messageId: messageId,
            itemHmac: Value(row.itemHmac),
            sizeBytes: Value(row.sizeBytes),
          ),
        );
  }

  void _logPushFailed(
    String accountId,
    MailObjectRow row,
    String op,
    Object e,
  ) {
    unawaited(
      _appLogger?.warn(
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

  Future<MailObjectRow?> _row(String accountId, String messageId) =>
      (_db.select(_db.mailObjects)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) & t.messageId.equals(messageId),
            ))
          .getSingleOrNull();

  Future<List<MailObjectRow>> _rows(
    String accountId,
    MailObjectFolder folder,
  ) =>
      (_db.select(_db.mailObjects)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) & t.folder.equals(folder.name),
            ))
          .get();

  Future<List<MailObjectRow>> _itemRows(String accountId, String itemHmac) =>
      (_db.select(_db.mailObjects)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.folder.equals(MailObjectFolder.data.name) &
                  t.itemHmac.equals(itemHmac),
            ))
          .get();

  /// Whether [folder] has local rows ([onServer]: ones the server had).
  Future<bool> _hasRows(
    String accountId,
    MailObjectFolder folder, {
    bool onServer = false,
  }) async =>
      (await (_db.select(_db.mailObjects)
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

  Future<List<MailObjectUidRow>> _index(
    String accountId,
    MailObjectFolder folder,
  ) =>
      (_db.select(_db.mailObjectUids)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) & t.folder.equals(folder.name),
            ))
          .get();

  Future<void> _dropRow(String accountId, String messageId) =>
      (_db.delete(_db.mailObjects)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) & t.messageId.equals(messageId),
            ))
          .go();

  Future<VersionVector> _loadVv(String accountId, String itemHmac) async {
    final row = await (_db.select(_db.mailObjectClocks)
          ..where(
            (t) => t.accountId.equals(accountId) & t.itemHmac.equals(itemHmac),
          ))
        .getSingleOrNull();
    if (row == null) return const {};
    try {
      final json = jsonDecode(row.vvJson) as Map<String, dynamic>;
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
      _db.into(_db.mailObjectClocks).insertOnConflictUpdate(
            MailObjectClocksCompanion.insert(
              accountId: accountId,
              itemHmac: itemHmac,
              vvJson: jsonEncode({
                for (final MapEntry(:key, :value) in vv.entries)
                  key: value.encode(),
              }),
            ),
          );

  Future<_Checkpoint?> _loadCheckpoint(
    String accountId,
    MailObjectFolder folder,
  ) async {
    final row = await (_db.select(_db.syncStates)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.resourceType.equals(mailObjectCheckpointKey(folder)),
          ))
        .getSingleOrNull();
    if (row == null) return null;
    try {
      final json = jsonDecode(row.state) as Map<String, dynamic>;
      return (
        uidValidity: json['uidValidity'] as int,
        lastUid: json['lastUid'] as int,
        uidNext: json['uidNext'] as int?,
        messages: json['messages'] as int,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveCheckpoint(
    String accountId,
    MailObjectFolder folder,
    _Checkpoint checkpoint,
  ) =>
      _db.into(_db.syncStates).insertOnConflictUpdate(
            SyncStatesCompanion.insert(
              accountId: accountId,
              resourceType: mailObjectCheckpointKey(folder),
              state: jsonEncode({
                'uidValidity': checkpoint.uidValidity,
                'lastUid': checkpoint.lastUid,
                'uidNext': checkpoint.uidNext,
                'messages': checkpoint.messages,
              }),
              syncedAt: _now(),
            ),
          );

  Future<void> _clearCheckpoint(String accountId, MailObjectFolder folder) =>
      (_db.delete(_db.syncStates)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.resourceType.equals(mailObjectCheckpointKey(folder)),
            ))
          .go();

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
