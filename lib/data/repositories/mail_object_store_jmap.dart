import 'dart:async';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'package:sharedinbox/core/encrypted_objects/envelope.dart';
import 'package:sharedinbox/core/encrypted_objects/object_mail.dart';
import 'package:sharedinbox/core/models/account.dart' as account_model;
import 'package:sharedinbox/core/models/mail_object.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/imap/mail_object_folders.dart'
    show mailObjectFolderName;
import 'package:sharedinbox/data/jmap/jmap_client.dart';
import 'package:sharedinbox/data/repositories/mail_object_store_base.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart'
    show appDataRootName;

/// [SyncStates.resourceType] of the cached `maxSizeUpload` of a JMAP
/// account: `{maxSizeUpload}` (null when the server does not say).
const mailObjectMaxSizeUploadKey = 'mos:maxSizeUpload';

/// Bytes of an object mail around its base64 blob (headers, notice, MIME
/// boundaries), rounded up generously.
const _mailOverhead = 1024;

/// The largest envelope whose object mail fits into [maxMailBytes]: base64
/// in 76-char lines turns 57 bytes into 78.
int mailObjectEnvelopeLimit(int maxMailBytes) => math.min(
      maxEnvelopeBytes,
      math.max(0, (maxMailBytes - _mailOverhead) * 57 ~/ 78),
    );

const _queryPage = 500;
const _getChunk = 100;

/// Method errors after which a full listing replaces the incremental pull.
/// Stalwart answers a state it cannot parse with `invalidArguments`; the
/// listing stores fresh states, so that recovers too.
const _resyncErrors = {
  'cannotCalculateChanges',
  'invalidArguments',
  'tooManyChanges',
  'unsupportedFilter',
  'unsupportedSort',
};

const _headerProperties = [
  'id',
  'blobId',
  'size',
  'messageId',
  'header:$itemHeader:asText',
  'header:$schemaHeader:asText',
];

/// A method-level error answer (RFC 8620 §3.6.2).
class _MethodError extends JmapException {
  _MethodError(String method, this.type) : super('$method error: $type');

  final String? type;
}

/// One email as its header properties name it.
typedef _Entry = ({
  String id,
  String? blobId,
  String messageId,
  String? itemHmac,
  String? schema,
  int size,
});

/// The checkpoint of one folder: the mailbox it was taken of, and the
/// `Email/query` and `Email/changes` states.
typedef _Checkpoint = ({
  String mailboxId,
  String queryState,
  String emailState,
});

/// The mailbox ids of `SharedInbox` and its children on one account.
class _Layout {
  _Layout(this.rootId, this.ids);

  String? rootId;
  final Map<MailObjectFolder, String> ids;
}

/// [MailObjectStore] for JMAP accounts (#1371): the same object mails as on
/// IMAP, uploaded as a blob and `Email/import`ed. The mail's JMAP id is
/// [MailObject.serverId].
///
/// The checkpoint of a folder (under [mailObjectCheckpointKey]) is
/// `{mailboxId, queryState, emailState}`: a pull asks `Email/queryChanges`
/// and `Email/changes` since then, or lists the mailbox again when the
/// server cannot say. A superseded version is destroyed in its own
/// `Email/set`, never in the request that imports its successor, and only
/// once that import was confirmed (5.4). With `pushPending` false (the
/// WorkManager isolate) it only pulls: no upload, no `Email/set`, no
/// `Mailbox/set`.
class MailObjectStoreJmap extends MailObjectStoreBase {
  MailObjectStoreJmap(
    super.db,
    super.accounts,
    super.mailboxes,
    super.storage, {
    http.Client? httpClient,
    super.keyLookup,
    super.writeKey,
    super.appLogger,
    super.pushPending,
    super.now,
    @visibleForTesting super.onStep,
  }) : _http = httpClient ?? http.Client();

  final http.Client _http;

  /// Extra emails of a version seen by the running pull, by
  /// `accountId/folder`; destroyed by the push that follows.
  final Map<String, Set<String>> _duplicates = {};

