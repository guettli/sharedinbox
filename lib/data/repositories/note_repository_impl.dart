import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'package:sharedinbox/core/models/account.dart' as account_model;
import 'package:sharedinbox/core/models/note.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/note_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:sharedinbox/data/imap/imap_errors.dart';
import 'package:sharedinbox/data/imap/imap_expunge.dart';
import 'package:sharedinbox/data/jmap/jmap_client.dart';

const _notesFolder = 'Notes';
const _headerNoteFor = 'X-SharedInbox-Note-For';
const _headerNoteId = 'X-SharedInbox-Note-Id';

/// [SyncStates.resourceType] used to store the notes-sync checkpoint per
/// account. See [NoteRepository.syncAllNotes].
const _notesResourceType = 'notes';

class NoteRepositoryImpl implements NoteRepository {
  NoteRepositoryImpl(
    this._db,
    this._accounts, {
    ImapConnectFn imapConnect = connectImap,
    http.Client? httpClient,
    AppLogger? appLogger,
    bool pushPending = true,
  })  : _pushEnabled = pushPending,
        _imapConnect = imapConnect,
        _httpClient = httpClient ?? http.Client(),
        _appLogger = appLogger;

  final AppDatabase _db;
  final AccountRepository _accounts;
  final ImapConnectFn _imapConnect;
  final http.Client _httpClient;
  final AppLogger? _appLogger;

  /// False in the background (WorkManager) isolate: [_exclusive] serializes
  /// pushes within one isolate only, so only the app's isolate pushes.
  final bool _pushEnabled;

  String _effectiveUsername(account_model.Account account) =>
      account.username.isNotEmpty ? account.username : account.email;

