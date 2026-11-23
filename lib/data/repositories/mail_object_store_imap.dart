import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:meta/meta.dart';

import 'package:sharedinbox/core/encrypted_objects/object_mail.dart';
import 'package:sharedinbox/core/models/account.dart' as account_model;
import 'package:sharedinbox/core/models/mail_object.dart';
import 'package:sharedinbox/core/repositories/mail_object_store.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:sharedinbox/data/imap/imap_errors.dart';
import 'package:sharedinbox/data/imap/imap_expunge.dart';
import 'package:sharedinbox/data/imap/imap_namespace.dart';
import 'package:sharedinbox/data/imap/mail_object_folders.dart';
import 'package:sharedinbox/data/imap/message_id_search.dart';
import 'package:sharedinbox/data/imap/missing_folder.dart';
import 'package:sharedinbox/data/repositories/mail_object_store_base.dart';
import 'package:sharedinbox/data/repositories/mailbox_state_writer.dart';

export 'package:sharedinbox/data/repositories/mail_object_store_base.dart'
    show mailObjectCheckpointKey, mailObjectEagerBodyLimit;

// The IMAP checkpoint of a folder (under [mailObjectCheckpointKey]):
// `{uidValidity, lastUid, uidNext, messages}`.

const _headerFetch = '(UID RFC822.SIZE BODY.PEEK[HEADER.FIELDS '
    '(MESSAGE-ID X-SHAREDINBOX-ITEM X-SHAREDINBOX-SCHEMA)])';
const _fetchChunk = 100;

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

/// [MailObjectStore] for IMAP accounts (#1370); JMAP accounts are served by
/// `MailObjectStoreJmap` (#1371).
///
/// One sync per account at a time. With `pushPending` false (the
/// WorkManager isolate) it only pulls: no APPEND, no expunge, no CREATE; a
/// vanished head is only marked for re-upload.
class MailObjectStoreImap extends MailObjectStoreBase {
  MailObjectStoreImap(
    super.db,
    super.accounts,
    super.mailboxes,
    super.storage, {
    ImapConnectFn imapConnect = connectImap,
    ImapNamespaceFn namespace = imapNamespaceFromServer,
    super.keyLookup,
    super.writeKey,
    super.keepVanishedKeyMail,
    super.appLogger,
    super.pushPending,
    super.now,
    @visibleForTesting super.onStep,
    super.projectors,
  })  : _imapConnect = imapConnect,
        _namespace = namespace;

  final ImapConnectFn _imapConnect;
  final ImapNamespaceFn _namespace;

  @override
  Future<Uint8List?> fetchRawBody(
    account_model.Account account,
    MailObject object,
  ) async {
    final uid = int.tryParse(object.serverId ?? '');
    if (uid == null) return null;
    final client = await _connect(account);
    try {
      final layout = await _layout(account.id, client);
      await client.selectMailboxByPath(layout.path(object.folder));
      return (await _fetchRaw(client, [uid]))[uid];
    } finally {
      await closeImapClient(client);
    }
  }

  // ── Sync ──────────────────────────────────────────────────────────────────

  Future<imap.ImapClient> _connect(account_model.Account account) async {
    final password = await accounts.getPassword(account.id);
    final username =
        account.username.isNotEmpty ? account.username : account.email;
    return _imapConnect(account, username, password);
  }

  Future<_Layout> _layout(String accountId, [imap.ImapClient? client]) async {
    final prefix = client == null
        ? await storedImapNamespacePrefix(db, accountId)
        : await imapNamespacePrefix(db, accountId, client, _namespace);
    final separator = await MailboxStateWriter(db).imapSeparator(accountId);
    return _Layout(prefix, separator);
  }

