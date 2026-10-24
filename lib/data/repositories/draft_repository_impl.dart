import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:sharedinbox/core/models/account.dart' as account_model;
import 'package:sharedinbox/core/models/draft.dart';
import 'package:sharedinbox/core/models/email.dart' as model;
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/draft_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/core/utils/mail_header_encode.dart';
import 'package:sharedinbox/core/utils/mime_filename.dart';
import 'package:sharedinbox/core/utils/recipient_check.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/imap/header_mail_address.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:sharedinbox/data/imap/mailbox_path_codec.dart';
import 'package:sharedinbox/data/jmap/jmap_client.dart';
import 'package:sharedinbox/data/storage/attachment_store.dart';

const _draftsFolder = 'Drafts';

class DraftRepositoryImpl extends DraftRepository {
  DraftRepositoryImpl(
    this._db,
    this._accounts, {
    ImapConnectFn? imapConnect,
    http.Client? httpClient,
    AppLogger? appLogger,
    AttachmentStore? attachmentStore,
  })  : _imapConnect = imapConnect,
        _httpClient = httpClient,
        _appLogger = appLogger,
        _files =
            attachmentStore ?? AttachmentStore.appSupport('draft_attachments');

  final AppDatabase _db;
  final AccountRepository _accounts;
  final ImapConnectFn? _imapConnect;
  final http.Client? _httpClient;
  final AppLogger? _appLogger;

  /// The drafts' own copies of their attachment files, one folder per draft.
  final AttachmentStore _files;

  /// The last [writeDraft] per draft id; the next one waits for it. Two saves
  /// of one draft (an auto-save and the flush when compose closes) would
  /// otherwise each copy the files and delete the other's copies.
  final Map<int, Future<void>> _writeTails = {};