  Future<JmapClient?> _connect(account_model.Account account) async =>
      JmapClient.connectAccount(
        httpClient: _http,
        account: account,
        password: await accounts.getPassword(account.id),
      );

  // ── Size ──────────────────────────────────────────────────────────────────

  @override
  Future<int> maxEnvelopeBytesFor(String accountId) async {
    final cached = await loadState(accountId, mailObjectMaxSizeUploadKey);
    final max = cached?['maxSizeUpload'];
    if (max is! int) return maxEnvelopeBytes;
    return mailObjectEnvelopeLimit(max);
  }

  Future<void> _cacheMaxSizeUpload(String accountId, JmapClient jmap) async {
    final cached = await loadState(accountId, mailObjectMaxSizeUploadKey);
    if (cached != null && cached['maxSizeUpload'] == jmap.maxSizeUpload) {
      return;
    }
    await saveState(accountId, mailObjectMaxSizeUploadKey, {
      'maxSizeUpload': jmap.maxSizeUpload,
    });
  }

  // ── Bodies ────────────────────────────────────────────────────────────────

  @override
  Future<Uint8List?> fetchRawBody(
    account_model.Account account,
    MailObject object,
  ) async {
    final jmap = await _connect(account);
    if (jmap == null) return null;
    final args = _args(
      await jmap.call([
        [
          'Email/get',
          {
            'accountId': jmap.accountId,
            'ids': [object.serverId],
            'properties': ['id', 'blobId'],
          },
          'g',
        ],
      ]),
      'g',
      'Email/get',
    );
    final list = args['list'] as List? ?? const [];
    if (list.isEmpty) return null;
    final blobId = (list.first as Map<String, dynamic>)['blobId'] as String?;
    if (blobId == null) return null;
    return _download(jmap, blobId);
  }

  Future<Uint8List> _download(JmapClient jmap, String blobId) =>
      jmap.downloadBlob(blobId, name: 'object.eml', type: 'message/rfc822');

  // ── Sync ──────────────────────────────────────────────────────────────────

  @override
  Future<void> syncAccount(account_model.Account account) async {
    if (account.type != account_model.AccountType.jmap) return;
    final accountId = account.id;
    final recorded = await (db.select(db.appDataFolders)
          ..where((t) => t.accountId.equals(accountId))
          ..limit(1))
        .getSingleOrNull();
    final local = [
      for (final folder in MailObjectFolder.values)
        if (await hasRows(accountId, folder)) folder,
    ];
    // No folder of ours and nothing to upload: no connection, no folder.
    if (recorded == null && local.isEmpty) return;
    final jmap = await _connect(account);
    if (jmap == null) return;
    await _cacheMaxSizeUpload(accountId, jmap);
    final layout = await _layoutOf(jmap);
    final rootId = layout.rootId;
    if (rootId != null) {
      await mailboxes.registerAppDataFolders(
        accountId,
        [rootId, ...layout.ids.values],
      );
    }
    for (final folder in MailObjectFolder.values) {
      await _syncFolder(jmap, accountId, folder, layout);
    }
  }

  Future<_Layout> _layoutOf(JmapClient jmap) async {
    final args = _args(
      await jmap.call([
        [
          'Mailbox/get',
          {
            'accountId': jmap.accountId,
            'ids': null,
            'properties': ['id', 'name', 'parentId', 'role'],
          },
          'm',
        ],
      ]),
      'm',
      'Mailbox/get',
    );
    final boxes = [
      for (final b in args['list'] as List? ?? const [])
        b as Map<String, dynamic>,
    ];
    final root = boxes
        .where(
          (b) =>
              b['parentId'] == null &&
              b['role'] == null &&
              b['name'] == appDataRootName,
        )
        .firstOrNull;
    final rootId = root?['id'] as String?;
    if (rootId == null) return _Layout(null, {});
    return _Layout(rootId, {
      for (final folder in MailObjectFolder.values)
        if (boxes
                .where(
                  (b) =>
                      b['parentId'] == rootId &&
                      b['name'] == mailObjectFolderName(folder),
                )
                .firstOrNull
            case final box?)
          folder: box['id'] as String,
    });
  }