  @override
  Future<void> syncAccount(account_model.Account account) async {
    if (account.type != account_model.AccountType.imap) return;
    final accountId = account.id;
    final recorded = {
      for (final r in await (db.select(db.appDataFolders)
            ..where((t) => t.accountId.equals(accountId)))
          .get())
        r.path,
    };
    final stored = await _layout(accountId);
    final active = [
      for (final folder in MailObjectFolder.values)
        if (recorded.contains(stored.path(folder)) ||
            await hasRows(accountId, folder))
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
      await openPending(accountId, only: pulled.inserted);
    }
    if (pulled != null && pulled.trusted) {
      await _handleVanished(accountId, folder, pulled.vanished);
    }
    if (!pushEnabled) return;
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
      if (!await hasRows(accountId, folder, onServer: true)) return null;
      if (!await appFolderGone(
        client,
        path,
        e,
        accountId: accountId,
        event: 'mos.select_failed_kept',
        message: 'Could not open an encrypted-object folder; the server did '
            'not say NONEXISTENT and still lists it: the local objects are '
            'kept',
        appLogger: appLogger,
      )) {
        rethrow;
      }
      await folderGone(accountId, folder, path);
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
      await forgetServerIds(accountId, folder);
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
        await db.into(db.mailObjectUids).insertOnConflictUpdate(
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
      final existing = await row(accountId, entry.messageId);
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
      await db.into(db.mailObjects).insertOnConflictUpdate(
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

  /// A UIDVALIDITY change (or a folder gone): every UID is stale. The index
  /// goes and the rows lose their UID; the rescan finds them again by
  /// Message-ID.
  @override
  Future<void> forgetServerIds(
    String accountId,
    MailObjectFolder folder,
  ) async {
    await (db.delete(db.mailObjectUids)
          ..where(
            (t) => t.accountId.equals(accountId) & t.folder.equals(folder.name),
          ))
        .go();
    await super.forgetServerIds(accountId, folder);
  }

  /// Index rows whose UID is gone from the server. Rows without a UID that
  /// a full listing did not find count as vanished too ([markGone]).
  Future<void> _handleVanished(
    String accountId,
    MailObjectFolder folder,
    List<MailObjectUidRow> vanished,
  ) async {
    final gone = <MailObjectRow>[];
    for (final entry in vanished) {
      await (db.delete(db.mailObjectUids)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.folder.equals(folder.name) &
                  t.uid.equals(entry.uid),
            ))
          .go();
      final r = await row(accountId, entry.messageId);
      if (r == null || r.serverId != '${entry.uid}') continue;
      gone.add(r);
    }
    gone.addAll(await unlocatedRows(accountId, folder));
    await markGone(accountId, folder, gone);
  }

  // ── Push (foreground only) ────────────────────────────────────────────────

  Future<void> _push(
    imap.ImapClient client,
    String accountId,
    MailObjectFolder folder,
    _Layout layout, {
    required bool exists,
  }) async {
    final pending = await pendingRows(accountId, folder);
    final duplicates =
        exists ? await _duplicateUids(accountId, folder) : const <int>[];
    if (pending.isEmpty && duplicates.isEmpty) return;
    final (:uploads, :deletes) = splitPending(pending);
    final path = layout.path(folder);
    if (!exists) {
      if (uploads.isEmpty) {
        // No folder: no server copy left to delete.
        for (final row in deletes) {
          await dropRow(accountId, row.messageId);
        }
        return;
      }
      await mailboxes.registerAppDataFolders(
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
        logPushFailed(accountId, row, 'upload', e);
      }
    }
    // Only once the version superseding it, or the pack covering it, is
    // confirmed.
    for (final row in await deletableNow(accountId, uploads, deletes)) {
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
        await dropRow(accountId, row.messageId);
      } catch (e) {
        if (isImapConnectionLost(e)) rethrow;
        logPushFailed(accountId, row, 'delete', e);
      }
    }
    if (duplicates.isNotEmpty) {
      await _expunge(client, accountId, folder, path, duplicates.toList(), []);
    }
  }

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
    await onStep?.call('append');
    final result = await client.appendMessageText(
      utf8.decode(row.payload!),
      flags: const [r'\Seen'],
      targetMailboxPath: path,
    );
    await onStep?.call('appended');
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
          appLogger?.warn(
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
    await (db.delete(db.mailObjectUids)
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
      final kept = await row(accountId, messageId);
      final keep = int.tryParse(kept?.serverId ?? '') ?? (uids..sort()).first;
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
    await markConfirmed(accountId, messageId, uid?.toString());
    final confirmed = await row(accountId, messageId);
    if (uid == null || uidValidity == null || confirmed == null) return;
    await db.into(db.mailObjectUids).insertOnConflictUpdate(
          MailObjectUidsCompanion.insert(
            accountId: accountId,
            folder: confirmed.folder,
            uidValidity: uidValidity,
            uid: uid,
            messageId: messageId,
            itemHmac: Value(confirmed.itemHmac),
            sizeBytes: Value(confirmed.sizeBytes),
          ),
        );
  }

  Future<List<MailObjectUidRow>> _index(
    String accountId,
    MailObjectFolder folder,
  ) =>
      (db.select(db.mailObjectUids)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) & t.folder.equals(folder.name),
            ))
          .get();

  Future<_Checkpoint?> _loadCheckpoint(
    String accountId,
    MailObjectFolder folder,
  ) async {
    final json = await loadCheckpointJson(accountId, folder);
    if (json == null) return null;
    try {
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
      saveCheckpointJson(accountId, folder, {
        'uidValidity': checkpoint.uidValidity,
        'lastUid': checkpoint.lastUid,
        'uidNext': checkpoint.uidNext,
        'messages': checkpoint.messages,
      });
}