  /// Resolves the local email row id for an RFC Message-ID so note log
  /// entries surface under that mail in the App Log screen (which filters by
  /// [AppLogEntry.emailId]). Returns `null` when the mail isn't cached
  /// locally — logging still works, the entry just won't be scoped to a mail.
  Future<String?> _emailIdForMessage(String accountId, String messageId) async {
    final row = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.messageId.equals(messageId) &
                // Not a hidden row (deleted for good, or gone).
                t.mailboxPath.equals('').not(),
          )
          ..limit(1))
        .getSingleOrNull();
    return row?.id;
  }

  // ── Observe (local cache) ─────────────────────────────────────────────────

  @override
  Stream<List<EmailNote>> observeNotes(String accountId, String messageId) =>
      observeNotesForMessages(accountId, [messageId]);

  @override
  Stream<List<EmailNote>> observeNotesForMessages(
    String accountId,
    Iterable<String> messageIds,
  ) {
    final ids = messageIds.toSet();
    if (ids.isEmpty) return Stream.value(const <EmailNote>[]);
    return (_db.select(_db.emailNotes)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.messageId.isIn(ids) &
                t.pendingDelete.equals(false),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .watch()
        .map((rows) => rows.map(_toModel).toList());
  }

  // ── Sync (server → local cache) ──────────────────────────────────────────

  @override
  Future<void> syncAllNotes(String accountId) =>
      _exclusive(accountId, () async {
        final account = await _accounts.getAccount(accountId);
        if (account == null) return;
        final password = await _accounts.getPassword(accountId);

        // Push local adds/deletes first, so the pull below sees them on the
        // server; it also never prunes or revives a row still pending. A
        // failed push must not keep the cache from refreshing.
        try {
          await _pushPending(account, password);
        } catch (e) {
          unawaited(
            _appLogger?.info(
              'note.push.deferred',
              'Pushing local note changes failed; pulling anyway',
              accountId: accountId,
              data: {'error': e.toString()},
            ),
          );
        }
        switch (account.type) {
          case account_model.AccountType.imap:
            await _syncAllNotesImap(account, password);
          case account_model.AccountType.jmap:
            await _syncAllNotesJmap(account, password);
        }
      });

  /// Tail of the running push/sync per account. Pushes and syncs of one
  /// account run one after another, so a push never races a pull's prune and
  /// two pushes never upload the same note twice (within this isolate).
  final Map<String, Future<void>> _accountTails = {};

  Future<void> _exclusive(String accountId, Future<void> Function() body) {
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

  /// Completes once every push/sync started so far has finished.
  @visibleForTesting
  Future<void> waitForIdle() async {
    while (_accountTails.isNotEmpty) {
      await Future.wait(_accountTails.values.toList());
    }
  }

  /// Tries to push right after a local add/delete. Offline (or any failure)
  /// is fine: the row stays pending and the next sync cycle pushes it.
  void _kickPush(String accountId) {
    if (!_pushEnabled) return;
    unawaited(
      _exclusive(accountId, () async {
        final account = await _accounts.getAccount(accountId);
        if (account == null) return;
        final password = await _accounts.getPassword(accountId);
        await _pushPending(account, password);
      }).catchError((Object e) {
        unawaited(
          _appLogger?.info(
            'note.push.deferred',
            'Note change saved locally; it is pushed on the next sync',
            accountId: accountId,
            data: {'error': e.toString()},
          ),
        );
      }),
    );
  }

  Future<void> _syncAllNotesImap(
    account_model.Account account,
    String password,
  ) async {
    final client = await _imapConnect(
      account,
      _effectiveUsername(account),
      password,
    );
    try {
      final imap.Mailbox selected;
      try {
        selected = await client.selectMailboxByPath(_notesFolder);
      } catch (e) {
        if (isImapMailboxNotFound(e)) {
          await _handleNotesFolderMissing(account.id, 'imap');
          return;
        }
        rethrow;
      }

      final uidValidity = selected.uidValidity ?? 0;
      final checkpoint = await _loadNotesCheckpoint(account.id);
      final storedUidValidity = checkpoint?['uidValidity'] as int?;
      final storedLastUid = checkpoint?['lastUid'] as int?;

      // First run or UID validity changed → full scan.
      if (storedUidValidity == null || storedUidValidity != uidValidity) {
        if (storedUidValidity != null) {
          // UID validity churned — the server reassigned UIDs, so every
          // cached serverId is stale. Drop them; the fetch below repopulates.
          await _clearNotesForAccount(
            account.id,
            'note.sync.uidvalidity_wipe',
          );
        }
        final allUids = (await client.uidSearchMessages(searchCriteria: 'ALL'))
                .matchingSequence
                ?.toList() ??
            [];
        final fetchedNoteIds = <String>{};
        if (allUids.isNotEmpty) {
          final seq = imap.MessageSequence.fromIds(allUids, isUid: true);
          final fetch = await client.uidFetchMessages(seq, '(UID BODY.PEEK[])');
          for (final msg in fetch.messages) {
            final noteId = await _upsertNoteFromImapMessage(account.id, msg);
            if (noteId != null) fetchedNoteIds.add(noteId);
          }
        }
        // Purge any local rows for this account that aren't in the fetched set.
        final pruned =
            await _pruneNotesForAccountNotIn(account.id, fetchedNoteIds);
        final maxUid = allUids.isEmpty ? 0 : allUids.reduce(math.max);
        await _saveNotesCheckpoint(account.id, {
          'uidValidity': uidValidity,
          'lastUid': maxUid,
        });
        unawaited(
          _appLogger?.info(
            'note.sync.completed',
            'Note sync (imap full scan) done',
            accountId: account.id,
            data: {
              'transport': 'imap',
              'fetched': fetchedNoteIds.length,
              'pruned': pruned,
            },
          ),
        );
        return;
      }

      // Incremental scan: fetch bodies only for newly appended UIDs.
      final lastUid = storedLastUid ?? 0;
      final newUids = (await client.uidSearchMessages(
            searchCriteria: 'UID ${lastUid + 1}:*',
          ))
              .matchingSequence
              ?.toList() ??
          [];
      // Some IMAP servers return the last-seen UID when nothing is newer;
      // drop anything at or below the checkpoint so we don't refetch.
      final trulyNew = newUids.where((u) => u > lastUid).toList();
      var fetched = 0;
      if (trulyNew.isNotEmpty) {
        final seq = imap.MessageSequence.fromIds(trulyNew, isUid: true);
        final fetch = await client.uidFetchMessages(seq, '(UID BODY.PEEK[])');
        for (final msg in fetch.messages) {
          final noteId = await _upsertNoteFromImapMessage(account.id, msg);
          if (noteId != null) fetched++;
        }
      }

      // Reconcile deletions with a cheap UID-only ALL search (no bodies).
      final serverUids = (await client.uidSearchMessages(searchCriteria: 'ALL'))
              .matchingSequence
              ?.toList() ??
          [];
      final serverUidStrings = serverUids.map((u) => u.toString()).toSet();
      final pruned =
          await _pruneNotesForAccountByServerId(account.id, serverUidStrings);

      // Only past what was fetched: a note appended after the search above is
      // already in [serverUids] and would otherwise never be fetched.
      final maxUid = trulyNew.fold(lastUid, math.max);
      await _saveNotesCheckpoint(account.id, {
        'uidValidity': uidValidity,
        'lastUid': maxUid,
      });
      // Runs every sync cycle — only log when something changed.
      if (fetched == 0 && pruned == 0) return;
      unawaited(
        _appLogger?.info(
          'note.sync.completed',
          'Note sync (imap incremental) done',
          accountId: account.id,
          data: {
            'transport': 'imap',
            'fetched': fetched,
            'pruned': pruned,
          },
        ),
      );
    } finally {
      await closeImapClient(client);
    }
  }

  /// The Notes folder doesn't exist (yet) — the default on most servers.
  /// Clears any stale checkpoint and drops orphaned local notes so the local
  /// cache mirrors reality. This runs on every sync cycle, and every App Log
  /// row is persisted, so it logs only when something was actually cleared.
  Future<void> _handleNotesFolderMissing(
    String accountId,
    String transport,
  ) async {
    final wiped = await _clearNotesForAccount(
      accountId,
      'note.sync.folder_missing_wipe',
    );
    // A note deleted locally has no server copy left to remove.
    await (_db.delete(_db.emailNotes)
          ..where(
            (t) => t.accountId.equals(accountId) & t.pendingDelete.equals(true),
          ))
        .go();
    final checkpointCleared = await _clearNotesCheckpoint(accountId) > 0;
    if (wiped == 0 && !checkpointCleared) return;
    unawaited(
      _appLogger?.info(
        'note.sync.completed',
        'Note sync: Notes folder not found, cleared local cache',
        accountId: accountId,
        data: {
          'transport': transport,
          'wiped': wiped,
          'checkpointCleared': checkpointCleared,
        },
      ),
    );
  }

  Future<void> _syncAllNotesJmap(
    account_model.Account account,
    String password,
  ) async {
    final jmapUrl = account.jmapUrl;
    if (jmapUrl == null || jmapUrl.isEmpty) return;

    final jmap = await JmapClient.connect(
      httpClient: _httpClient,
      jmapUrl: Uri.parse(jmapUrl),
      username: _effectiveUsername(account),
      password: password,
    );

    final mailboxId = await _findNotesMailboxJmap(jmap);
    if (mailboxId == null) {
      await _handleNotesFolderMissing(account.id, 'jmap');
      return;
    }

    final checkpoint = await _loadNotesCheckpoint(account.id);
    final storedQueryState = checkpoint?['queryState'] as String?;
    final storedEmailState = checkpoint?['emailState'] as String?;

    if (storedQueryState == null || storedEmailState == null) {
      await _jmapFullNotesSync(account.id, jmap, mailboxId);
      return;
    }

    try {
      await _jmapIncrementalNotesSync(
        account.id,
        jmap,
        mailboxId,
        sinceQueryState: storedQueryState,
        sinceEmailState: storedEmailState,
      );
    } on _NotesCannotCalculateChanges {
      // Server can no longer resolve the sinceState token — reset and
      // re-fetch everything.
      await _clearNotesCheckpoint(account.id);
      await _jmapFullNotesSync(account.id, jmap, mailboxId);
    }
  }

  Future<void> _jmapFullNotesSync(
    String accountId,
    JmapClient jmap,
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
    final queryArgs = _responseArgs(queryResp, 0, 'Email/query');
    final queryState = queryArgs['queryState'] as String? ?? '';
    final ids = List<String>.from(queryArgs['ids'] as List? ?? const []);

    final fetchedIds = <String>{};
    String emailState = '';
    if (ids.isEmpty) {
      // Still need a starting emailState — Email/get with an empty ids list
      // returns the current state and an empty list (RFC 8621 §5.1).
      final getResp = await jmap.call([
        [
          'Email/get',
          {
            'accountId': jmap.accountId,
            'ids': <String>[],
            'properties': _noteProperties,
            'fetchTextBodyValues': true,
          },
          '0',
        ],
      ]);
      emailState =
          _responseArgs(getResp, 0, 'Email/get')['state'] as String? ?? '';
    } else {
      final getResp = await jmap.call([
        [
          'Email/get',
          {
            'accountId': jmap.accountId,
            'ids': ids,
            'properties': _noteProperties,
            'fetchTextBodyValues': true,
          },
          '0',
        ],
      ]);
      final getArgs = _responseArgs(getResp, 0, 'Email/get');
      emailState = getArgs['state'] as String? ?? '';
      final list = getArgs['list'] as List<dynamic>;

      for (final e in list) {
        final noteId = await _upsertNoteFromJmapEmail(
          accountId,
          e as Map<String, dynamic>,
        );
        if (noteId != null) fetchedIds.add(noteId);
      }
    }

    // Purge local rows that weren't observed.
    final pruned = await _pruneNotesForAccountNotIn(accountId, fetchedIds);

    await _saveNotesCheckpoint(accountId, {
      'queryState': queryState,
      'emailState': emailState,
    });
    unawaited(
      _appLogger?.info(
        'note.sync.completed',
        'Note sync (jmap full) done',
        accountId: accountId,
        data: {
          'transport': 'jmap',
          'fetched': fetchedIds.length,
          'pruned': pruned,
        },
      ),
    );
  }

  Future<void> _jmapIncrementalNotesSync(
    String accountId,
    JmapClient jmap,
    String mailboxId, {
    required String sinceQueryState,
    required String sinceEmailState,
  }) async {
    final responses = await jmap.call([
      [
        'Email/queryChanges',
        {
          'accountId': jmap.accountId,
          'filter': {'inMailbox': mailboxId},
          'sinceQueryState': sinceQueryState,
        },
        '0',
      ],
      [
        'Email/changes',
        {'accountId': jmap.accountId, 'sinceState': sinceEmailState},
        '1',
      ],
    ]);

    final queryChanges = _responseTriple(responses, 0);
    if (queryChanges[0] == 'error') {
      final type = (queryChanges[1] as Map<String, dynamic>)['type'] as String?;
      if (type == 'cannotCalculateChanges') {
        throw const _NotesCannotCalculateChanges();
      }
      throw JmapException('Email/queryChanges error: $type');
    }
    final emailChanges = _responseTriple(responses, 1);
    if (emailChanges[0] == 'error') {
      final type = (emailChanges[1] as Map<String, dynamic>)['type'] as String?;
      if (type == 'cannotCalculateChanges') {
        throw const _NotesCannotCalculateChanges();
      }
      throw JmapException('Email/changes error: $type');
    }

    final queryArgs = queryChanges[1] as Map<String, dynamic>;
    final newQueryState = queryArgs['newQueryState'] as String? ?? '';
    final added = queryArgs['added'] as List<dynamic>? ?? const [];
    final removed =
        List<String>.from(queryArgs['removed'] as List? ?? const []);

    final emailArgs = emailChanges[1] as Map<String, dynamic>;
    final newEmailState = emailArgs['newState'] as String? ?? '';
    final created =
        List<String>.from(emailArgs['created'] as List? ?? const []);
    final updated =
        List<String>.from(emailArgs['updated'] as List? ?? const []);
    final destroyed =
        List<String>.from(emailArgs['destroyed'] as List? ?? const []);

    final addedIds = <String>{
      for (final entry in added)
        (entry as Map<String, dynamic>)['id'] as String,
    };

    // Fetch bodies for anything newly added or updated in the Notes mailbox.
    final toFetch = <String>{
      ...addedIds,
      ...created,
      ...updated,
    };
    if (toFetch.isNotEmpty) {
      final getResp = await jmap.call([
        [
          'Email/get',
          {
            'accountId': jmap.accountId,
            'ids': toFetch.toList(),
            'properties': _noteProperties,
            'fetchTextBodyValues': true,
          },
          '0',
        ],
      ]);
      final list = _responseArgs(getResp, 0, 'Email/get')['list'] as List;
      for (final e in list) {
        await _upsertNoteFromJmapEmail(accountId, e as Map<String, dynamic>);
      }
    }

    // Deletions come from two sources: destroyed (globally deleted) and
    // removed-from-query (moved out of the Notes mailbox). Both mean "not a
    // note anymore", so drop from the local cache in either case.
    //
    // An id may appear in both `removed` and `added`: RFC 8620 §5.6 lets a
    // server list a still-matching item in `removed` as long as it re-lists
    // it in `added`, and servers such as Stalwart do that for a freshly
    // created note. Such an id is still in the Notes mailbox, so it must survive —
    // otherwise the note the user just added vanishes on the next sync.
    final toRemove = {
      ...destroyed,
      ...removed.where((id) => !addedIds.contains(id)),
    };
    for (final jmapId in toRemove) {
      await _deleteNoteByServerId(accountId, jmapId);
    }

    await _saveNotesCheckpoint(accountId, {
      'queryState': newQueryState,
      'emailState': newEmailState,
    });
    // Runs every sync cycle — only log when something changed.
    if (toFetch.isEmpty && toRemove.isEmpty) return;
    unawaited(
      _appLogger?.info(
        'note.sync.completed',
        'Note sync (jmap incremental) done',
        accountId: accountId,
        data: {
          'transport': 'jmap',
          'fetched': toFetch.length,
          'removed': toRemove.length,
        },
      ),
    );
  }

  static const _noteProperties = [
    'id',
    'receivedAt',
    'textBody',
    'bodyValues',
    'header:$_headerNoteFor:asText',
    'header:$_headerNoteId:asText',
  ];

  // ── Add ───────────────────────────────────────────────────────────────────

  @override
  Future<void> addNote(
    String accountId,
    String messageId,
    String text,
  ) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null) {
      unawaited(
        _appLogger?.warn(
          'note.add.no_account',
          'Cannot add note: account not found',
          accountId: accountId,
          data: {'messageId': messageId},
        ),
      );
      return;
    }
    final noteId = _generateId();
    // Offline-first: the note exists as soon as it is stored here; the push
    // to the server follows (now if online, else on a later sync).
    await _db.into(_db.emailNotes).insert(
          EmailNotesCompanion.insert(
            id: noteId,
            accountId: accountId,
            messageId: messageId,
            noteText: text,
            serverId: '',
            createdAt: DateTime.now(),
            pendingUpload: const Value(true),
          ),
        );
    final emailId = await _emailIdForMessage(accountId, messageId);
    unawaited(
      _appLogger?.info(
        'note.added',
        'Note added',
        accountId: accountId,
        emailId: emailId,
        data: {
          'noteId': noteId,
          'messageId': messageId,
          'transport': account.type.name,
        },
      ),
    );
    _kickPush(accountId);
  }

  @override
  Future<void> deleteNote(String noteId) async {
    final noteRow = await (_db.select(_db.emailNotes)
          ..where((t) => t.id.equals(noteId)))
        .getSingleOrNull();
    if (noteRow == null) return;

    final emailId =
        await _emailIdForMessage(noteRow.accountId, noteRow.messageId);
    final data = {
      'noteId': noteRow.id,
      'messageId': noteRow.messageId,
      'serverId': noteRow.serverId,
    };

    final account = await _accounts.getAccount(noteRow.accountId);
    if (account == null) {
      await (_db.delete(_db.emailNotes)..where((t) => t.id.equals(noteId)))
          .go();
      unawaited(
        _appLogger?.warn(
          'note.deleted',
          'Note deleted locally only (account missing)',
          accountId: noteRow.accountId,
          emailId: emailId,
          data: data,
        ),
      );
      return;
    }

    // Offline-first: hidden at once; the row stays as a tombstone until the
    // server copy is gone, so a sync in between cannot bring it back.
    await (_db.update(_db.emailNotes)..where((t) => t.id.equals(noteId)))
        .write(const EmailNotesCompanion(pendingDelete: Value(true)));
    unawaited(
      _appLogger?.info(
        'note.deleted',
        'Note deleted',
        accountId: account.id,
        emailId: emailId,
        data: {...data, 'transport': account.type.name},
      ),
    );
    _kickPush(account.id);
  }

  // ── Push (local → server) ────────────────────────────────────────────────

  /// Uploads notes added locally and removes the server copies of notes
  /// deleted locally. Connects only when something is pending. A failure on
  /// one note is logged and leaves it pending; connection failures throw.
  /// Callers hold [_exclusive] for the account.
  Future<void> _pushPending(
    account_model.Account account,
    String password,
  ) async {
    if (!_pushEnabled) return;
    final pending = await (_db.select(_db.emailNotes)
          ..where(
            (t) =>
                t.accountId.equals(account.id) &
                (t.pendingUpload.equals(true) | t.pendingDelete.equals(true)),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();
    if (pending.isEmpty) return;
    // A note deleted before its upload is not uploaded; the delete step
    // still looks for a server copy, in case an earlier upload got through
    // without its answer reaching us.
    final uploads = [
      for (final r in pending)
        if (r.pendingUpload && !r.pendingDelete) r,
    ];
    final deletes = [
      for (final r in pending)
        if (r.pendingDelete) r,
    ];
    switch (account.type) {
      case account_model.AccountType.imap:
        await _pushPendingImap(account, password, uploads, deletes);
      case account_model.AccountType.jmap:
        await _pushPendingJmap(account, password, uploads, deletes);
    }
  }

  /// Marks [row] as on the server under [serverId]. Leaves a tombstone set
  /// meanwhile in place: the delete step removes the copy just made.
  Future<void> _markUploaded(EmailNoteRow row, String serverId) async {
    await (_db.update(_db.emailNotes)..where((t) => t.id.equals(row.id))).write(
      EmailNotesCompanion(
        pendingUpload: const Value(false),
        serverId: Value(serverId),
      ),
    );
    final emailId = await _emailIdForMessage(row.accountId, row.messageId);
    unawaited(
      _appLogger?.info(
        'note.pushed',
        'Note uploaded to the server',
        accountId: row.accountId,
        emailId: emailId,
        data: {'noteId': row.id, 'serverId': serverId},
      ),
    );
  }

  Future<void> _logPushFailed(EmailNoteRow row, String op, Object e) async {
    final emailId = await _emailIdForMessage(row.accountId, row.messageId);
    unawaited(
      _appLogger?.warn(
        'note.push.failed',
        'Could not $op the note on the server; retrying on the next sync',
        accountId: row.accountId,
        emailId: emailId,
        data: {'noteId': row.id, 'error': e.toString()},
      ),
    );
  }

  Future<void> _dropTombstone(EmailNoteRow row) =>
      (_db.delete(_db.emailNotes)..where((t) => t.id.equals(row.id))).go();

  Future<void> _pushPendingImap(
    account_model.Account account,
    String password,
    List<EmailNoteRow> uploads,
    List<EmailNoteRow> deletes,
  ) async {
    final client = await _imapConnect(
      account,
      _effectiveUsername(account),
      password,
    );
    try {
      if (uploads.isNotEmpty) {
        try {
          await client.createMailbox(_notesFolder);
        } catch (_) {
          // Already exists.
        }
      }
      try {
        await client.selectMailboxByPath(_notesFolder);
      } catch (e) {
        if (!isImapMailboxNotFound(e)) rethrow;
        // No Notes folder (and nothing to upload): nothing left to delete.
        for (final row in deletes) {
          await _dropTombstone(row);
        }
        return;
      }
      for (final row in uploads) {
        try {
          await _uploadNoteImap(client, row);
        } catch (e) {
          // Every further command on this client would fail the same way.
          if (isImapConnectionLost(e)) rethrow;
          await _logPushFailed(row, 'upload', e);
        }
      }
      for (final row in deletes) {
        try {
          final uids = await _imapUidsOfNote(client, row);
          if (uids.isNotEmpty) await deleteAndExpungeUids(client, uids);
          await _dropTombstone(row);
        } catch (e) {
          if (isImapConnectionLost(e)) rethrow;
          await _logPushFailed(row, 'delete', e);
        }
      }
    } finally {
      await closeImapClient(client);
    }
  }

  Future<void> _uploadNoteImap(imap.ImapClient client, EmailNoteRow row) async {
    // Idempotent: an earlier upload may have landed without its answer
    // reaching us (connection dropped after APPEND).
    final existing = await _imapUidsOfNote(client, row);
    if (existing.isNotEmpty) {
      await _markUploaded(row, existing.first.toString());
      return;
    }
    final builder = imap.MessageBuilder()
      ..subject = 'Note'
      ..text = row.noteText;
    builder.addHeader(_headerNoteFor, row.messageId);
    builder.addHeader(_headerNoteId, row.id);
    final appendResult = await client.appendMessage(
      builder.buildMimeMessage(),
      targetMailboxPath: _notesFolder,
    );
    final appended =
        appendResult.responseCodeAppendUid?.targetSequence.toList() ??
            const <int>[];
    // Without UIDPLUS there is no APPENDUID; find the copy by its header.
    final uids =
        appended.isNotEmpty ? appended : await _imapUidsOfNote(client, row);
    await _markUploaded(row, uids.isEmpty ? '' : uids.first.toString());
  }

  /// UIDs in the selected Notes folder holding note [row]: found by its
  /// note-id header, plus its cached UID when that message really carries
  /// the note id (a UID from before a UIDVALIDITY change may be another
  /// note's).
  Future<List<int>> _imapUidsOfNote(
    imap.ImapClient client,
    EmailNoteRow row,
  ) async {
    final uids = <int>{};
    try {
      final found = (await client.uidSearchMessages(
            searchCriteria: 'HEADER $_headerNoteId "${row.id}"',
          ))
              .matchingSequence
              ?.toList() ??
          const <int>[];
      uids.addAll(found);
    } catch (e) {
      // A server refusing HEADER search: fall back to the cached UID.
      if (isImapConnectionLost(e)) rethrow;
    }
    final cached = int.tryParse(row.serverId);
    if (cached == null || uids.contains(cached)) return uids.toList();
    final fetch = await client.uidFetchMessages(
      imap.MessageSequence.fromId(cached, isUid: true),
      '(UID BODY.PEEK[])',
    );
    for (final msg in fetch.messages) {
      if (msg.uid != cached) continue;
      if (msg.getHeaderValue(_headerNoteId)?.trim() != row.id) continue;
      uids.add(cached);
    }
    return uids.toList();
  }

  Future<void> _pushPendingJmap(
    account_model.Account account,
    String password,
    List<EmailNoteRow> uploads,
    List<EmailNoteRow> deletes,
  ) async {
    final jmapUrl = account.jmapUrl;
    // Like the pull: nothing to talk to. The rows stay pending.
    if (jmapUrl == null || jmapUrl.isEmpty) return;
    final jmap = await JmapClient.connect(
      httpClient: _httpClient,
      jmapUrl: Uri.parse(jmapUrl),
      username: _effectiveUsername(account),
      password: password,
    );
    if (uploads.isNotEmpty) {
      final target = await _findOrCreateNotesMailboxJmap(jmap);
      for (final row in uploads) {
        try {
          await _uploadNoteJmap(jmap, target, row);
        } catch (e) {
          await _logPushFailed(row, 'upload', e);
        }
      }
    }
    if (deletes.isEmpty) return;
    final mailboxId = await _findNotesMailboxJmap(jmap);
    for (final row in deletes) {
      try {
        await _deleteNoteJmap(jmap, mailboxId, row);
      } catch (e) {
        await _logPushFailed(row, 'delete', e);
      }
    }
  }

  /// JMAP ids of note [row]: its cached id (JMAP ids are never reused) plus
  /// any copy in the Notes mailbox carrying its note-id header.
  Future<Set<String>> _jmapIdsOfNote(
    JmapClient jmap,
    String? mailboxId,
    EmailNoteRow row,
  ) async {
    final ids = <String>{if (row.serverId.isNotEmpty) row.serverId};
    if (mailboxId == null) return ids;
    // The header filter is a loose "contains" match (RFC 8621 §4.4.1), so
    // each hit is checked for the exact note id before it counts. The query
    // and the check go in one request.
    final List<dynamic> resp;
    try {
      resp = await jmap.call([
        [
          'Email/query',
          {
            'accountId': jmap.accountId,
            'filter': {
              'inMailbox': mailboxId,
              'header': [_headerNoteId, row.id],
            },
          },
          'q',
        ],
        [
          'Email/get',
          {
            'accountId': jmap.accountId,
            '#ids': {'resultOf': 'q', 'name': 'Email/query', 'path': '/ids'},
            'properties': ['id', 'header:$_headerNoteId:asText'],
          },
          'g',
        ],
      ]);
    } on JmapException {
      // A server without header filtering: the cached id only.
      return ids;
    }
    final triple = resp.length > 1 ? resp[1] as List<dynamic> : const [];
    if (triple.isEmpty || triple[0] != 'Email/get') return ids;
    final list = (triple[1] as Map<String, dynamic>)['list'] as List? ?? [];
    for (final e in list) {
      final m = e as Map<String, dynamic>;
      final noteId = (m['header:$_headerNoteId:asText'] as String?)?.trim();
      if (noteId != row.id) continue;
      ids.add(m['id'] as String);
    }
    return ids;
  }

  Future<void> _uploadNoteJmap(
    JmapClient jmap,
    String mailboxId,
    EmailNoteRow row,
  ) async {
    // Idempotent: an earlier Email/set may have succeeded unseen.
    final existing = await _jmapIdsOfNote(jmap, mailboxId, row);
    if (existing.isNotEmpty) {
      await _markUploaded(row, existing.first);
      return;
    }
    const bodyPartId = '1';
    final setResp = await jmap.call([
      [
        'Email/set',
        {
          'accountId': jmap.accountId,
          'create': {
            'new-note': {
              'mailboxIds': {mailboxId: true},
              'subject': 'Note',
              'keywords': {r'$seen': true},
              'headers': [
                {'name': _headerNoteFor, 'value': ' ${row.messageId}'},
                {'name': _headerNoteId, 'value': ' ${row.id}'},
              ],
              'bodyValues': {
                bodyPartId: {
                  'value': row.noteText,
                  'isEncodingProblem': false,
                  'isTruncated': false,
                },
              },
              'textBody': [
                {'partId': bodyPartId, 'type': 'text/plain'},
              ],
            },
          },
        },
        '0',
      ],
    ]);
    final result = _responseArgs(setResp, 0, 'Email/set');
    final created = result['created'] as Map<String, dynamic>?;
    final newEmail = created?['new-note'] as Map<String, dynamic>?;
    final jmapEmailId = newEmail?['id'] as String?;
    if (jmapEmailId == null || jmapEmailId.isEmpty) {
      final notCreated = result['notCreated'] as Map<String, dynamic>?;
      throw JmapException(
        'Email/set did not create the note: ${notCreated?['new-note']}',
      );
    }
    await _markUploaded(row, jmapEmailId);
  }

  Future<void> _deleteNoteJmap(
    JmapClient jmap,
    String? mailboxId,
    EmailNoteRow row,
  ) async {
    final ids = await _jmapIdsOfNote(jmap, mailboxId, row);
    if (ids.isNotEmpty) {
      final resp = await jmap.call([
        [
          'Email/set',
          {
            'accountId': jmap.accountId,
            'destroy': ids.toList(),
          },
          '0',
        ],
      ]);
      final result = _responseArgs(resp, 0, 'Email/set');
      final notDestroyed =
          (result['notDestroyed'] as Map<String, dynamic>?) ?? const {};
      for (final entry in notDestroyed.entries) {
        final type = (entry.value as Map<String, dynamic>?)?['type'];
        if (type == 'notFound') continue; // already gone
        throw JmapException('Email/set could not destroy ${entry.key}: $type');
      }
    }
    await _dropTombstone(row);
  }

  // ── Upsert helpers ────────────────────────────────────────────────────────

  /// Decodes note headers/body from an IMAP fetched message and upserts the
  /// row. Returns the note id on success, or `null` when the message is
  /// missing the note-id header (not one of ours).
  Future<String?> _upsertNoteFromImapMessage(
    String accountId,
    imap.MimeMessage msg,
  ) async {
    final uid = msg.uid;
    if (uid == null) return null;
    final noteId = msg.getHeaderValue(_headerNoteId)?.trim();
    if (noteId == null || noteId.isEmpty) return null;
    final messageId = msg.getHeaderValue(_headerNoteFor)?.trim();
    if (messageId == null || messageId.isEmpty) return null;

    await _db.into(_db.emailNotes).insertOnConflictUpdate(
          EmailNotesCompanion.insert(
            id: noteId,
            accountId: accountId,
            messageId: messageId,
            noteText: msg.decodeTextPlainPart() ?? '',
            serverId: uid.toString(),
            createdAt: msg.decodeDate() ?? DateTime.now(),
            // On the server, so no longer waiting for upload. A local
            // tombstone (pendingDelete) is left as is: absent here.
            pendingUpload: const Value(false),
          ),
        );
    return noteId;
  }

  /// Decodes note headers/body from a JMAP Email/get response entry and
  /// upserts the row. Returns the note id on success, or `null` when the
  /// message is missing the note-id header.
  Future<String?> _upsertNoteFromJmapEmail(
    String accountId,
    Map<String, dynamic> m,
  ) async {
    final noteId = (m['header:$_headerNoteId:asText'] as String?)?.trim();
    if (noteId == null || noteId.isEmpty) return null;
    final messageId = (m['header:$_headerNoteFor:asText'] as String?)?.trim();
    if (messageId == null || messageId.isEmpty) return null;

    final jmapEmailId = m['id'] as String;
    final bodyValues = m['bodyValues'] as Map<String, dynamic>? ?? const {};
    final textBodyParts = m['textBody'] as List<dynamic>? ?? const [];
    var noteText = '';
    if (textBodyParts.isNotEmpty) {
      final partId =
          (textBodyParts.first as Map<String, dynamic>)['partId'] as String?;
      if (partId != null) {
        noteText = (bodyValues[partId] as Map<String, dynamic>?)?['value']
                as String? ??
            '';
      }
    }
    final createdAt =
        DateTime.tryParse(m['receivedAt'] as String? ?? '') ?? DateTime.now();

    await _db.into(_db.emailNotes).insertOnConflictUpdate(
          EmailNotesCompanion.insert(
            id: noteId,
            accountId: accountId,
            messageId: messageId,
            noteText: noteText,
            serverId: jmapEmailId,
            createdAt: createdAt,
            // On the server, so no longer waiting for upload. A local
            // tombstone (pendingDelete) is left as is: absent here.
            pendingUpload: const Value(false),
          ),
        );
    return noteId;
  }

  // ── DB helpers ────────────────────────────────────────────────────────────

  /// Logs (at warn level) that a cached note row was dropped during
  /// reconciliation, scoped to the mail it belonged to so it shows up in that
  /// mail's App Log. This is the breadcrumb that makes a "disappearing note"
  /// visible after the fact.
  Future<void> _logNoteRemoved(String event, EmailNoteRow row) async {
    final logger = _appLogger;
    if (logger == null) return;
    final emailId = await _emailIdForMessage(row.accountId, row.messageId);
    await logger.warn(
      event,
      'Cached note removed during sync reconciliation',
      accountId: row.accountId,
      emailId: emailId,
      data: {
        'noteId': row.id,
        'messageId': row.messageId,
        'serverId': row.serverId,
      },
    );
  }

  /// Drops the cached server notes of [accountId]. Keeps notes still
  /// waiting for their upload or server delete: those are local changes.
  Future<int> _clearNotesForAccount(String accountId, String event) async {
    final rows = await (_db.select(_db.emailNotes)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.pendingUpload.equals(false) &
                t.pendingDelete.equals(false),
          ))
        .get();
    for (final row in rows) {
      await _logNoteRemoved(event, row);
      await (_db.delete(_db.emailNotes)..where((t) => t.id.equals(row.id)))
          .go();
    }
    return rows.length;
  }

  Future<int> _pruneNotesForAccountNotIn(
    String accountId,
    Set<String> keptNoteIds,
  ) async {
    final rows = await (_db.select(_db.emailNotes)
          ..where((t) => t.accountId.equals(accountId)))
        .get();
    var removed = 0;
    for (final row in rows) {
      // Not on the server yet: absent from its listing by definition.
      if (row.pendingUpload) continue;
      if (!keptNoteIds.contains(row.id)) {
        await _logNoteRemoved('note.sync.pruned_not_in', row);
        await (_db.delete(_db.emailNotes)..where((t) => t.id.equals(row.id)))
            .go();
        removed++;
      }
    }
    return removed;
  }

  Future<int> _pruneNotesForAccountByServerId(
    String accountId,
    Set<String> keptServerIds,
  ) async {
    final rows = await (_db.select(_db.emailNotes)
          ..where((t) => t.accountId.equals(accountId)))
        .get();
    var removed = 0;
    for (final row in rows) {
      // A locally-added note on a server without UIDPLUS has an empty serverId
      // until a full sync repairs it (see [_uploadNoteImap]). It can never be in
      // the server UID set, so pruning it here would silently delete the note
      // the user just added. Skip it — the full scan reconciles it by note-id
      // header instead.
      if (row.serverId.isEmpty) continue;
      if (row.pendingUpload) continue;
      if (!keptServerIds.contains(row.serverId)) {
        await _logNoteRemoved('note.sync.pruned_by_server_id', row);
        await (_db.delete(_db.emailNotes)..where((t) => t.id.equals(row.id)))
            .go();
        removed++;
      }
    }
    return removed;
  }

  Future<void> _deleteNoteByServerId(
    String accountId,
    String serverId,
  ) async {
    final rows = await (_db.select(_db.emailNotes)
          ..where(
            (t) => t.accountId.equals(accountId) & t.serverId.equals(serverId),
          ))
        .get();
    for (final row in rows) {
      await _logNoteRemoved('note.sync.pruned_removed', row);
    }
    await (_db.delete(_db.emailNotes)
          ..where(
            (t) => t.accountId.equals(accountId) & t.serverId.equals(serverId),
          ))
        .go();
  }

  Future<Map<String, dynamic>?> _loadNotesCheckpoint(String accountId) async {
    final row = await (_db.select(_db.syncStates)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.resourceType.equals(_notesResourceType),
          ))
        .getSingleOrNull();
    if (row == null) return null;
    try {
      return jsonDecode(row.state) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveNotesCheckpoint(
    String accountId,
    Map<String, dynamic> checkpoint,
  ) async {
    await _db.into(_db.syncStates).insertOnConflictUpdate(
          SyncStatesCompanion.insert(
            accountId: accountId,
            resourceType: _notesResourceType,
            state: jsonEncode(checkpoint),
            syncedAt: DateTime.now(),
          ),
        );
  }

  /// Deletes the notes checkpoint; returns the number of rows removed.
  Future<int> _clearNotesCheckpoint(String accountId) async {
    return (_db.delete(_db.syncStates)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.resourceType.equals(_notesResourceType),
          ))
        .go();
  }

  // ── JMAP helpers ──────────────────────────────────────────────────────────

  Future<String?> _findNotesMailboxJmap(JmapClient jmap) async {
    final resp = await jmap.call([
      [
        'Mailbox/get',
        {'accountId': jmap.accountId, 'ids': null},
        '0',
      ],
    ]);
    final list = _responseArgs(resp, 0, 'Mailbox/get')['list'] as List<dynamic>;
    for (final m in list) {
      final map = m as Map<String, dynamic>;
      if (map['name'] == _notesFolder) return map['id'] as String?;
    }
    return null;
  }

  Future<String> _findOrCreateNotesMailboxJmap(JmapClient jmap) async {
    final existing = await _findNotesMailboxJmap(jmap);
    if (existing != null) return existing;

    final resp = await jmap.call([
      [
        'Mailbox/set',
        {
          'accountId': jmap.accountId,
          'create': {
            'new-notes': {'name': _notesFolder},
          },
        },
        '0',
      ],
    ]);
    final result = _responseArgs(resp, 0, 'Mailbox/set');
    final created = result['created'] as Map<String, dynamic>?;
    final newMailbox = created?['new-notes'] as Map<String, dynamic>?;
    final id = newMailbox?['id'] as String?;
    if (id == null) {
      throw JmapException(
        'Mailbox/set did not create the Notes mailbox: '
        '${result['notCreated']}',
      );
    }
    return id;
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

  /// Returns the raw `[methodName, args, callId]` triple without throwing on
  /// method-level errors — used when the caller needs to inspect the error
  /// type (e.g. to fall back to a full sync on `cannotCalculateChanges`).
  List<dynamic> _responseTriple(List<dynamic> responses, int index) =>
      responses[index] as List<dynamic>;

  EmailNote _toModel(EmailNoteRow row) => EmailNote(
        id: row.id,
        accountId: row.accountId,
        messageId: row.messageId,
        noteText: row.noteText,
        serverId: row.serverId,
        createdAt: row.createdAt,
        pendingUpload: row.pendingUpload,
      );

  // Generates a random UUID v4.
  static String _generateId() {
    final rng = math.Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 1
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}'
        '-${hex.substring(12, 16)}-${hex.substring(16, 20)}'
        '-${hex.substring(20)}';
  }
}

/// Internal sentinel: the JMAP server can no longer calculate incremental
/// changes from the stored state token — fall back to a full sync.
class _NotesCannotCalculateChanges implements Exception {
  const _NotesCannotCalculateChanges();
}