  Future<void> _syncFolder(
    JmapClient jmap,
    String accountId,
    MailObjectFolder folder,
    _Layout layout,
  ) async {
    _duplicates.remove(_key(accountId, folder));
    final mailboxId = layout.ids[folder];
    if (mailboxId == null) {
      // Nothing the server had: nothing to protect (a first upload makes
      // the mailbox in the push).
      if (await hasRows(accountId, folder, onServer: true)) {
        await folderGone(
          accountId,
          folder,
          '$appDataRootName/${mailObjectFolderName(folder)}',
        );
      }
    } else {
      final pulled = await _pull(jmap, accountId, folder, mailboxId);
      if (folder == MailObjectFolder.data) {
        await openPending(accountId, only: pulled.inserted);
      }
      await markGone(accountId, folder, pulled.gone);
    }
    if (!pushEnabled) return;
    await _push(jmap, accountId, folder, layout);
  }

  static String _key(String accountId, MailObjectFolder folder) =>
      '$accountId/${folder.name}';

  /// Pulls [folder] (mailbox [mailboxId]). [inserted] are the Message-IDs
  /// of the rows it added, [gone] the rows whose mail is no longer there.
  Future<({Set<String> inserted, List<MailObjectRow> gone})> _pull(
    JmapClient jmap,
    String accountId,
    MailObjectFolder folder,
    String mailboxId,
  ) async {
    final checkpoint = await _loadCheckpoint(accountId, folder);
    if (checkpoint != null && checkpoint.mailboxId == mailboxId) {
      try {
        return await _pullChanges(jmap, accountId, folder, checkpoint);
      } on _MethodError catch (e) {
        if (!_resyncErrors.contains(e.type)) rethrow;
        unawaited(
          appLogger?.info(
            'mos.full_resync',
            'The server cannot list the changes of an encrypted-object '
                'folder; it is listed again',
            accountId: accountId,
            data: {'folder': folder.name, 'error': e.type},
          ),
        );
      }
    }
    return _pullAll(jmap, accountId, folder, mailboxId);
  }

  /// Lists the whole mailbox (no checkpoint, another mailbox, or the server
  /// cannot list the changes). Rows the listing does not hold are gone;
  /// rows without an id are found again by Message-ID.
  Future<({Set<String> inserted, List<MailObjectRow> gone})> _pullAll(
    JmapClient jmap,
    String accountId,
    MailObjectFolder folder,
    String mailboxId,
  ) async {
    final ids = <String>[];
    String? emailState;
    String? queryState;
    while (true) {
      final responses = await jmap.call([
        // The state before the listing: changes after it are asked next time.
        if (emailState == null)
          [
            'Email/get',
            {'accountId': jmap.accountId, 'ids': <String>[]},
            'g',
          ],
        [
          'Email/query',
          {
            'accountId': jmap.accountId,
            'filter': {'inMailbox': mailboxId},
            'position': ids.length,
            'limit': _queryPage,
            'calculateTotal': true,
          },
          'q',
        ],
      ]);
      emailState ??= _args(responses, 'g', 'Email/get')['state'] as String?;
      final query = _args(responses, 'q', 'Email/query');
      queryState ??= query['queryState'] as String?;
      final page = List<String>.from(query['ids'] as List? ?? const []);
      ids.addAll(page);
      final total = query['total'] as int?;
      if (page.isEmpty || total == null || ids.length >= total) break;
    }
    final listed = ids.toSet();
    final inserted = await _adopt(
      jmap,
      accountId,
      folder,
      await _headers(jmap, ids),
      present: listed.contains,
    );
    final gone = [
      for (final r in await rows(accountId, folder))
        if (r.serverId case final id? when !listed.contains(id)) r,
      ...await unlocatedRows(accountId, folder),
    ];
    await _saveCheckpoint(
      accountId,
      folder,
      (
        mailboxId: mailboxId,
        queryState: queryState ?? '',
        emailState: emailState ?? '',
      ),
    );
    return (inserted: inserted, gone: gone);
  }

