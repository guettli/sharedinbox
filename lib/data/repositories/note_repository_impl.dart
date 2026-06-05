import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:http/http.dart' as http;

import 'package:sharedinbox/core/models/account.dart' as account_model;
import 'package:sharedinbox/core/models/note.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/note_repository.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:sharedinbox/data/jmap/jmap_client.dart';

const _notesFolder = 'Notes';
const _headerNoteFor = 'X-SharedInbox-Note-For';
const _headerNoteId = 'X-SharedInbox-Note-Id';

class NoteRepositoryImpl implements NoteRepository {
  NoteRepositoryImpl(
    this._db,
    this._accounts, {
    ImapConnectFn imapConnect = connectImap,
    http.Client? httpClient,
  })  : _imapConnect = imapConnect,
        _httpClient = httpClient ?? http.Client();

  final AppDatabase _db;
  final AccountRepository _accounts;
  final ImapConnectFn _imapConnect;
  final http.Client _httpClient;

  String _effectiveUsername(account_model.Account account) =>
      account.username.isNotEmpty ? account.username : account.email;

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
  Future<void> syncNotes(String accountId, String messageId) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null) return;
    final password = await _accounts.getPassword(accountId);

    switch (account.type) {
      case account_model.AccountType.imap:
        await _syncNotesImap(account, password, messageId);
      case account_model.AccountType.jmap:
        await _syncNotesJmap(account, password, messageId);
    }
  }

  Future<void> _syncNotesImap(
    account_model.Account account,
    String password,
    String messageId,
  ) async {
    final client = await _imapConnect(
      account,
      _effectiveUsername(account),
      password,
    );
    try {
      try {
        await client.selectMailboxByPath(_notesFolder);
      } catch (_) {
        // Notes folder doesn't exist — nothing to sync.
        return;
      }

      final escaped = messageId.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
      final searchResult = await client.uidSearchMessages(
        searchCriteria: 'HEADER $_headerNoteFor "$escaped"',
      );
      final uids = searchResult.matchingSequence?.toList() ?? [];

      if (uids.isEmpty) {
        await (_db.delete(_db.emailNotes)
              ..where(
                (t) =>
                    t.accountId.equals(account.id) &
                    t.messageId.equals(messageId),
              ))
            .go();
        return;
      }

      final seq = imap.MessageSequence.fromIds(uids, isUid: true);
      final fetch = await client.uidFetchMessages(seq, '(UID BODY.PEEK[])');

      final fetchedIds = <String>{};
      for (final msg in fetch.messages) {
        final uid = msg.uid;
        if (uid == null) continue;
        final noteId = msg.getHeaderValue(_headerNoteId)?.trim();
        if (noteId == null || noteId.isEmpty) continue;
        fetchedIds.add(noteId);
        await _db.into(_db.emailNotes).insertOnConflictUpdate(
              EmailNotesCompanion.insert(
                id: noteId,
                accountId: account.id,
                messageId: messageId,
                noteText: msg.decodeTextPlainPart() ?? '',
                serverId: uid.toString(),
                createdAt: msg.decodeDate() ?? DateTime.now(),
              ),
            );
      }

      // Remove stale local notes (deleted on the server).
      final local = await (_db.select(_db.emailNotes)
            ..where(
              (t) =>
                  t.accountId.equals(account.id) &
                  t.messageId.equals(messageId),
            ))
          .get();
      for (final note in local) {
        if (!fetchedIds.contains(note.id)) {
          await (_db.delete(_db.emailNotes)..where((t) => t.id.equals(note.id)))
              .go();
        }
      }
    } finally {
      await client.logout();
    }
  }

  Future<void> _syncNotesJmap(
    account_model.Account account,
    String password,
    String messageId,
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
      await (_db.delete(_db.emailNotes)
            ..where(
              (t) =>
                  t.accountId.equals(account.id) &
                  t.messageId.equals(messageId),
            ))
          .go();
      return;
    }

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

    if (ids.isEmpty) {
      await (_db.delete(_db.emailNotes)
            ..where(
              (t) =>
                  t.accountId.equals(account.id) &
                  t.messageId.equals(messageId),
            ))
          .go();
      return;
    }

    final getResp = await jmap.call([
      [
        'Email/get',
        {
          'accountId': jmap.accountId,
          'ids': ids,
          'properties': [
            'id',
            'receivedAt',
            'textBody',
            'bodyValues',
            'header:$_headerNoteFor:asText',
            'header:$_headerNoteId:asText',
          ],
          'fetchTextBodyValues': true,
        },
        '0',
      ],
    ]);
    final list =
        _responseArgs(getResp, 0, 'Email/get')['list'] as List<dynamic>;

    final fetchedIds = <String>{};
    for (final e in list) {
      final m = e as Map<String, dynamic>;
      final noteFor = (m['header:$_headerNoteFor:asText'] as String?)?.trim();
      if (noteFor != messageId) continue;
      final noteId = (m['header:$_headerNoteId:asText'] as String?)?.trim();
      if (noteId == null || noteId.isEmpty) continue;
      final jmapEmailId = m['id'] as String;

      final bodyValues = m['bodyValues'] as Map<String, dynamic>? ?? {};
      final textBodyParts = m['textBody'] as List<dynamic>? ?? [];
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
      fetchedIds.add(noteId);
      await _db.into(_db.emailNotes).insertOnConflictUpdate(
            EmailNotesCompanion.insert(
              id: noteId,
              accountId: account.id,
              messageId: messageId,
              noteText: noteText,
              serverId: jmapEmailId,
              createdAt: createdAt,
            ),
          );
    }

    // Remove stale local notes.
    final local = await (_db.select(_db.emailNotes)
          ..where(
            (t) =>
                t.accountId.equals(account.id) & t.messageId.equals(messageId),
          ))
        .get();
    for (final note in local) {
      if (!fetchedIds.contains(note.id)) {
        await (_db.delete(_db.emailNotes)..where((t) => t.id.equals(note.id)))
            .go();
      }
    }
  }

  // ── Add ───────────────────────────────────────────────────────────────────

  @override
  Future<void> addNote(
    String accountId,
    String messageId,
    String text,
  ) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null) return;
    final password = await _accounts.getPassword(accountId);
    final noteId = _generateId();

    switch (account.type) {
      case account_model.AccountType.imap:
        await _addNoteImap(account, password, messageId, noteId, text);
      case account_model.AccountType.jmap:
        await _addNoteJmap(account, password, messageId, noteId, text);
    }
  }

  Future<void> _addNoteImap(
    account_model.Account account,
    String password,
    String messageId,
    String noteId,
    String text,
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
  }

  // ── Delete ────────────────────────────────────────────────────────────────

  @override
  Future<void> deleteNote(String noteId) async {
    final noteRow = await (_db.select(_db.emailNotes)
          ..where((t) => t.id.equals(noteId)))
        .getSingleOrNull();
    if (noteRow == null) return;

    final account = await _accounts.getAccount(noteRow.accountId);
    if (account == null) {
      await (_db.delete(_db.emailNotes)..where((t) => t.id.equals(noteId)))
          .go();
      return;
    }
    final password = await _accounts.getPassword(account.id);

    switch (account.type) {
      case account_model.AccountType.imap:
        await _deleteNoteImap(account, password, noteRow);
      case account_model.AccountType.jmap:
        await _deleteNoteJmap(account, password, noteRow);
    }
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
