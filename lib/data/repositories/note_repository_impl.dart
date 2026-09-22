import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:http/http.dart' as http;

import 'package:sharedinbox/core/models/account.dart' as account_model;
import 'package:sharedinbox/core/models/note.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/note_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:sharedinbox/data/imap/imap_errors.dart';
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
  })  : _imapConnect = imapConnect,
        _httpClient = httpClient ?? http.Client(),
        _appLogger = appLogger;

  final AppDatabase _db;
  final AccountRepository _accounts;
  final ImapConnectFn _imapConnect;
  final http.Client _httpClient;
  final AppLogger? _appLogger;

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
                t.accountId.equals(accountId) & t.messageId.equals(messageId),
          )
          ..limit(1))
        .getSingleOrNull();
    return row?.id;
  }

  // ── Observe (local cache) ─────────────────────────────────────────────────

  @override
  Stream<List<EmailNote>> observeNotes(String accountId, String messageId) {
    return (_db.select(_db.emailNotes)
          ..where(
            (t) =>
                t.accountId.equals(accountId) & t.messageId.equals(messageId),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .watch()
        .map((rows) => rows.map(_toModel).toList());
  }

  // ── Sync (server → local cache) ──────────────────────────────────────────

  @override
  Future<void> syncAllNotes(String accountId) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null) return;
    final password = await _accounts.getPassword(accountId);

    switch (account.type) {
      case account_model.AccountType.imap:
        await _syncAllNotesImap(account, password);
      case account_model.AccountType.jmap:
        await _syncAllNotesJmap(account, password);
    }
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
          // Notes folder doesn't exist yet — clear any stale checkpoint and
          // drop orphaned local notes so the local cache mirrors reality.
          final wiped = await _clearNotesForAccount(
            account.id,
            'note.sync.folder_missing_wipe',
          );
          await _clearNotesCheckpoint(account.id);
          unawaited(
            _appLogger?.info(
              'note.sync.completed',
              'Note sync: Notes folder not found, cleared local cache',
              accountId: account.id,
              data: {'transport': 'imap', 'wiped': wiped},
            ),
          );
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

      final maxUid = serverUids.isEmpty ? lastUid : serverUids.reduce(math.max);
      await _saveNotesCheckpoint(account.id, {
        'uidValidity': uidValidity,
        'lastUid': maxUid,
      });
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
      await client.logout();
    }
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
      final wiped = await _clearNotesForAccount(
        account.id,
        'note.sync.folder_missing_wipe',
      );
      await _clearNotesCheckpoint(account.id);
      unawaited(
        _appLogger?.info(
          'note.sync.completed',
          'Note sync: Notes mailbox not found, cleared local cache',
          accountId: account.id,
          data: {'transport': 'jmap', 'wiped': wiped},
        ),
      );
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

    // Fetch bodies for anything newly added or updated in the Notes mailbox.
    final toFetch = <String>{
      for (final entry in added)
        (entry as Map<String, dynamic>)['id'] as String,
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
    final toRemove = {...destroyed, ...removed};
    for (final jmapId in toRemove) {
      await _deleteNoteByServerId(accountId, jmapId);
    }

    await _saveNotesCheckpoint(accountId, {
      'queryState': newQueryState,
      'emailState': newEmailState,
    });
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
    final password = await _accounts.getPassword(accountId);
    final noteId = _generateId();
    final emailId = await _emailIdForMessage(accountId, messageId);

    switch (account.type) {
      case account_model.AccountType.imap:
        await _addNoteImap(account, password, messageId, noteId, text, emailId);
      case account_model.AccountType.jmap:
        await _addNoteJmap(account, password, messageId, noteId, text, emailId);
    }
  }

  Future<void> _addNoteImap(
    account_model.Account account,
    String password,
    String messageId,
    String noteId,
    String text,
    String? emailId,
  ) async {
    final client = await _imapConnect(
      account,
      _effectiveUsername(account),
      password,
    );
    try {
      try {
        await client.createMailbox(_notesFolder);
      } catch (_) {
        // Already exists.
      }

      final builder = imap.MessageBuilder()
        ..subject = 'Note'
        ..text = text;
      builder.addHeader(_headerNoteFor, messageId);
      builder.addHeader(_headerNoteId, noteId);
      final mime = builder.buildMimeMessage();

      final appendResult = await client.appendMessage(
        mime,
        targetMailboxPath: _notesFolder,
      );
      final uidList =
          appendResult.responseCodeAppendUid?.targetSequence.toList();
      final serverId = (uidList != null && uidList.isNotEmpty)
          ? uidList.first.toString()
          : '';

      await _db.into(_db.emailNotes).insertOnConflictUpdate(
            EmailNotesCompanion.insert(
              id: noteId,
              accountId: account.id,
              messageId: messageId,
              noteText: text,
              serverId: serverId,
              createdAt: DateTime.now(),
            ),
          );

      unawaited(
        _appLogger?.info(
          'note.added',
          'Note added (imap)',
          accountId: account.id,
          emailId: emailId,
          data: {
            'noteId': noteId,
            'messageId': messageId,
            'serverId': serverId,
            'transport': 'imap',
          },
        ),
      );
      if (serverId.isEmpty) {
        // The server didn't return an APPENDUID (no UIDPLUS), so we cached the
        // note without its server UID. A later full sync repairs it by matching
        // the note-id header; until then the prune-by-serverId reconciliation
        // must not treat this row as an orphan (see
        // [_pruneNotesForAccountByServerId]).
        unawaited(
          _appLogger?.warn(
            'note.add.no_server_id',
            'Note appended without an APPENDUID (server lacks UIDPLUS); '
                'serverId left empty until the next full sync',
            accountId: account.id,
            emailId: emailId,
            data: {'noteId': noteId, 'messageId': messageId},
          ),
        );
      }
    } finally {
      await client.logout();
    }
  }

  Future<void> _addNoteJmap(
    account_model.Account account,
    String password,
    String messageId,
    String noteId,
    String text,
    String? emailId,
  ) async {
    final jmapUrl = account.jmapUrl;
    if (jmapUrl == null || jmapUrl.isEmpty) {
      throw Exception('JMAP account ${account.id} has no jmapUrl');
    }

    final jmap = await JmapClient.connect(
      httpClient: _httpClient,
      jmapUrl: Uri.parse(jmapUrl),
      username: _effectiveUsername(account),
      password: password,
    );

    final mailboxId = await _findOrCreateNotesMailboxJmap(jmap);

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
                {'name': _headerNoteFor, 'value': ' $messageId'},
                {'name': _headerNoteId, 'value': ' $noteId'},
              ],
              'bodyValues': {
                bodyPartId: {
                  'value': text,
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
    final jmapEmailId = newEmail?['id'] as String? ?? '';

    await _db.into(_db.emailNotes).insertOnConflictUpdate(
          EmailNotesCompanion.insert(
            id: noteId,
            accountId: account.id,
            messageId: messageId,
            noteText: text,
            serverId: jmapEmailId,
            createdAt: DateTime.now(),
          ),
        );

    unawaited(
      _appLogger?.info(
        'note.added',
        'Note added (jmap)',
        accountId: account.id,
        emailId: emailId,
        data: {
          'noteId': noteId,
          'messageId': messageId,
          'serverId': jmapEmailId,
          'transport': 'jmap',
        },
      ),
    );
    if (jmapEmailId.isEmpty) {
      unawaited(
        _appLogger?.warn(
          'note.add.no_server_id',
          'JMAP Email/set returned no created id; serverId left empty',
          accountId: account.id,
          emailId: emailId,
          data: {'noteId': noteId, 'messageId': messageId},
        ),
      );
    }
  }

  // ── Delete ────────────────────────────────────────────────────────────────

  @override
  Future<void> deleteNote(String noteId) async {
    final noteRow = await (_db.select(_db.emailNotes)
          ..where((t) => t.id.equals(noteId)))
        .getSingleOrNull();
    if (noteRow == null) return;

    final emailId =
        await _emailIdForMessage(noteRow.accountId, noteRow.messageId);

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
          data: {
            'noteId': noteRow.id,
            'messageId': noteRow.messageId,
            'serverId': noteRow.serverId,
          },
        ),
      );
      return;
    }
    final password = await _accounts.getPassword(account.id);

    switch (account.type) {
      case account_model.AccountType.imap:
        await _deleteNoteImap(account, password, noteRow);
      case account_model.AccountType.jmap:
        await _deleteNoteJmap(account, password, noteRow);
    }

    unawaited(
      _appLogger?.info(
        'note.deleted',
        'Note deleted (${account.type.name})',
        accountId: account.id,
        emailId: emailId,
        data: {
          'noteId': noteRow.id,
          'messageId': noteRow.messageId,
          'serverId': noteRow.serverId,
          'transport': account.type.name,
        },
      ),
    );
  }

  Future<void> _deleteNoteImap(
    account_model.Account account,
    String password,
    EmailNoteRow noteRow,
  ) async {
    final client = await _imapConnect(
      account,
      _effectiveUsername(account),
      password,
    );
    try {
      try {
        await client.selectMailboxByPath(_notesFolder);
        final uid = int.tryParse(noteRow.serverId);
        if (uid != null) {
          final seq = imap.MessageSequence.fromId(uid, isUid: true);
          await client.uidMarkDeleted(seq);
          await client.uidExpunge(seq);
        }
      } catch (_) {
        // Notes folder gone or message already deleted — clean up locally.
      }
    } finally {
      await client.logout();
    }
    await (_db.delete(_db.emailNotes)..where((t) => t.id.equals(noteRow.id)))
        .go();
  }

  Future<void> _deleteNoteJmap(
    account_model.Account account,
    String password,
    EmailNoteRow noteRow,
  ) async {
    final jmapUrl = account.jmapUrl;
    if (jmapUrl == null || jmapUrl.isEmpty) return;

    final jmap = await JmapClient.connect(
      httpClient: _httpClient,
      jmapUrl: Uri.parse(jmapUrl),
      username: _effectiveUsername(account),
      password: password,
    );

    if (noteRow.serverId.isNotEmpty) {
      await jmap.call([
        [
          'Email/set',
          {
            'accountId': jmap.accountId,
            'destroy': [noteRow.serverId],
          },
          '0',
        ],
      ]);
    }

    await (_db.delete(_db.emailNotes)..where((t) => t.id.equals(noteRow.id)))
        .go();
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

  Future<int> _clearNotesForAccount(String accountId, String event) async {
    final rows = await (_db.select(_db.emailNotes)
          ..where((t) => t.accountId.equals(accountId)))
        .get();
    for (final row in rows) {
      await _logNoteRemoved(event, row);
    }
    await (_db.delete(_db.emailNotes)
          ..where((t) => t.accountId.equals(accountId)))
        .go();
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
      // until a full sync repairs it (see [_addNoteImap]). It can never be in
      // the server UID set, so pruning it here would silently delete the note
      // the user just added. Skip it — the full scan reconciles it by note-id
      // header instead.
      if (row.serverId.isEmpty) continue;
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

  Future<void> _clearNotesCheckpoint(String accountId) async {
    await (_db.delete(_db.syncStates)
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
    return newMailbox?['id'] as String? ?? _notesFolder;
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