  /// Applies what changed in [checkpoint]'s mailbox since it was taken.
  /// Throws [_MethodError] when the server cannot say.
  Future<({Set<String> inserted, List<MailObjectRow> gone})> _pullChanges(
    JmapClient jmap,
    String accountId,
    MailObjectFolder folder,
    _Checkpoint checkpoint,
  ) async {
    final responses = await jmap.call([
      [
        'Email/queryChanges',
        {
          'accountId': jmap.accountId,
          'filter': {'inMailbox': checkpoint.mailboxId},
          'sinceQueryState': checkpoint.queryState,
        },
        'qc',
      ],
      [
        'Email/changes',
        {'accountId': jmap.accountId, 'sinceState': checkpoint.emailState},
        'c',
      ],
    ]);
    final query = _args(responses, 'qc', 'Email/queryChanges');
    var changes = _args(responses, 'c', 'Email/changes');
    final destroyed = <String>{};
    while (true) {
      destroyed.addAll(List<String>.from(changes['destroyed'] as List? ?? []));
      if (changes['hasMoreChanges'] != true) break;
      changes = _args(
        await jmap.call([
          [
            'Email/changes',
            {
              'accountId': jmap.accountId,
              'sinceState': changes['newState'],
            },
            'c',
          ],
        ]),
        'c',
        'Email/changes',
      );
    }
    final added = [
      for (final a in query['added'] as List? ?? const [])
        (a as Map<String, dynamic>)['id'] as String,
    ];
    // RFC 8620 §5.6 lets a server list a still-matching id in `removed` as
    // long as it lists it in `added` again.
    final goneIds = {
      ...destroyed,
      for (final id in query['removed'] as List? ?? const [])
        if (!added.contains(id)) id as String,
    };
    final inserted = await _adopt(
      jmap,
      accountId,
      folder,
      await _headers(jmap, added),
      present: (id) => !goneIds.contains(id),
    );
    final gone = goneIds.isEmpty
        ? const <MailObjectRow>[]
        : await (db.select(db.mailObjects)
              ..where(
                (t) =>
                    t.accountId.equals(accountId) &
                    t.folder.equals(folder.name) &
                    t.serverId.isIn(goneIds),
              ))
            .get();
    await _saveCheckpoint(
      accountId,
      folder,
      (
        mailboxId: checkpoint.mailboxId,
        queryState: query['newQueryState'] as String? ?? '',
        emailState: changes['newState'] as String? ?? '',
      ),
    );
    return (inserted: inserted, gone: gone);
  }

  /// The header properties of [ids], in chunks.
  Future<List<_Entry>> _headers(JmapClient jmap, List<String> ids) async {
    final out = <_Entry>[];
    for (var i = 0; i < ids.length; i += _getChunk) {
      final args = _args(
        await jmap.call([
          [
            'Email/get',
            {
              'accountId': jmap.accountId,
              'ids': ids.sublist(i, math.min(i + _getChunk, ids.length)),
              'properties': _headerProperties,
            },
            'g',
          ],
        ]),
        'g',
        'Email/get',
      );
      for (final e in args['list'] as List? ?? const []) {
        final m = e as Map<String, dynamic>;
        out.add(
          (
            id: m['id'] as String,
            blobId: m['blobId'] as String?,
            messageId: _messageIdOf(m),
            itemHmac: (m['header:$itemHeader:asText'] as String?)?.trim(),
            schema: (m['header:$schemaHeader:asText'] as String?)?.trim(),
            size: m['size'] as int? ?? 0,
          ),
        );
      }
    }
    return out;
  }

  /// The Message-ID of email [m] as the rows hold it (`<…>`), or `''`.
  static String _messageIdOf(Map<String, dynamic> m) {
    final ids = m['messageId'] as List?;
    if (ids == null || ids.isEmpty) return '';
    return '<${ids.first}>';
  }