  Future<T> _serialized<T>(int id, Future<T> Function() body) {
    final previous = _writeTails[id] ?? Future<void>.value();
    final run = previous.then((_) => body());
    final tail = run.then<void>((_) {}, onError: (Object _) {});
    _writeTails[id] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_writeTails[id], tail)) {
          unawaited(_writeTails.remove(id));
        }
      }),
    );
    return run;
  }

  @override
  Future<SavedDraft> writeDraft(DraftInput input) {
    final id = input.id;
    if (id == null) return _insertDraft(input);
    return _serialized(id, () => _updateDraft(id, input));
  }

  Future<SavedDraft> _updateDraft(int id, DraftInput input) async {
    final DraftInput(
      :accountId,
      :replyToEmailId,
      :toText,
      :ccText,
      :bccText,
      :subjectText,
      :bodyText,
      :attachments,
    ) = input;
    final now = DateTime.now();
    final old = await (_db.select(_db.drafts)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (old == null) {
      // Deleted meanwhile (sent, discarded, or gone from the server): there
      // is no row to update, and files without a row would be orphans.
      return SavedDraft(
        id: id,
        accountId: accountId,
        replyToEmailId: replyToEmailId,
        toText: toText,
        ccText: ccText,
        bccText: bccText,
        subjectText: subjectText,
        bodyText: bodyText,
        updatedAt: now,
        attachments: attachments,
      );
    }
    final stored = attachments.isEmpty && old.attachmentsJson == '[]'
        ? attachments
        : await _files.keep(id, attachments);
    await _db.transaction(() async {
      // Read again in the transaction: a push finishing meanwhile may have
      // stored a new server id, which the tombstone must not miss.
      final fresh = await (_db.select(_db.drafts)
            ..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      // The server ids belong to the old account's mailbox. Kept across a
      // switch of the From account, the next push would expunge that UID
      // from the new account's Drafts folder — someone else's draft.
      final switched = fresh != null && fresh.accountId != accountId;
      if (switched) await _tombstoneServerCopy(fresh);
      await (_db.update(_db.drafts)..where((t) => t.id.equals(id))).write(
        DraftsCompanion(
          accountId: Value(accountId),
          replyToEmailId: Value(replyToEmailId),
          toText: Value(toText),
          ccText: Value(ccText),
          bccText: Value(bccText),
          subjectText: Value(subjectText),
          bodyText: Value(bodyText),
          updatedAt: Value(now),
          dirty: const Value(true),
          attachmentsJson: Value(encodeDraftAttachments(stored)),
          imapServerId: switched ? const Value(null) : const Value.absent(),
          jmapServerId: switched ? const Value(null) : const Value.absent(),
        ),
      );
    });
    final row = await (_db.select(_db.drafts)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row != null) return _toModel(row);
    return SavedDraft(
      id: id,
      accountId: accountId,
      replyToEmailId: replyToEmailId,
      toText: toText,
      ccText: ccText,
      bccText: bccText,
      subjectText: subjectText,
      bodyText: bodyText,
      updatedAt: now,
      attachments: stored,
    );
  }

  Future<SavedDraft> _insertDraft(DraftInput input) async {
    final DraftInput(
      :accountId,
      :replyToEmailId,
      :toText,
      :ccText,
      :bccText,
      :subjectText,
      :bodyText,
      :attachments,
    ) = input;
    final now = DateTime.now();
    final newId = await _db.into(_db.drafts).insert(
          DraftsCompanion.insert(
            accountId: Value(accountId),
            replyToEmailId: Value(replyToEmailId),
            toText: Value(toText),
            ccText: Value(ccText),
            bccText: Value(bccText),
            subjectText: Value(subjectText),
            bodyText: Value(bodyText),
            updatedAt: now,
            dirty: const Value(true),
          ),
        );
    // The id is only known now, and the row exists before its folder does.
    var stored = attachments;
    if (attachments.isNotEmpty) {
      stored = await _serialized(newId, () async {
        final kept = await _files.keep(newId, attachments);
        await (_db.update(_db.drafts)..where((t) => t.id.equals(newId))).write(
          DraftsCompanion(attachmentsJson: Value(encodeDraftAttachments(kept))),
        );
        return kept;
      });
    }
    return SavedDraft(
      id: newId,
      accountId: accountId,
      replyToEmailId: replyToEmailId,
      toText: toText,
      ccText: ccText,
      bccText: bccText,
      subjectText: subjectText,
      bodyText: bodyText,
      updatedAt: now,
      attachments: stored,
    );
  }

  @override
  Future<List<SavedDraft>> listNewMessageDrafts({String? accountId}) async {
    final query = _db.select(_db.drafts)
      ..where((t) => t.replyToEmailId.isNull());
    if (accountId != null) {
      query.where((t) => t.accountId.equals(accountId));
    }
    query.orderBy([
      (t) => OrderingTerm.desc(t.updatedAt),
      (t) => OrderingTerm.desc(t.id),
    ]);
    final rows = await query.get();
    return rows.map(_toModel).toList();
  }

  @override
  Future<SavedDraft?> getDraft(int id) async {
    final row = await (_db.select(
      _db.drafts,
    )..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : _toModel(row);
  }

  @override
  Future<SavedDraft?> findDraftForEmail(model.Email email) async {
    if (email.isLocal) return null;
    final accountId = email.accountId;
    // A JMAP message row is "<accountId>:<email id>". An IMAP row is
    // "<accountId>:<mailbox>:<uid>", which never equals a JMAP email id.
    final prefix = '$accountId:';
    if (email.id.startsWith(prefix)) {
      final jmapId = email.id.substring(prefix.length);
      final row = await (_db.select(_db.drafts)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) & t.jmapServerId.equals(jmapId),
            )
            ..limit(1))
          .getSingleOrNull();
      if (row != null) return _toModel(row);
    }
    if (email.uid <= 0) return null;
    // IMAP UIDs only mean something in the mailbox draft sync used for them.
    final state = await (_db.select(_db.syncStates)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.resourceType.equals(_draftsPathState),
          ))
        .getSingleOrNull();
    if (email.mailboxPath != (state?.state ?? _draftsFolder)) return null;
    final row = await (_db.select(_db.drafts)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.imapServerId.equals(email.uid.toString()),
          )
          ..limit(1))
        .getSingleOrNull();
    return row == null ? null : _toModel(row);
  }

  @override
  Future<void> deleteDraft(int id) => _serialized(id, () async {
        // One transaction, so a push finishing in between cannot store a new
        // server id that the tombstone then misses.
        final row = await _db.transaction(() async {
          final row = await (_db.select(_db.drafts)
                ..where((t) => t.id.equals(id)))
              .getSingleOrNull();
          if (row == null) return null;
          await _tombstoneServerCopy(row);
          await (_db.delete(_db.drafts)..where((t) => t.id.equals(id))).go();
          return row;
        });
        if (row != null) await _deleteFilesOf(row);
      });

  /// Deletes [row]'s attachment folder once the row is gone. A row that
  /// never had attachments has none (short of a crash, which
  /// [deleteOrphanedAttachments] cleans up).
  Future<void> _deleteFilesOf(Draft row) async {
    if (row.attachmentsJson == '[]') return;
    await _files.delete(row.id);
  }

  /// Deletes the draft row [row] that sync found gone from the server.
  Future<void> _dropSyncedRow(Draft row) async {
    await (_db.delete(_db.drafts)..where((t) => t.id.equals(row.id))).go();
    await _deleteFilesOf(row);
  }

  @override
  Future<void> deleteOrphanedAttachments() async {
    try {
      await _files.deleteOrphans(() async {
        final rows = await _db.select(_db.drafts).get();
        return {for (final r in rows) r.id};
      });
    } catch (e, stack) {
      unawaited(
        _appLogger?.warn(
          'draft.attachments.sweep_failed',
          'Could not remove attachment files of deleted drafts',
          error: e,
          stack: stack,
        ),
      );
    }
  }

  /// Queues removal of [row]'s copy on its account's server, if it has one.
  Future<void> _tombstoneServerCopy(Draft row) =>
      _tombstone(row.accountId, row.imapServerId ?? row.jmapServerId);

  /// Queues removal of [serverId] from [accountId]'s server, if the account
  /// still exists (a deleted account has no server to sync).
  Future<void> _tombstone(String? accountId, String? serverId) async {
    if (accountId == null || serverId == null || serverId.isEmpty) return;
    final account = await (_db.select(_db.accounts)
          ..where((t) => t.id.equals(accountId)))
        .getSingleOrNull();
    if (account == null) return;
    await _db.into(_db.draftTombstones).insert(
          DraftTombstonesCompanion.insert(
            accountId: accountId,
            serverId: serverId,
            createdAt: DateTime.now(),
          ),
        );
  }

  /// Stores that [row] went up to [accountId]'s server as [newServerId].
  ///
  /// The push runs while compose may still be open, so the row can have
  /// changed since it was read:
  /// - edited: the new server id is kept but the row stays dirty, so the
  ///   next push uploads the edit and replaces the copy just made;
  /// - moved to another account or deleted: the copy just made belongs to
  ///   nobody, so it is queued for removal from [accountId]'s server.
  ///
  /// Edits are detected by content rather than `updatedAt`, which is stored
  /// with one-second precision.
  Future<void> _recordPush(
    Draft row,
    String accountId,
    String? newServerId, {
    required bool jmap,
  }) {
    final serverId = jmap
        ? DraftsCompanion(jmapServerId: Value(newServerId))
        : DraftsCompanion(imapServerId: Value(newServerId));
    return _db.transaction(() async {
      final unchanged = await (_db.update(_db.drafts)
            ..where(
              (t) =>
                  t.id.equals(row.id) &
                  t.accountId.equals(accountId) &
                  t.toText.equals(row.toText) &
                  t.ccText.equals(row.ccText) &
                  t.bccText.equals(row.bccText) &
                  t.subjectText.equals(row.subjectText) &
                  t.bodyText.equals(row.bodyText) &
                  t.attachmentsJson.equals(row.attachmentsJson),
            ))
          .write(serverId.copyWith(dirty: const Value(false)));
      if (unchanged > 0) return;
      final edited = await (_db.update(_db.drafts)
            ..where(
              (t) => t.id.equals(row.id) & t.accountId.equals(accountId),
            ))
          .write(serverId);
      if (edited > 0) return;
      if (newServerId == null || newServerId.isEmpty) {
        // No APPENDUID: the copy cannot be addressed, so it stays behind.
        unawaited(
          _appLogger?.warn(
            'draft.push.orphaned',
            'Draft moved or deleted during push; its new server copy has '
                'no id and cannot be removed',
            accountId: accountId,
          ),
        );
        return;
      }
      await _tombstone(accountId, newServerId);
    });
  }

  /// Server ids of [accountId]'s drafts queued for removal. A pull must not
  /// import them again before the next sync removes them.
  Future<Set<String>> _tombstonedServerIds(String accountId) async {
    final rows = await (_db.select(_db.draftTombstones)
          ..where((t) => t.accountId.equals(accountId)))
        .get();
    return {for (final r in rows) r.serverId};
  }

  /// The last [syncDrafts] run per account; the next one waits for it.
  final Map<String, Future<void>> _syncTails = {};

  /// Runs one draft sync of [accountId] at a time. The background sync loop
  /// and the "Edit draft" action can ask at once; two overlapping runs would
  /// both push the same dirty draft (a second server copy) and both pull the
  /// same new server draft (a second local row). A call made during a run
  /// waits for it and then runs itself, so it still sees edits made meanwhile.
  @override
  Future<void> syncDrafts(String accountId) {
    final previous = _syncTails[accountId];
    final run = previous == null
        ? _syncDraftsNow(accountId)
        : previous.then((_) => _syncDraftsNow(accountId));
    // The tail never fails, so a failed run does not fail the next one.
    final tail = run.then<void>((_) {}, onError: (Object _) {});
    _syncTails[accountId] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_syncTails[accountId], tail)) {
          unawaited(_syncTails.remove(accountId));
        }
      }),
    );
    return run;
  }

  Future<void> _syncDraftsNow(String accountId) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null) return;

    switch (account.type) {
      case account_model.AccountType.imap:
        if (_imapConnect == null) return;
        final password = await _accounts.getPassword(accountId);
        await _syncDraftsImap(account, password);
      case account_model.AccountType.jmap:
        if (_httpClient == null) return;
        final password = await _accounts.getPassword(accountId);
        await _syncDraftsJmap(account, password);
    }
  }

  String _effectiveUsername(account_model.Account account) =>
      account.username.isNotEmpty ? account.username : account.email;

  // ── IMAP ────────────────────────────────────────────────────────────────

  Future<void> _syncDraftsImap(
    account_model.Account account,
    String password,
  ) async {
    final client = await _imapConnect!(
      account,
      _effectiveUsername(account),
      password,
    );
    try {
      // The mailbox the server flags as SPECIAL-USE \Drafts: "[Gmail]/Drafts",
      // "INBOX.Drafts", "Entwürfe". Only the server's flag counts, not a
      // folder that merely has "Drafts" in its name ("Projects/Drafts"). A
      // server that flags none keeps the "Drafts" folder used so far.
      final rolePath = await _serverDraftsMailboxPath(client);
      final draftsPath = rolePath ?? _draftsFolder;
      if (rolePath == null) {
        try {
          await client.createMailbox(_draftsFolder);
        } catch (_) {
          // Already exists.
        }
      }
      // Stored paths are decoded Unicode; the wire wants modified UTF-7.
      final encodedPath = encodeImapMailboxPath(
        draftsPath,
        client.serverInfo.pathSeparator ?? '/',
      );
      await client.selectMailboxByPath(encodedPath);
      await _forgetUidsFromOtherMailbox(account.id, draftsPath);

      await _pushTombstonesImap(client, account.id);
      await _pushDirtyImap(client, account, encodedPath);
      await _pullDraftsImap(client, account.id);
    } finally {
      await client.logout();
    }
  }

  Future<void> _pushTombstonesImap(
    imap.ImapClient client,
    String accountId,
  ) async {
    final tombstones = await (_db.select(_db.draftTombstones)
          ..where((t) => t.accountId.equals(accountId)))
        .get();
    for (final tombstone in tombstones) {
      final uid = int.tryParse(tombstone.serverId);
      if (uid != null) {
        try {
          final seq = imap.MessageSequence.fromId(uid, isUid: true);
          await client.uidMarkDeleted(seq);
          await client.uidExpunge(seq);
        } catch (_) {
          // Already gone or transient error — drop the tombstone anyway so
          // we don't retry forever.
        }
      }
      await (_db.delete(_db.draftTombstones)
            ..where((t) => t.id.equals(tombstone.id)))
          .go();
    }
  }

  static const _draftsPathState = 'IMAP:DraftsMailbox';

  /// Draft rows and tombstones carry IMAP UIDs, which only mean something in
  /// the mailbox they came from. When the drafts mailbox in use changes (an
  /// account synced before the server's own drafts mailbox was used always
  /// had "Drafts"), expunging those UIDs in the new mailbox could delete
  /// unrelated messages there. Instead the local drafts are pushed again as
  /// new messages and the tombstones are dropped; the old copies stay in the
  /// old folder.
  Future<void> _forgetUidsFromOtherMailbox(
    String accountId,
    String draftsPath,
  ) async {
    final row = await (_db.select(_db.syncStates)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.resourceType.equals(_draftsPathState),
          ))
        .getSingleOrNull();
    final previousPath = row?.state ?? _draftsFolder;
    if (previousPath != draftsPath) {
      await _db.transaction(() async {
        await (_db.update(_db.drafts)
              ..where(
                (t) =>
                    t.accountId.equals(accountId) & t.imapServerId.isNotNull(),
              ))
            .write(
          const DraftsCompanion(imapServerId: Value(null), dirty: Value(true)),
        );
        await (_db.delete(_db.draftTombstones)
              ..where((t) => t.accountId.equals(accountId)))
            .go();
      });
    }
    if (row?.state != draftsPath) {
      await _db.into(_db.syncStates).insertOnConflictUpdate(
            SyncStatesCompanion.insert(
              accountId: accountId,
              resourceType: _draftsPathState,
              state: draftsPath,
              syncedAt: DateTime.now(),
            ),
          );
    }
  }

  /// The mailbox the server lists with the SPECIAL-USE `\Drafts` flag, if any.
  Future<String?> _serverDraftsMailboxPath(imap.ImapClient client) async {
    try {
      final boxes = await client.listMailboxes(recursive: true);
      for (final box in boxes) {
        if (box.isDrafts) return box.path;
      }
    } catch (_) {
      // LIST failed; fall back to "Drafts".
    }
    return null;
  }

  Future<void> _pushDirtyImap(
    imap.ImapClient client,
    account_model.Account account,
    String draftsPath,
  ) async {
    final dirty = await (_db.select(_db.drafts)
          ..where((t) => t.accountId.equals(account.id) & t.dirty.equals(true)))
        .get();

    for (final row in dirty) {
      final builder = imap.MessageBuilder()
        ..from = [HeaderMailAddress(account.displayName, account.email)]
        ..to = _parseAddresses(row.toText)
        ..cc = _parseAddresses(row.ccText)
        // The server copy is the sender's own, so it keeps Bcc like any
        // other client's draft does (#1126).
        ..bcc = _parseAddresses(row.bccText)
        ..subject = encodeUnstructuredHeader(row.subjectText)
        ..subjectEncoding = imap.HeaderEncoding.none
        ..text = row.bodyText;
      for (final a in decodeDraftAttachments(row.attachmentsJson)) {
        final file = File(a.path);
        // A file gone missing is left out rather than failing every push;
        // compose tells the user when the draft is opened.
        if (!await file.exists()) continue;
        await builder.addFile(file, imap.MediaType.fromText(a.contentType));
      }
      final mime = builder.buildMimeMessage();

      final appendResult = await client.appendMessage(
        mime,
        targetMailboxPath: draftsPath,
        flags: [r'\Draft'],
      );
      final uidList =
          appendResult.responseCodeAppendUid?.targetSequence.toList();
      final newUid = (uidList != null && uidList.isNotEmpty)
          ? uidList.first.toString()
          : null;

      // After appending the new copy, expunge the old one so server-side
      // edits replace the previous version instead of accumulating.
      final oldUid = row.imapServerId;
      if (oldUid != null && oldUid.isNotEmpty && oldUid != newUid) {
        final oldUidInt = int.tryParse(oldUid);
        if (oldUidInt != null) {
          try {
            final seq = imap.MessageSequence.fromId(oldUidInt, isUid: true);
            await client.uidMarkDeleted(seq);
            await client.uidExpunge(seq);
          } catch (_) {
            // Old copy already gone — fine.
          }
        }
      }

      await _recordPush(row, account.id, newUid, jmap: false);
    }
  }

  Future<void> _pullDraftsImap(
    imap.ImapClient client,
    String accountId,
  ) async {
    final searchResult = await client.uidSearchMessages(
      searchCriteria: 'NOT DELETED',
    );
    final serverUids =
        (searchResult.matchingSequence?.toList() ?? <int>[]).toSet();
    final serverUidStrings = serverUids.map((u) => u.toString()).toSet();

    final localRows = await (_db.select(_db.drafts)
          ..where(
            (t) => t.accountId.equals(accountId) & t.imapServerId.isNotNull(),
          ))
        .get();
    final knownUids = await _tombstonedServerIds(accountId);
    for (final row in localRows) {
      final uid = row.imapServerId;
      if (uid != null) knownUids.add(uid);
    }

    // Remove local rows whose server copy has disappeared (but never wipe
    // dirty rows — those haven't been pushed yet).
    for (final row in localRows) {
      final uid = row.imapServerId;
      if (uid == null) continue;
      if (!serverUidStrings.contains(uid) && !row.dirty) {
        await _dropSyncedRow(row);
      }
    }

    final newUids =
        serverUids.where((u) => !knownUids.contains(u.toString())).toList();
    if (newUids.isEmpty) return;

    final seq = imap.MessageSequence.fromIds(newUids, isUid: true);
    final fetch =
        await client.uidFetchMessages(seq, '(UID FLAGS ENVELOPE BODY.PEEK[])');

    for (final msg in fetch.messages) {
      final uid = msg.uid?.toString();
      if (uid == null) continue;
      if (msg.flags?.contains(r'\Deleted') ?? false) continue;
      final env = msg.envelope;
      final parts = _attachmentPartsImap(msg, accountId);
      final newId = await _db.into(_db.drafts).insert(
            DraftsCompanion.insert(
              accountId: Value(accountId),
              toText: Value(_addressListToText(env?.to)),
              ccText: Value(_addressListToText(env?.cc)),
              bccText: Value(_addressListToText(env?.bcc)),
              subjectText: Value(env?.subject ?? ''),
              bodyText: Value(msg.decodeTextPlainPart() ?? ''),
              updatedAt: env?.date ?? DateTime.now(),
              imapServerId: Value(uid),
              dirty: const Value(false),
            ),
          );
      await _storePulledAttachments(newId, parts);
    }
  }

  /// The attachments of a server draft fetched with `BODY.PEEK[]`, decoded.
  /// A part that cannot be decoded is logged and left out.
  List<_PulledAttachment> _attachmentPartsImap(
    imap.MimeMessage msg,
    String accountId,
  ) {
    final result = <_PulledAttachment>[];
    final List<imap.ContentInfo> infos;
    try {
      infos = msg.findContentInfo();
    } catch (e, stack) {
      _warnAttachmentPull(accountId, e, stack);
      return result;
    }
    for (final info in infos) {
      try {
        final part = info.fetchId.isEmpty ? null : msg.getPart(info.fetchId);
        final bytes = part?.decodeContentBinary();
        if (bytes == null) continue;
        result.add(
          _PulledAttachment(
            filename: mimePartFileName(
                  info.contentDisposition,
                  info.contentType,
                ) ??
                'attachment',
            contentType:
                info.contentType?.mediaType.text ?? 'application/octet-stream',
            bytes: bytes,
          ),
        );
      } catch (e, stack) {
        _warnAttachmentPull(accountId, e, stack);
      }
    }
    return result;
  }

  void _warnAttachmentPull(String accountId, Object e, StackTrace stack) {
    unawaited(
      _appLogger?.warn(
        'draft.pull.attachment_failed',
        'Could not read an attachment of a server draft',
        accountId: accountId,
        error: e,
        stack: stack,
      ),
    );
  }

  /// Writes [parts] into the folder of the just-pulled draft [draftId].
  Future<void> _storePulledAttachments(
    int draftId,
    List<_PulledAttachment> parts,
  ) async {
    if (parts.isEmpty) return;
    final stored = <DraftAttachment>[];
    for (final part in parts) {
      final path = await _files.add(draftId, part.filename, part.bytes);
      stored.add(
        DraftAttachment(
          path: path,
          filename: p.basename(path),
          contentType: part.contentType,
          size: part.bytes.length,
        ),
      );
    }
    await (_db.update(_db.drafts)..where((t) => t.id.equals(draftId))).write(
      DraftsCompanion(attachmentsJson: Value(encodeDraftAttachments(stored))),
    );
  }

  // ── JMAP ────────────────────────────────────────────────────────────────

  Future<void> _syncDraftsJmap(
    account_model.Account account,
    String password,
  ) async {
    final jmapUrl = account.jmapUrl;
    if (jmapUrl == null || jmapUrl.isEmpty) return;

    final jmap = await JmapClient.connect(
      httpClient: _httpClient!,
      jmapUrl: Uri.parse(jmapUrl),
      username: _effectiveUsername(account),
      password: password,
    );

    final mailboxId = await _findOrCreateDraftsMailboxJmap(jmap);

    await _pushTombstonesJmap(jmap, account.id);
    await _pushDirtyJmap(jmap, account, mailboxId);
    await _pullDraftsJmap(jmap, account.id, mailboxId);
  }

  Future<void> _pushTombstonesJmap(JmapClient jmap, String accountId) async {
    final tombstones = await (_db.select(_db.draftTombstones)
          ..where((t) => t.accountId.equals(accountId)))
        .get();
    if (tombstones.isEmpty) return;

    await jmap.call([
      [
        'Email/set',
        {
          'accountId': jmap.accountId,
          'destroy': tombstones.map((t) => t.serverId).toList(),
        },
        '0',
      ],
    ]);

    for (final tombstone in tombstones) {
      await (_db.delete(_db.draftTombstones)
            ..where((t) => t.id.equals(tombstone.id)))
          .go();
    }
  }

  Future<void> _pushDirtyJmap(
    JmapClient jmap,
    account_model.Account account,
    String mailboxId,
  ) async {
    final dirty = await (_db.select(_db.drafts)
          ..where((t) => t.accountId.equals(account.id) & t.dirty.equals(true)))
        .get();

    for (final row in dirty) {
      const bodyPartId = '1';
      final create = <String, dynamic>{
        'mailboxIds': {mailboxId: true},
        'keywords': {r'$draft': true},
        'from': [
          {'name': account.displayName, 'email': account.email},
        ],
        'to': _parseAddressesJmap(row.toText),
        if (row.ccText.trim().isNotEmpty) 'cc': _parseAddressesJmap(row.ccText),
        if (row.bccText.trim().isNotEmpty)
          'bcc': _parseAddressesJmap(row.bccText),
        'subject': row.subjectText,
        'bodyValues': {
          bodyPartId: {
            'value': row.bodyText,
            'isEncodingProblem': false,
            'isTruncated': false,
          },
        },
        'textBody': [
          {'partId': bodyPartId, 'type': 'text/plain'},
        ],
      };
      final attachments = <Map<String, dynamic>>[];
      for (final a in decodeDraftAttachments(row.attachmentsJson)) {
        final file = File(a.path);
        // As for IMAP: a missing file is left out, not a failed push.
        if (!await file.exists()) continue;
        final blobId = await jmap.uploadBlob(
          await file.readAsBytes(),
          a.contentType,
        );
        attachments.add({
          'blobId': blobId,
          'type': a.contentType,
          'name': a.filename,
          'disposition': 'attachment',
        });
      }
      if (attachments.isNotEmpty) create['attachments'] = attachments;

      final destroyIds = <String>[];
      final oldId = row.jmapServerId;
      if (oldId != null && oldId.isNotEmpty) destroyIds.add(oldId);

      final setArgs = <String, dynamic>{
        'accountId': jmap.accountId,
        'create': {'draft': create},
      };
      if (destroyIds.isNotEmpty) setArgs['destroy'] = destroyIds;

      final resp = await jmap.call([
        ['Email/set', setArgs, '0'],
      ]);
      final result = _responseArgs(resp, 0, 'Email/set');
      final created = result['created'] as Map<String, dynamic>?;
      final newEmail = created?['draft'] as Map<String, dynamic>?;
      final newId = newEmail?['id'] as String?;

      await _recordPush(row, account.id, newId, jmap: true);
    }
  }

  Future<void> _pullDraftsJmap(
    JmapClient jmap,
    String accountId,
    String mailboxId,
  ) async {
    final queryResp = await jmap.call([
      [
        'Email/query',
        {
          'accountId': jmap.accountId,
          'filter': {'inMailbox': mailboxId},
        },
        '0',
      ],
    ]);
    final ids = List<String>.from(
      (_responseArgs(queryResp, 0, 'Email/query')['ids'] as List? ?? []),
    );

    final localRows = await (_db.select(_db.drafts)
          ..where(
            (t) => t.accountId.equals(accountId) & t.jmapServerId.isNotNull(),
          ))
        .get();

    final serverIds = ids.toSet();

    // Remove local rows that have disappeared from the server (skip dirty
    // rows — those have local edits not yet pushed).
    for (final row in localRows) {
      final id = row.jmapServerId;
      if (id == null) continue;
      if (!serverIds.contains(id) && !row.dirty) {
        await _dropSyncedRow(row);
      }
    }

    final knownIds = await _tombstonedServerIds(accountId);
    for (final row in localRows) {
      final id = row.jmapServerId;
      if (id != null) knownIds.add(id);
    }
    final newIds = ids.where((id) => !knownIds.contains(id)).toList();
    if (newIds.isEmpty) return;

    final getResp = await jmap.call([
      [
        'Email/get',
        {
          'accountId': jmap.accountId,
          'ids': newIds,
          'properties': [
            'id',
            'receivedAt',
            'subject',
            'to',
            'cc',
            'bcc',
            'textBody',
            'bodyValues',
            'attachments',
          ],
          'fetchTextBodyValues': true,
        },
        '0',
      ],
    ]);
    final list =
        _responseArgs(getResp, 0, 'Email/get')['list'] as List<dynamic>;

    for (final e in list) {
      final m = e as Map<String, dynamic>;
      final id = m['id'] as String?;
      if (id == null) continue;

      final bodyValues = m['bodyValues'] as Map<String, dynamic>? ?? {};
      final textBody = m['textBody'] as List<dynamic>? ?? [];
      var bodyText = '';
      if (textBody.isNotEmpty) {
        final partId =
            (textBody.first as Map<String, dynamic>)['partId'] as String?;
        if (partId != null) {
          bodyText = (bodyValues[partId] as Map<String, dynamic>?)?['value']
                  as String? ??
              '';
        }
      }

      final receivedAt =
          DateTime.tryParse(m['receivedAt'] as String? ?? '') ?? DateTime.now();
      final parts = await _attachmentPartsJmap(jmap, m, accountId);

      final newId = await _db.into(_db.drafts).insert(
            DraftsCompanion.insert(
              accountId: Value(accountId),
              toText: Value(_addressJsonToText(m['to'])),
              ccText: Value(_addressJsonToText(m['cc'])),
              bccText: Value(_addressJsonToText(m['bcc'])),
              subjectText: Value((m['subject'] as String?) ?? ''),
              bodyText: Value(bodyText),
              updatedAt: receivedAt,
              jmapServerId: Value(id),
              dirty: const Value(false),
            ),
          );
      await _storePulledAttachments(newId, parts);
    }
  }

  /// Downloads the attachments of the server draft [email]. One that cannot
  /// be downloaded is logged and left out.
  Future<List<_PulledAttachment>> _attachmentPartsJmap(
    JmapClient jmap,
    Map<String, dynamic> email,
    String accountId,
  ) async {
    final result = <_PulledAttachment>[];
    final list = email['attachments'] as List<dynamic>? ?? const [];
    for (final entry in list.whereType<Map<String, dynamic>>()) {
      final blobId = entry['blobId'] as String?;
      if (blobId == null) continue;
      final name = (entry['name'] as String?) ?? 'attachment';
      final type = (entry['type'] as String?) ?? 'application/octet-stream';
      try {
        final bytes = await jmap.downloadBlob(blobId, name: name, type: type);
        result.add(
          _PulledAttachment(filename: name, contentType: type, bytes: bytes),
        );
      } catch (e, stack) {
        _warnAttachmentPull(accountId, e, stack);
      }
    }
    return result;
  }

  Future<String> _findOrCreateDraftsMailboxJmap(JmapClient jmap) async {
    final resp = await jmap.call([
      [
        'Mailbox/get',
        {'accountId': jmap.accountId, 'ids': null},
        '0',
      ],
    ]);
    final list = _responseArgs(resp, 0, 'Mailbox/get')['list'] as List<dynamic>;
    for (final mailbox in list) {
      final map = mailbox as Map<String, dynamic>;
      if (map['role'] == 'drafts' || map['name'] == _draftsFolder) {
        final id = map['id'] as String?;
        if (id != null) return id;
      }
    }

    final createResp = await jmap.call([
      [
        'Mailbox/set',
        {
          'accountId': jmap.accountId,
          'create': {
            'new-drafts': {'name': _draftsFolder, 'role': 'drafts'},
          },
        },
        '0',
      ],
    ]);
    final result = _responseArgs(createResp, 0, 'Mailbox/set');
    final created = result['created'] as Map<String, dynamic>?;
    final newMailbox = created?['new-drafts'] as Map<String, dynamic>?;
    final newId = newMailbox?['id'] as String?;
    if (newId == null) {
      throw JmapException('Could not create Drafts mailbox');
    }
    return newId;
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  // A draft keeps what was typed, even an entry that is not an address yet
  // ("bob" on the way to "bob@example.com"); only sending refuses those.
  List<imap.MailAddress> _parseAddresses(String text) => [
        for (final r in parseRecipients(text))
          HeaderMailAddress(r.address.name, r.address.email),
      ];

  List<Map<String, dynamic>> _parseAddressesJmap(String text) => [
        for (final r in parseRecipients(text))
          {
            if (r.address.name != null) 'name': r.address.name,
            'email': r.address.email,
          },
      ];

  String _addressListToText(List<imap.MailAddress>? addresses) {
    if (addresses == null || addresses.isEmpty) return '';
    return addresses.map((a) => a.email).join(', ');
  }

  String _addressJsonToText(Object? value) {
    if (value is! List) return '';
    return value
        .whereType<Map<String, dynamic>>()
        .map((m) => m['email'] as String? ?? '')
        .where((s) => s.isNotEmpty)
        .join(', ');
  }

  Map<String, dynamic> _responseArgs(
    List<dynamic> responses,
    int index,
    String expectedMethod,
  ) {
    final triple = responses[index] as List<dynamic>;
    final method = triple[0] as String;
    if (method == 'error') {
      final err = triple[1] as Map<String, dynamic>;
      throw JmapException('$expectedMethod error: ${err['type']}');
    }
    return triple[1] as Map<String, dynamic>;
  }

  SavedDraft _toModel(Draft row) => SavedDraft(
        id: row.id,
        accountId: row.accountId,
        replyToEmailId: row.replyToEmailId,
        toText: row.toText,
        ccText: row.ccText,
        bccText: row.bccText,
        subjectText: row.subjectText,
        bodyText: row.bodyText,
        updatedAt: row.updatedAt,
        imapServerId: row.imapServerId,
        jmapServerId: row.jmapServerId,
        dirty: row.dirty,
        attachments: decodeDraftAttachments(row.attachmentsJson),
      );
}

/// An attachment of a server draft, read during a pull.
class _PulledAttachment {
  const _PulledAttachment({
    required this.filename,
    required this.contentType,
    required this.bytes,
  });

  final String filename;
  final String contentType;
  final List<int> bytes;
}
