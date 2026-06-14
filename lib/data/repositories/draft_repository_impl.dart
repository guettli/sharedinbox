import 'package:drift/drift.dart';
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:http/http.dart' as http;

import 'package:sharedinbox/core/models/account.dart' as account_model;
import 'package:sharedinbox/core/models/draft.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/draft_repository.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:sharedinbox/data/jmap/jmap_client.dart';

const _draftsFolder = 'Drafts';

class DraftRepositoryImpl implements DraftRepository {
  DraftRepositoryImpl(
    this._db,
    this._accounts, {
    ImapConnectFn? imapConnect,
    http.Client? httpClient,
  })  : _imapConnect = imapConnect,
        _httpClient = httpClient;

  final AppDatabase _db;
  final AccountRepository _accounts;
  final ImapConnectFn? _imapConnect;
  final http.Client? _httpClient;

  @override
  Future<SavedDraft> saveDraft({
    int? id,
    String? accountId,
    String? replyToEmailId,
    required String toText,
    required String ccText,
    required String subjectText,
    required String bodyText,
  }) async {
    final now = DateTime.now();
    if (id != null) {
      await (_db.update(_db.drafts)..where((t) => t.id.equals(id))).write(
        DraftsCompanion(
          accountId: Value(accountId),
          replyToEmailId: Value(replyToEmailId),
          toText: Value(toText),
          ccText: Value(ccText),
          subjectText: Value(subjectText),
          bodyText: Value(bodyText),
          updatedAt: Value(now),
          dirty: const Value(true),
        ),
      );
      final row = await (_db.select(_db.drafts)..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      if (row != null) return _toModel(row);
      return SavedDraft(
        id: id,
        accountId: accountId,
        replyToEmailId: replyToEmailId,
        toText: toText,
        ccText: ccText,
        subjectText: subjectText,
        bodyText: bodyText,
        updatedAt: now,
      );
    }

    final newId = await _db.into(_db.drafts).insert(
          DraftsCompanion.insert(
            accountId: Value(accountId),
            replyToEmailId: Value(replyToEmailId),
            toText: Value(toText),
            ccText: Value(ccText),
            subjectText: Value(subjectText),
            bodyText: Value(bodyText),
            updatedAt: now,
            dirty: const Value(true),
          ),
        );
    return SavedDraft(
      id: newId,
      accountId: accountId,
      replyToEmailId: replyToEmailId,
      toText: toText,
      ccText: ccText,
      subjectText: subjectText,
      bodyText: bodyText,
      updatedAt: now,
    );
  }

  @override
  Future<SavedDraft?> findDraft({String? replyToEmailId}) async {
    final query = _db.select(_db.drafts);
    if (replyToEmailId == null) {
      query.where((t) => t.replyToEmailId.isNull());
    } else {
      query.where((t) => t.replyToEmailId.equals(replyToEmailId));
    }
    query.orderBy([(t) => OrderingTerm.desc(t.id)]);
    query.limit(1);
    final row = await query.getSingleOrNull();
    return row == null ? null : _toModel(row);
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
  Future<void> deleteDraft(int id) async {
    final row = await (_db.select(_db.drafts)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return;
    final accountId = row.accountId;
    final serverId = row.imapServerId ?? row.jmapServerId;
    if (accountId != null && serverId != null && serverId.isNotEmpty) {
      await _db.into(_db.draftTombstones).insert(
            DraftTombstonesCompanion.insert(
              accountId: accountId,
              serverId: serverId,
              createdAt: DateTime.now(),
            ),
          );
    }
    await (_db.delete(_db.drafts)..where((t) => t.id.equals(id))).go();
  }

  @override
  Future<void> syncDrafts(String accountId) async {
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
      try {
        await client.createMailbox(_draftsFolder);
      } catch (_) {
        // Already exists.
      }
      await client.selectMailboxByPath(_draftsFolder);

      await _pushTombstonesImap(client, account.id);
      await _pushDirtyImap(client, account);
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

  Future<void> _pushDirtyImap(
    imap.ImapClient client,
    account_model.Account account,
  ) async {
    final dirty = await (_db.select(_db.drafts)
          ..where((t) => t.accountId.equals(account.id) & t.dirty.equals(true)))
        .get();

    for (final row in dirty) {
      final builder = imap.MessageBuilder()
        ..from = [imap.MailAddress(account.displayName, account.email)]
        ..to = _parseAddresses(row.toText)
        ..cc = _parseAddresses(row.ccText)
        ..subject = row.subjectText
        ..text = row.bodyText;
      final mime = builder.buildMimeMessage();

      final appendResult = await client.appendMessage(
        mime,
        targetMailboxPath: _draftsFolder,
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

      await (_db.update(_db.drafts)..where((t) => t.id.equals(row.id))).write(
        DraftsCompanion(
          imapServerId: Value(newUid),
          dirty: const Value(false),
        ),
      );
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
    final knownUids = <String>{};
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
        await (_db.delete(_db.drafts)..where((t) => t.id.equals(row.id))).go();
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
      await _db.into(_db.drafts).insert(
            DraftsCompanion.insert(
              accountId: Value(accountId),
              toText: Value(_addressListToText(env?.to)),
              ccText: Value(_addressListToText(env?.cc)),
              subjectText: Value(env?.subject ?? ''),
              bodyText: Value(msg.decodeTextPlainPart() ?? ''),
              updatedAt: env?.date ?? DateTime.now(),
              imapServerId: Value(uid),
              dirty: const Value(false),
            ),
          );
    }
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

      await (_db.update(_db.drafts)..where((t) => t.id.equals(row.id))).write(
        DraftsCompanion(
          jmapServerId: Value(newId),
          dirty: const Value(false),
        ),
      );
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
        await (_db.delete(_db.drafts)..where((t) => t.id.equals(row.id))).go();
      }
    }

    final knownIds = <String>{};
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
            'textBody',
            'bodyValues',
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

      await _db.into(_db.drafts).insert(
            DraftsCompanion.insert(
              accountId: Value(accountId),
              toText: Value(_addressJsonToText(m['to'])),
              ccText: Value(_addressJsonToText(m['cc'])),
              subjectText: Value((m['subject'] as String?) ?? ''),
              bodyText: Value(bodyText),
              updatedAt: receivedAt,
              jmapServerId: Value(id),
              dirty: const Value(false),
            ),
          );
    }
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

  List<imap.MailAddress> _parseAddresses(String text) {
    if (text.trim().isEmpty) return [];
    return text
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .map((s) => imap.MailAddress('', s))
        .toList();
  }

  List<Map<String, dynamic>> _parseAddressesJmap(String text) {
    if (text.trim().isEmpty) return [];
    return text
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .map((s) => {'email': s})
        .toList();
  }

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
        subjectText: row.subjectText,
        bodyText: row.bodyText,
        updatedAt: row.updatedAt,
        imapServerId: row.imapServerId,
        jmapServerId: row.jmapServerId,
        dirty: row.dirty,
      );
}