  /// Matches the new emails to local rows by Message-ID (a version uploaded
  /// before, or listed again) and stores the others. A second email of a
  /// version whose row holds an id still [present] is a duplicate, destroyed
  /// by a foreground push. Mails that are not objects are left alone.
  /// Returns the Message-IDs of the rows added.
  Future<Set<String>> _adopt(
    JmapClient jmap,
    String accountId,
    MailObjectFolder folder,
    List<_Entry> entries, {
    required bool Function(String id) present,
  }) async {
    final duplicates = _duplicates[_key(accountId, folder)] ??= {};
    final toInsert = <_Entry>[];
    for (final entry in entries) {
      if (entry.messageId.isEmpty) continue;
      if (folder == MailObjectFolder.data &&
          (entry.itemHmac == null || entry.schema != objectMailSchema)) {
        continue;
      }
      final existing = await row(accountId, entry.messageId);
      if (existing == null) {
        if (toInsert.any((e) => e.messageId == entry.messageId)) {
          duplicates.add(entry.id);
          continue;
        }
        toInsert.add(entry);
        continue;
      }
      final cached = existing.serverId;
      if (cached == entry.id) continue;
      if (cached != null && present(cached)) {
        duplicates.add(entry.id);
        continue;
      }
      await markConfirmed(accountId, existing.messageId, entry.id);
    }
    final inserted = <String>{};
    for (final e in toInsert) {
      final blobId = e.blobId;
      final eager = blobId != null && e.size <= mailObjectEagerBodyLimit;
      await db.into(db.mailObjects).insertOnConflictUpdate(
            MailObjectsCompanion.insert(
              accountId: accountId,
              folder: folder.name,
              messageId: e.messageId,
              itemHmac: Value(e.itemHmac),
              serverId: Value(e.id),
              sizeBytes: Value(e.size),
              payload: Value(eager ? await _download(jmap, blobId) : null),
            ),
          );
      inserted.add(e.messageId);
    }
    return inserted;
  }

  // ── Push (foreground only) ────────────────────────────────────────────────

  Future<void> _push(
    JmapClient jmap,
    String accountId,
    MailObjectFolder folder,
    _Layout layout,
  ) async {
    final pending = await pendingRows(accountId, folder);
    final duplicates =
        _duplicates.remove(_key(accountId, folder)) ?? const <String>{};
    if (pending.isEmpty && duplicates.isEmpty) return;
    final (:uploads, :deletes) = splitPending(pending);
    var mailboxId = layout.ids[folder];
    if (mailboxId == null) {
      if (uploads.isEmpty) {
        // No mailbox: no server copy left to delete.
        for (final r in deletes) {
          await dropRow(accountId, r.messageId);
        }
        return;
      }
      mailboxId = await _createMailbox(jmap, accountId, folder, layout);
    }
    final limit = jmap.maxSizeUpload;
    for (final r in uploads) {
      if (limit != null && r.payload!.length > limit) {
        // Written before the limit was known: stays local, not retried
        // against a server that refuses it.
        unawaited(
          appLogger?.warn(
            'mos.push.too_large',
            'An encrypted object is larger than the server accepts; it '
                'stays on this device only',
            accountId: accountId,
            data: {
              'folder': folder.name,
              'messageId': r.messageId,
              'size': r.payload!.length,
              'maxSizeUpload': limit,
            },
          ),
        );
        continue;
      }
      try {
        await _upload(jmap, accountId, mailboxId, r);
      } catch (e) {
        if (isJmapNetworkError(e)) rethrow;
        logPushFailed(accountId, r, 'upload', e);
      }
    }
    final waiting = {
      for (final r in uploads)
        if (await stillPending(accountId, r.messageId)) r.itemHmac,
    };
    final destroy = <MailObjectRow, Set<String>>{};
    for (final r in deletes) {
      // Only once the version superseding it is confirmed.
      if (r.itemHmac != null && waiting.contains(r.itemHmac)) continue;
      try {
        destroy[r] = {
          if (r.serverId case final id?) id,
          ...await _serverIds(jmap, mailboxId, r.messageId),
        };
      } catch (e) {
        if (isJmapNetworkError(e)) rethrow;
        logPushFailed(accountId, r, 'delete', e);
      }
    }
    final ids = {...duplicates, for (final s in destroy.values) ...s};
    final Map<String, String?> failed;
    try {
      failed = ids.isEmpty ? const {} : await _destroy(jmap, ids);
    } catch (e) {
      if (isJmapNetworkError(e)) rethrow;
      for (final r in destroy.keys) {
        logPushFailed(accountId, r, 'delete', e);
      }
      return;
    }
    for (final MapEntry(key: r, value: serverIds) in destroy.entries) {
      final refused = serverIds.where(failed.containsKey).toList();
      if (refused.isNotEmpty) {
        logPushFailed(accountId, r, 'delete', failed[refused.first] ?? '');
        continue;
      }
      await dropRow(accountId, r.messageId);
    }
  }

  /// Destroys [ids] in an `Email/set` of its own. Returns the ids the
  /// server refused, with the error type; one it no longer has is done.
  Future<Map<String, String?>> _destroy(
    JmapClient jmap,
    Set<String> ids,
  ) async {
    await onStep?.call('destroy');
    final args = _args(
      await jmap.call([
        [
          'Email/set',
          {'accountId': jmap.accountId, 'destroy': ids.toList()},
          'd',
        ],
      ]),
      'd',
      'Email/set',
    );
    final notDestroyed =
        args['notDestroyed'] as Map<String, dynamic>? ?? const {};
    return {
      for (final MapEntry(:key, :value) in notDestroyed.entries)
        if ((value as Map<String, dynamic>?)?['type'] case final type
            when type != 'notFound')
          key: type as String?,
    };
  }

  /// Uploads [r] and imports it into [mailboxId] with `$seen`, unless the
  /// server has the version already (by its Message-ID, never the item
  /// HMAC), and records its id.
  Future<void> _upload(
    JmapClient jmap,
    String accountId,
    String mailboxId,
    MailObjectRow r,
  ) async {
    final existing = await _serverIds(jmap, mailboxId, r.messageId);
    if (existing.isNotEmpty) {
      await markConfirmed(accountId, r.messageId, existing.first);
      return;
    }
    await onStep?.call('import');
    final blobId = await jmap.uploadBlob(r.payload!, 'message/rfc822');
    final args = _args(
      await jmap.call([
        [
          'Email/import',
          {
            'accountId': jmap.accountId,
            'emails': {
              'c0': {
                'blobId': blobId,
                'mailboxIds': {mailboxId: true},
                'keywords': {r'$seen': true},
              },
            },
          },
          'i',
        ],
      ]),
      'i',
      'Email/import',
    );
    await onStep?.call('imported');
    final created = (args['created'] as Map<String, dynamic>?)?['c0'];
    if (created is Map<String, dynamic> && created['id'] is String) {
      await markConfirmed(accountId, r.messageId, created['id'] as String);
      return;
    }
    final error = (args['notCreated'] as Map<String, dynamic>?)?['c0'];
    final type = error is Map<String, dynamic> ? error['type'] : null;
    final existingId =
        error is Map<String, dynamic> ? error['existingId'] : null;
    if (type == 'alreadyExists' && existingId is String) {
      await markConfirmed(accountId, r.messageId, existingId);
      return;
    }
    throw JmapException('Email/import did not create the object: $type');
  }

  /// Ids of the emails in [mailboxId] whose Message-ID is [messageId]. The
  /// `header` filter only matches a substring (RFC 8621 §4.4.1), so every
  /// hit is checked. Empty when the server refuses the filter.
  Future<List<String>> _serverIds(
    JmapClient jmap,
    String mailboxId,
    String messageId,
  ) async {
    final bare = messageId.startsWith('<') && messageId.endsWith('>')
        ? messageId.substring(1, messageId.length - 1)
        : messageId;
    final responses = await jmap.call([
      [
        'Email/query',
        {
          'accountId': jmap.accountId,
          'filter': {
            'inMailbox': mailboxId,
            'header': ['Message-ID', bare],
          },
        },
        'q',
      ],
      [
        'Email/get',
        {
          'accountId': jmap.accountId,
          '#ids': {'resultOf': 'q', 'name': 'Email/query', 'path': '/ids'},
          'properties': ['id', 'messageId'],
        },
        'g',
      ],
    ]);
    final Map<String, dynamic> args;
    try {
      args = _args(responses, 'g', 'Email/get');
    } on _MethodError {
      return const [];
    }
    return [
      for (final e in args['list'] as List? ?? const [])
        if (_messageIdOf(e as Map<String, dynamic>) == messageId)
          e['id'] as String,
    ];
  }

  /// Creates `SharedInbox` (when missing) and [folder]'s mailbox under it,
  /// records both and returns the mailbox id.
  Future<String> _createMailbox(
    JmapClient jmap,
    String accountId,
    MailObjectFolder folder,
    _Layout layout,
  ) async {
    final rootId = layout.rootId ??
        await _createBox(jmap, appDataRootName, null) ??
        (await _layoutOf(jmap)).rootId;
    if (rootId == null) {
      throw JmapException('Mailbox/set did not create $appDataRootName');
    }
    layout.rootId = rootId;
    final name = mailObjectFolderName(folder);
    final id = await _createBox(jmap, name, rootId) ??
        (await _layoutOf(jmap)).ids[folder];
    if (id == null) {
      throw JmapException('Mailbox/set did not create $appDataRootName/$name');
    }
    layout.ids[folder] = id;
    await mailboxes.registerAppDataFolders(accountId, [rootId, id]);
    return id;
  }

  /// The id of a new mailbox [name] under [parentId]; null when the server
  /// did not create it (another device may have just done so).
  Future<String?> _createBox(
    JmapClient jmap,
    String name,
    String? parentId,
  ) async {
    final args = _args(
      await jmap.call([
        [
          'Mailbox/set',
          {
            'accountId': jmap.accountId,
            'create': {
              'b': {'name': name, 'parentId': parentId},
            },
          },
          's',
        ],
      ]),
      's',
      'Mailbox/set',
    );
    final created = (args['created'] as Map<String, dynamic>?)?['b'];
    return created is Map<String, dynamic> ? created['id'] as String? : null;
  }

  // ── Responses and checkpoint ──────────────────────────────────────────────

  /// The arguments of the response to call [callId]; throws [_MethodError]
  /// for an error answer.
  static Map<String, dynamic> _args(
    List<dynamic> responses,
    String callId,
    String method,
  ) {
    for (final r in responses) {
      final triple = r as List<dynamic>;
      if (triple.length < 3 || triple[2] != callId) continue;
      final args = triple[1] as Map<String, dynamic>;
      if (triple[0] == 'error') {
        throw _MethodError(method, args['type'] as String?);
      }
      return args;
    }
    throw JmapException('$method: no response');
  }

  Future<_Checkpoint?> _loadCheckpoint(
    String accountId,
    MailObjectFolder folder,
  ) async {
    final json = await loadCheckpointJson(accountId, folder);
    if (json == null) return null;
    final mailboxId = json['mailboxId'];
    final queryState = json['queryState'];
    final emailState = json['emailState'];
    // An empty state is one the server did not give: list again.
    if (mailboxId is! String ||
        queryState is! String ||
        emailState is! String ||
        queryState.isEmpty ||
        emailState.isEmpty) {
      return null;
    }
    return (
      mailboxId: mailboxId,
      queryState: queryState,
      emailState: emailState,
    );
  }

  Future<void> _saveCheckpoint(
    String accountId,
    MailObjectFolder folder,
    _Checkpoint checkpoint,
  ) =>
      saveCheckpointJson(accountId, folder, {
        'mailboxId': checkpoint.mailboxId,
        'queryState': checkpoint.queryState,
        'emailState': checkpoint.emailState,
      });
}
