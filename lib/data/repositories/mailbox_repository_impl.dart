import 'dart:async';
import 'dart:convert';
import 'dart:math' show max;

import 'package:drift/drift.dart';
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:http/http.dart' as http;

import 'package:sharedinbox/core/models/account.dart' as account_model;
import 'package:sharedinbox/core/models/mailbox.dart' as model;
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/core/utils/logger.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/db/mailbox_fold.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:sharedinbox/data/imap/mailbox_path_codec.dart';
import 'package:sharedinbox/data/imap/message_id_search.dart';
import 'package:sharedinbox/data/jmap/jmap_client.dart';
import 'package:sharedinbox/data/repositories/email_state_writer.dart';
import 'package:sharedinbox/data/repositories/mailbox_state_writer.dart';
import 'package:sharedinbox/data/repositories/thread_aggregate.dart';

/// The change in a mailbox `m`'s unread count (SQL, correlated on `m`) that
/// the stored server count `m.unread_count` does not reflect yet
/// (SYNC-REDESIGN.md §7): over the rows of its account with a change that
/// is queued, being sent, stuck, parked or a counterpart's shadow, or acked
/// after the count was read (`ack_seq > m.unread_seq`), the unread rows the
/// app shows in `m` minus the unread rows the server has in `m` as last
/// read (`srv_*`). This covers read/unread changes, and moves, deletes and
/// snoozes of unread mail, each once; a change the count already reflects
/// is not counted again, so the number does not flicker back. Virtual rows
/// (no server copy) are left out: the server's count never had them.
///
/// Limits: `srv_*` is the server's state as last read, not as of the
/// count's read. A row read again after the count (its change confirmed
/// and dropped) adds nothing any more, so until the next count read the
/// folder shows the older server count; a count read before a mail
/// arrived can make the sum negative ([MailboxRepositoryImpl] shows 0 and
/// logs it). The query is driven from the foldable ops
/// (`pending_changes_resource_state`, then the `emails` primary key), so
/// re-running it on every write costs one probe per queued change and
/// mailbox.
const unreadDeltaSql = 'COALESCE((SELECT SUM(c.n) FROM ('
    'SELECT e.id, e.account_id, e.mailbox_path AS path, 1 AS n '
    'FROM emails e WHERE e.is_seen = 0 AND e.is_local = 0 '
    'AND e.id IN ($_queuedRowsSql) '
    'UNION ALL '
    'SELECT e.id, e.account_id, e.srv_mailbox_path AS path, -1 AS n '
    'FROM emails e WHERE e.srv_is_seen = 0 AND e.srv_gone = 0 '
    'AND e.is_local = 0 '
    'AND e.id IN ($_queuedRowsSql)'
    ') c WHERE c.account_id = m.account_id AND c.path = m.path '
    'AND EXISTS (SELECT 1 FROM pending_changes p WHERE p.resource_id = c.id '
    "AND (p.state IN ('pending', 'inflight', 'stuck', 'parked', 'shadow') "
    "OR (p.state = 'acked' AND p.ack_seq > m.unread_seq)))), 0)";

const _queuedRowsSql = 'SELECT resource_id FROM pending_changes '
    "WHERE state IN ('pending', 'inflight', 'stuck', 'parked', 'shadow', "
    "'acked')";

class MailboxRepositoryImpl implements MailboxRepository {
  MailboxRepositoryImpl(
    this._db,
    this._accounts, {
    ImapConnectFn imapConnect = connectImap,
    http.Client? httpClient,
    AppLogger? appLogger,
  })  : _imapConnect = imapConnect,
        _httpClient = httpClient ?? http.Client(),
        _appLogger = appLogger,
        _writer = MailboxStateWriter(_db, appLogger: appLogger);

  final AppDatabase _db;
  final AccountRepository _accounts;
  final ImapConnectFn _imapConnect;
  final http.Client _httpClient;
  final AppLogger? _appLogger;

  /// The only writer of `mailboxes` (SYNC-REDESIGN.md §7).
  final MailboxStateWriter _writer;

  // Lives as long as the repository, like the email repository's.
  // ignore: close_sinks
  final _queuedCtrl = StreamController<String>.broadcast();

  @override
  Stream<String> get onChangesQueued => _queuedCtrl.stream;

  String _effectiveUsername(account_model.Account account) =>
      account.username.isNotEmpty ? account.username : account.email;

  /// The mailboxes, each with the unread count the UI shows: the server's
  /// count plus the effect of the user's changes it does not reflect yet
  /// (SYNC-REDESIGN.md §7, [unreadDeltaSql]).
  @override
  Stream<List<model.Mailbox>> observeMailboxes(String? accountId) {
    return _db
        .customSelect(
          'SELECT m.*, ($unreadDeltaSql) AS unread_delta FROM mailboxes m '
          'WHERE ${mailboxShownSql('m')}'
          '${accountId == null ? '' : ' AND m.account_id = ?1'} '
          'ORDER BY m.path',
          variables: [if (accountId != null) Variable.withString(accountId)],
          readsFrom: {_db.mailboxes, _db.emails, _db.pendingChanges},
        )
        .watch()
        .map(
          (rows) => [
            for (final r in rows)
              _shownUnread(
                _db.mailboxes.map(r.data),
                r.read<int>('unread_delta'),
              ),
          ],
        );
  }

  /// Folders whose shown unread count came out negative, logged once each.
  final _negativeLogged = <String>{};

  /// [row] with the unread count the UI shows (server count plus
  /// [delta]); a negative sum (a count read before mail it now has, see
  /// [unreadDeltaSql]) shows as 0 and is logged once per folder.
  model.Mailbox _shownUnread(MailboxRow row, int delta) {
    final shown = row.unreadCount + delta;
    if (shown < 0 && _negativeLogged.add(row.id)) {
      unawaited(
        _appLogger?.warn(
          'mailbox.unread_negative',
          'The unread count of "${row.name}" came out at $shown (server '
              '${row.unreadCount}, local changes $delta); showing 0 until '
              'the next count read',
          accountId: row.accountId,
          mailboxPath: row.path,
          data: {'server': row.unreadCount, 'delta': delta},
        ),
      );
    }
    return _toModel(row, unreadDelta: delta);
  }

  @override
  Future<model.Mailbox?> findMailboxByRole(
    String accountId,
    String role,
  ) async {
    final rows = await _db.customSelect(
      'SELECT m.* FROM mailboxes m WHERE m.account_id = ?1 AND m.role = ?2 '
      'AND ${mailboxShownSql('m')} LIMIT 1',
      variables: [Variable.withString(accountId), Variable.withString(role)],
      readsFrom: {_db.mailboxes, _db.pendingChanges},
    ).get();
    return rows.isEmpty ? null : _toModel(_db.mailboxes.map(rows.first.data));
  }

  @override
  Future<int> syncMailboxes(String accountId) async {
    final account = (await _accounts.getAccount(accountId))!;
    final password = await _accounts.getPassword(accountId);
    switch (account.type) {
      case account_model.AccountType.imap:
        return _syncMailboxesImap(account, password);
      case account_model.AccountType.jmap:
        return _syncMailboxesJmap(account, password);
    }
  }

  // ── IMAP ──────────────────────────────────────────────────────────────────

  Future<int> _syncMailboxesImap(
    account_model.Account account,
    String password,
  ) async {
    final client = await _imapConnect(
      account,
      _effectiveUsername(account),
      password,
    );
    try {
      // Before LIST: a folder created or renamed by a flush after this does
      // not count as gone, and an old path it renamed away is not stored
      // again (SYNC-REDESIGN.md §4.3).
      final listSeq = await EmailStateWriter(_db).nextReadSeq();
      final mailboxes = await client.listMailboxes(recursive: true);
      final separator = imapSeparatorOf(mailboxes);
      await _writer.recordImapSeparator(account.id, separator);

      // Pre-load existing DB roles so we can preserve manually-set roles for
      // folders the server doesn't tag with a special-use attribute.
      final existingRows = await (_db.select(
        _db.mailboxes,
      )..where((t) => t.accountId.equals(account.id)))
          .get();
      final existingRoles = {for (final r in existingRows) r.path: r.role};

      // Reconcile server-side deletions: any locally cached mailbox that the
      // server no longer lists has been deleted upstream, so drop it (and its
      // cached emails / sync state) before upserting the survivors.
      final serverPaths = mailboxes.map((mb) => mb.path).toSet();
      // A rename whose answer was lost but that the listing shows done
      // moves the folder first, so it is not taken for deleted.
      await _writer.completeLostRenames(account.id, serverPaths);
      // A folder another client renamed or moved: its mail and the changes
      // queued for it follow instead of failing as "folder removed".
      await _followRenamesElsewhere(client, account.id, mailboxes, listSeq);
      await _prune(account.id, serverPaths, listSeq);
      final renamedAway = await _writer.renamedAwaySince(account.id, listSeq);

      for (final mb in mailboxes) {
        final path = mb.path;
        // An old path (or a subfolder of one) a rename acked after this
        // listing started moved away from.
        if (MailboxStateWriter.isRenamedAway(path, renamedAway, separator)) {
          continue;
        }

        var unread = 0;
        var total = 0;
        // The read sequence of this count (SYNC-REDESIGN.md §7).
        final readSeq = await EmailStateWriter(_db).nextReadSeq();
        try {
          final status = await client.statusMailbox(mb, [
            imap.StatusFlags.messages,
            imap.StatusFlags.unseen,
          ]);
          unread = status.messagesUnseen;
          total = status.messagesExists;
        } catch (e, stack) {
          log('STATUS skipped for $path: $e');
          // Surface the failure in the App Log so a folder that silently shows
          // no count (falling back to 0) is discoverable (#498).
          unawaited(
            _appLogger?.warn(
              'mailbox_count_failed',
              'Could not compute message count for "$path"',
              accountId: account.id,
              mailboxPath: path,
              error: e,
              stack: stack,
            ),
          );
        }

        // Use the server-assigned role when available; fall back to the
        // existing DB role so that manually-created folders (e.g. a user
        // who just created their Archive folder) keep their role across syncs
        // when the IMAP server does not expose a special-use attribute.
        final role = _imapRole(mb) ?? existingRoles[path];

        // IMAP paths are already hierarchical + human-readable, so the
        // display path mirrors `path` (with a pending rename's name).
        await _writer.writeServer(
          accountId: account.id,
          path: path,
          name: mb.name,
          role: role,
          parentId: null,
          unreadCount: unread,
          totalCount: total,
          unreadSeq: readSeq,
          readSeq: listSeq,
        );
      }
      await _writer.rebuildDisplayPaths(account.id);
      await _afterListing(account.id, listSeq);
      return mailboxes.length;
    } finally {
      await closeImapClient(client);
    }
  }

  // ── JMAP ──────────────────────────────────────────────────────────────────

  Future<int> _syncMailboxesJmap(
    account_model.Account account,
    String password,
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

    final storedState = await _loadSyncState(account.id, 'Mailbox');

    if (storedState == null) {
      return _jmapFullMailboxSync(account.id, jmap);
    } else {
      return _jmapIncrementalMailboxSync(account.id, jmap, storedState);
    }
  }

  /// First-time sync: fetch all mailboxes and persist state.
  Future<int> _jmapFullMailboxSync(String accountId, JmapClient jmap) async {
    final readSeq = await EmailStateWriter(_db).nextReadSeq();
    final responses = await jmap.call([
      [
        'Mailbox/get',
        {'accountId': jmap.accountId, 'ids': null},
        '0',
      ],
    ]);

    final result = _responseArgs(responses, 0, 'Mailbox/get');
    final mailboxes = result['list'] as List<dynamic>;
    final newState = result['state'] as String;

    // Reconcile server-side deletions: for JMAP, `path` stores the opaque
    // server mailbox id, so we filter against the ids in the returned list.
    final serverIds = {
      for (final mb in mailboxes) (mb as Map<String, dynamic>)['id'] as String,
    };
    await _prune(accountId, serverIds, readSeq);

    await _upsertJmapMailboxes(accountId, mailboxes, readSeq: readSeq);
    await _afterListing(accountId, readSeq);
    await _saveSyncState(accountId, 'Mailbox', newState);
    log(
      'JMAP full mailbox sync: ${mailboxes.length} mailboxes, state=$newState',
    );
    return mailboxes.length;
  }

  /// Incremental sync using Mailbox/changes since [sinceState].
  Future<int> _jmapIncrementalMailboxSync(
    String accountId,
    JmapClient jmap,
    String sinceState,
  ) async {
    // Before the requests: the counts read below are at least this new.
    final readSeq = await EmailStateWriter(_db).nextReadSeq();
    final responses = await jmap.call([
      [
        'Mailbox/changes',
        {'accountId': jmap.accountId, 'sinceState': sinceState},
        '0',
      ],
    ]);

    final changes = _responseArgs(responses, 0, 'Mailbox/changes');
    final newState = changes['newState'] as String;
    final created = List<String>.from(changes['created'] as List? ?? []);
    final updated = List<String>.from(changes['updated'] as List? ?? []);
    final destroyed = List<String>.from(changes['destroyed'] as List? ?? []);

    // Fetch details for created + updated mailboxes, plus any of their
    // ancestors not already cached, so displayPath can be built from real
    // names instead of leaking an opaque parent id into the UI (#605).
    final toFetch = [...created, ...updated];
    if (toFetch.isNotEmpty) {
      final fetched = await _fetchJmapMailboxesWithAncestors(
        jmap,
        accountId,
        toFetch,
      );
      await _upsertJmapMailboxes(accountId, fetched, readSeq: readSeq);
    }

    // Remove destroyed mailboxes (and their cached emails / sync state).
    for (final jmapId in destroyed) {
      await removeLocalMailbox(
        _db,
        accountId,
        jmapId,
        appLogger: _appLogger,
      );
    }

    await _afterListing(accountId, readSeq);
    await _saveSyncState(accountId, 'Mailbox', newState);
    log(
      'JMAP incremental mailbox sync: +${created.length} '
      '~${updated.length} -${destroyed.length}, state=$newState',
    );
    return toFetch.length + destroyed.length;
  }

  /// Fetches [ids] via `Mailbox/get`, then follows every `parentId` that is
  /// neither in the response nor already cached locally, repeating until the
  /// ancestor chain is closed. An incremental sync only reports the mailboxes
  /// that changed, so a child whose (unchanged) parent isn't cached would
  /// otherwise have no name for that parent and render it as the opaque server
  /// id — the recurring "a instead of folder name" bug (#605).
  Future<List<dynamic>> _fetchJmapMailboxesWithAncestors(
    JmapClient jmap,
    String accountId,
    List<String> ids,
  ) async {
    final cachedRows = await (_db.select(_db.mailboxes)
          ..where((t) => t.accountId.equals(accountId)))
        .get();
    final cachedIds = {for (final r in cachedRows) r.path};

    final collected = <String, Map<String, dynamic>>{};
    final requested = <String>{};
    var pending = ids.toSet();
    while (pending.isNotEmpty) {
      requested.addAll(pending);
      final getResponses = await jmap.call([
        [
          'Mailbox/get',
          {'accountId': jmap.accountId, 'ids': pending.toList()},
          '1',
        ],
      ]);
      final getResult = _responseArgs(getResponses, 0, 'Mailbox/get');
      for (final mb in getResult['list'] as List<dynamic>) {
        final m = mb as Map<String, dynamic>;
        collected[m['id'] as String] = m;
      }
      final next = <String>{};
      for (final m in collected.values) {
        final parent = m['parentId'] as String?;
        if (parent == null || parent.isEmpty) continue;
        if (collected.containsKey(parent)) continue;
        if (cachedIds.contains(parent)) continue;
        // Skip ids we already asked for: a parent the server didn't return
        // (e.g. concurrently deleted) must not loop us forever.
        if (requested.contains(parent)) continue;
        next.add(parent);
      }
      pending = next;
    }
    return collected.values.toList();
  }

  static String? _fallbackJmapRole(String? name) {
    if (name == null) return null;
    final lowerName = name.toLowerCase();
    if (lowerName == 'inbox') return 'inbox';
    if (lowerName == 'archive') return 'archive';
    if (lowerName == 'drafts' || lowerName == 'draft') return 'drafts';
    if (lowerName == 'trash' ||
        lowerName == 'deleted items' ||
        lowerName == 'deleted messages' ||
        lowerName == 'bin') {
      return 'trash';
    }
    if (lowerName == 'sent' ||
        lowerName == 'sent items' ||
        lowerName == 'sent messages') {
      return 'sent';
    }
    if (lowerName == 'junk' ||
        lowerName == 'junk mail' ||
        lowerName == 'spam') {
      return 'junk';
    }
    // Not a registered role, but the app's own Snoozed folder (created
    // without a role where the server refuses it) gets the snooze icon.
    if (lowerName == 'snoozed') return 'snoozed';
    return null;
  }

  /// [readSeq]: the read sequence taken before the requests that returned
  /// [mailboxes], stored with their unread counts (SYNC-REDESIGN.md §7).
  Future<void> _upsertJmapMailboxes(
    String accountId,
    List<dynamic> mailboxes, {
    required int readSeq,
  }) async {
    // For JMAP, `path` stores the opaque mailbox ID (so Email rows can
    // reference it via mailboxPath) but the UI wants the hierarchical,
    // human-readable path — e.g. "Archive/2026": the writer builds it from
    // each mailbox's `parentId` chain of (effective) names once the batch
    // is stored. A parent neither in this batch nor cached truncates the
    // path rather than embedding the opaque parent id, so we never store
    // "a/Work" (#605).
    // A folder deleted (acked) after these were read: a stale answer must
    // not bring it back (SYNC-REDESIGN.md §4.3).
    final deletedSince = await _writer.renamedAwaySince(accountId, readSeq);
    for (final mb in mailboxes) {
      final m = mb as Map<String, dynamic>;
      final jmapId = m['id'] as String;
      if (deletedSince.contains(jmapId)) continue;
      final name = m['name'] as String? ?? jmapId;
      final role = m['role'] as String? ?? _fallbackJmapRole(name);
      if (m['totalEmails'] is! int || m['unreadEmails'] is! int) {
        // The server omitted the count properties; we fall back to 0 but log it
        // so a folder that shows no real count is discoverable (#498).
        unawaited(
          _appLogger?.warn(
            'mailbox_count_failed',
            'JMAP mailbox "$name" is missing totalEmails/unreadEmails',
            accountId: accountId,
            mailboxPath: jmapId,
          ),
        );
      }
      await _writer.writeServer(
        accountId: accountId,
        path: jmapId,
        name: name,
        role: role,
        parentId: m['parentId'] as String?,
        unreadCount: (m['unreadEmails'] as int?) ?? 0,
        totalCount: (m['totalEmails'] as int?) ?? 0,
        unreadSeq: readSeq,
        readSeq: readSeq,
        displayPath: name,
      );
    }
    // When a parent's name changes, every descendant's displayPath goes
    // stale: the writer recomputes every one that changed.
    await _writer.rebuildDisplayPaths(accountId);
  }

  // ── sync_state helpers ────────────────────────────────────────────────────

  Future<String?> _loadSyncState(String accountId, String resourceType) async {
    final row = await (_db.select(_db.syncStates)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.resourceType.equals(resourceType),
          ))
        .getSingleOrNull();
    return row?.state;
  }

  Future<void> _saveSyncState(
    String accountId,
    String resourceType,
    String state,
  ) async {
    await _db.into(_db.syncStates).insertOnConflictUpdate(
          SyncStatesCompanion.insert(
            accountId: accountId,
            resourceType: resourceType,
            state: state,
            syncedAt: DateTime.now(),
          ),
        );
  }

  // ── helpers ───────────────────────────────────────────────────────────────

  /// Extracts the argument map from a methodResponse at [index].
  /// Throws [JmapException] if the response is an error.
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

  model.Mailbox _toModel(MailboxRow row, {int unreadDelta = 0}) =>
      model.Mailbox(
        id: row.id,
        accountId: row.accountId,
        path: row.path,
        name: row.name,
        // Fall back to `path` when display_path is empty (row predates the
        // v47 migration, or was inserted by test setup with the older API).
        displayPath: row.displayPath.isEmpty ? row.path : row.displayPath,
        parentId: effectiveMailboxParent(
          parentId: row.parentId,
          localParent: row.localParent,
        ),
        unreadCount: max(0, row.unreadCount + unreadDelta),
        totalCount: row.totalCount,
        role: row.role,
        isLocal: row.isLocal,
      );

  /// Maps enough_mail special-use flags (RFC 6154) to JMAP role strings (RFC 8621).
  static String? _imapRole(imap.Mailbox mb) {
    if (mb.isInbox) {
      return 'inbox';
    }
    if (mb.isArchive) {
      return 'archive';
    }
    if (mb.isTrash) {
      return 'trash';
    }
    if (mb.isSent) {
      return 'sent';
    }
    if (mb.isDrafts) {
      return 'drafts';
    }
    if (mb.isJunk) {
      return 'junk';
    }
    // Gmail's "All Mail" carries the RFC 6154 \All special-use flag. It holds a
    // copy of every message in every other folder, so we tag it with the JMAP
    // "all" role (RFC 8621) to give both protocols one signal to skip it during
    // automatic sync and avoid downloading everything twice (#691).
    if (mb.hasFlag(imap.MailboxFlag.all)) {
      return 'all';
    }

    // Name-based fallback for servers that do not support special-use flags
    final name = mb.name.toLowerCase();
    if (name == 'inbox') {
      return 'inbox';
    }
    if (name == 'archive') {
      return 'archive';
    }
    if (name == 'drafts' || name == 'draft') {
      return 'drafts';
    }
    if (name == 'trash' ||
        name == 'deleted items' ||
        name == 'deleted messages' ||
        name == 'bin') {
      return 'trash';
    }
    if (name == 'sent' || name == 'sent items' || name == 'sent messages') {
      return 'sent';
    }
    if (name == 'junk' || name == 'junk mail' || name == 'spam') {
      return 'junk';
    }

    return null;
  }

  /// After a folder listing that started at [readSeq]: the acked ops it
  /// settles as a whole (creates found by a read, deletes), and the
  /// counterpart stand-in folders it did not find.
  Future<void> _afterListing(String accountId, int readSeq) async {
    await _writer.settleReadConfirmed(accountId, readSeq);
    await _writer.settleAckedDeletes(accountId, readSeq);
    await _writer.dropOrphanedCounterpartFolders(
      accountId,
      listedSeq: readSeq,
    );
  }

  /// IMAP folders another client renamed or moved (SYNC-REDESIGN.md §8,
  /// phase 5b): IMAP has no folder ids, so a rename elsewhere lists as a
  /// folder gone plus a new one. A cached folder the listing [listed]
  /// (started at [readSeq]) no longer has is taken for renamed to a new
  /// folder that shares its leaf (a move) or its parent (a rename) with it
  /// and is the only new one that
  /// - has its UIDVALIDITY (from its sync checkpoint; STATUS of the new
  ///   one): RFC 3501 servers that keep UIDVALIDITY across RENAME, while a
  ///   new folder gets a fresh one; or, as that fails on servers that give a
  ///   renamed folder a new one (Stalwart),
  /// - holds every Message-ID cached for it (at most [_renameProbeIds] of
  ///   them, searched with `UID SEARCH HEADER Message-ID`), with at least as
  ///   many messages: an empty folder cannot be recognised this way.
  /// The cached folder, its subfolders, its mail and the queued changes
  /// naming it follow ([MailboxStateWriter.serverPathChanged]; App Log warn
  /// `mailbox.renamed_elsewhere`). Anything else is left to the prune: the
  /// changes queued for the folder fail, listed.
  Future<void> _followRenamesElsewhere(
    imap.ImapClient client,
    String accountId,
    List<imap.Mailbox> listed,
    int readSeq,
  ) async {
    final listedPaths = {for (final mb in listed) mb.path};
    final vanished = await _writer.prunable(accountId, listedPaths, readSeq);
    if (vanished.isEmpty) return;
    final cached = {
      for (final r in await (_db.select(_db.mailboxes)
            ..where((t) => t.accountId.equals(accountId)))
          .get())
        r.path,
    };
    final fresh = [
      for (final mb in listed)
        if (!cached.contains(mb.path)) mb,
    ];
    if (fresh.isEmpty) return;
    final validityOf = <String, int>{};
    for (final v in vanished) {
      final raw = await _loadSyncState(accountId, 'IMAP:${v.path}');
      if (raw == null) continue;
      try {
        final validity =
            (jsonDecode(raw) as Map<String, dynamic>)['uidValidity'];
        if (validity is int && validity != 0) validityOf[v.path] = validity;
      } catch (_) {}
    }
    final freshStatus = <String, ({int? validity, int messages})>{};
    for (final mb in fresh) {
      try {
        final status = await client.statusMailbox(mb, [
          imap.StatusFlags.uidValidity,
          imap.StatusFlags.messages,
        ]);
        freshStatus[mb.path] = (
          validity: status.uidValidity,
          messages: status.messagesExists,
        );
      } catch (e) {
        if (!client.isConnected) rethrow;
      }
    }
    final separator = imapSeparatorOf(listed);
    String parentOf(String path) {
      final cut = path.lastIndexOf(separator);
      return cut < 0 ? '' : path.substring(0, cut);
    }

    String leafOf(String path) {
      final cut = path.lastIndexOf(separator);
      return cut < 0 ? path : path.substring(cut + separator.length);
    }

    // Parents first: their subfolders move with them.
    final ordered = [for (final v in vanished) v.path]
      ..sort((a, b) => a.length.compareTo(b.length));
    final taken = <String>{};
    for (final from in ordered) {
      if (await _writer.rowByPath(accountId, from) == null) continue;
      final candidates = [
        for (final path in freshStatus.keys)
          if (!taken.contains(path) &&
              (leafOf(from) == leafOf(path) ||
                  parentOf(from) == parentOf(path)) &&
              await _writer.rowByPath(accountId, path) == null)
            path,
      ];
      if (candidates.isEmpty) continue;
      var how = 'UIDVALIDITY';
      final validity = validityOf[from];
      var matches = validity == null ||
              validityOf.values.where((v) => v == validity).length != 1
          ? const <String>[]
          : [
              for (final path in candidates)
                if (freshStatus[path]!.validity == validity) path,
            ];
      if (matches.isEmpty) {
        how = 'Message-ID';
        final ids = await _cachedMessageIds(accountId, from);
        if (ids.isEmpty) continue;
        matches = [
          for (final path in candidates)
            if (freshStatus[path]!.messages >= ids.length &&
                await _holdsAll(client, path, ids))
              path,
        ];
      }
      if (matches.length != 1) continue;
      final to = matches.single;
      taken.add(to);
      await _writer.serverPathChanged(accountId, from, to);
      unawaited(
        _appLogger?.warn(
          'mailbox.renamed_elsewhere',
          'The folder "$from" is "$to" on the server now (renamed or moved '
              'by another client, recognised by its $how); its mail and the '
              'changes queued for it follow',
          accountId: accountId,
          mailboxPath: to,
          data: {'from': from, 'to': to, 'by': how},
        ),
      );
    }
  }

  /// How many cached Message-IDs a rename check looks for at most.
  static const _renameProbeIds = 50;

  /// The Message-IDs cached for the server folder [path] of [accountId]
  /// (at most [_renameProbeIds]); empty when it has none or a mail without
  /// one.
  Future<List<String>> _cachedMessageIds(
    String accountId,
    String path,
  ) async {
    final rows = await _db.customSelect(
      'SELECT message_id FROM emails WHERE account_id = ?1 '
      'AND srv_mailbox_path = ?2 AND srv_gone = 0 AND is_local = 0 '
      'ORDER BY id LIMIT ?3',
      variables: [
        Variable.withString(accountId),
        Variable.withString(path),
        Variable.withInt(_renameProbeIds),
      ],
    ).get();
    final ids = [for (final r in rows) r.readNullable<String>('message_id')];
    if (ids.any((id) => id == null || id.isEmpty)) return const [];
    return ids.cast<String>();
  }

  /// Whether the server folder [path] holds a message with each of [ids].
  Future<bool> _holdsAll(
    imap.ImapClient client,
    String path,
    List<String> ids,
  ) async {
    try {
      await client.selectUnicodeMailboxByPath(path);
      for (final id in ids) {
        var found = false;
        for (final criteria in messageIdSearchCriteria(id)) {
          final result =
              await client.uidSearchMessages(searchCriteria: criteria);
          if (result.matchingSequence?.isNotEmpty ?? false) {
            found = true;
            break;
          }
        }
        if (!found) return false;
      }
      return true;
    } catch (e) {
      if (!client.isConnected) rethrow;
      return false;
    }
  }

  @override
  Future<void> clearForResync(String accountId) =>
      _writer.clearForResync(accountId);

  /// Removes any locally cached mailbox for [accountId] whose `path` is not
  /// in [keepPaths] (paths the server still advertises), with the related
  /// emails, threads and sync checkpoints ([removeLocalMailbox]); the
  /// queued changes naming it fail and stay listed. A listing that started
  /// at [readSeq] removes nothing created offline, nor a folder a later
  /// read or ack wrote (just created or renamed): [MailboxStateWriter.prunable].
  Future<void> _prune(
    String accountId,
    Set<String> keepPaths,
    int readSeq,
  ) async {
    for (final row in await _writer.prunable(accountId, keepPaths, readSeq)) {
      log('Mailbox "${row.path}" deleted on server — removing local cache');
      await removeLocalMailbox(
        _db,
        accountId,
        row.path,
        appLogger: _appLogger,
      );
    }
  }

  @override
  Future<model.Mailbox> createMailboxWithRole(
    String accountId,
    String name,
    String role, {
    String? parentDisplayPath,
  }) =>
      _createMailbox(accountId, name, role, parentDisplayPath);

  @override
  Future<model.Mailbox> createMailbox(
    String accountId,
    String name, {
    String? parentDisplayPath,
  }) =>
      _createMailbox(accountId, name, null, parentDisplayPath);

  /// Creates the folder locally at once and queues its creation on the
  /// server (`create_mailbox`, SYNC-REDESIGN.md §7), offline too: the
  /// folder shows right away, mail can be moved into it (those moves wait
  /// for the create), and the next flush creates it. A server refusal (a
  /// name clash) becomes a failed change on the Pending Changes screen.
  Future<model.Mailbox> _createMailbox(
    String accountId,
    String name,
    String? role,
    String? parentDisplayPath,
  ) async {
    // Validate before any lookup, so a bad name is never queued.
    final segments = splitFolderName(name);
    final parent = await _findParent(accountId, parentDisplayPath);
    final row = await _writer.createLocal(
      accountId: accountId,
      segments: segments,
      role: role,
      parent: parent,
    );
    unawaited(
      _appLogger?.info(
        'mailbox.create',
        'Created folder "${segments.join('/')}"; queued for the server',
        accountId: accountId,
        mailboxPath: row.path,
        data: {'name': name, if (role != null) 'role': role},
      ),
    );
    _queuedCtrl.add(accountId);
    return _toModel(row);
  }

  /// Splits a user-typed folder [name] on `/` into its hierarchy segments, so
  /// `Projects/2026` means "2026 inside Projects" on every protocol — IMAP
  /// joins the segments with the server's hierarchy delimiter, JMAP creates
  /// one mailbox per segment chained by `parentId`.
  ///
  /// Throws [ArgumentError] for an empty name or an empty segment
  /// (`a//b`, a leading or trailing `/`).
  static List<String> splitFolderName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Folder name must not be empty');
    }
    final segments = trimmed.split('/').map((s) => s.trim()).toList();
    if (segments.any((s) => s.isEmpty)) {
      throw ArgumentError.value(
        name,
        'name',
        'Folder name must not contain an empty part '
            '(no leading, trailing or double "/")',
      );
    }
    return segments;
  }

  /// Looks up the local mailbox row whose `displayPath` matches
  /// [parentDisplayPath]. Throws when a non-null displayPath does not resolve —
  /// creating a child under a parent that isn't in the local cache would leave
  /// the new mailbox unreachable in the UI's tree.
  Future<MailboxRow?> _findParent(
    String accountId,
    String? parentDisplayPath,
  ) async {
    if (parentDisplayPath == null || parentDisplayPath.isEmpty) return null;
    // Only a folder that shows: not one being deleted.
    final row = (await _shownRows(accountId))
        .where((r) => r.displayPath == parentDisplayPath)
        .firstOrNull;
    if (row == null) {
      throw Exception(
        'Parent mailbox "$parentDisplayPath" not found in local cache',
      );
    }
    return row;
  }

  // ── rename / delete / move ──────────────────────────────────────────────

  /// Renames the folder locally at once and queues the rename on the
  /// server (`rename_mailbox`), offline too: the new name shows right away.
  @override
  Future<model.Mailbox> renameMailbox(
    String accountId,
    String mailboxPath,
    String newName,
  ) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(newName, 'newName', 'Name must not be empty');
    }
    if (trimmed.contains('/')) {
      throw ArgumentError.value(
        newName,
        'newName',
        'Name must not contain "/"',
      );
    }
    final row = await _requireRow(accountId, mailboxPath);
    if (row.name == trimmed) return _toModel(row);
    final renamed = await _writer.enqueueRename(row, trimmed);
    unawaited(
      _appLogger?.info(
        'mailbox.rename',
        'Renamed folder "${row.name}" to "$trimmed"; queued for the server',
        accountId: accountId,
        mailboxPath: row.path,
        data: {'from': row.name, 'to': trimmed},
      ),
    );
    _queuedCtrl.add(accountId);
    return _toModel(renamed);
  }

  /// Deletes the folder locally at once and queues the delete on the
  /// server (`delete_mailbox`, SYNC-REDESIGN.md §7, phase 5b), offline too:
  /// the folder is hidden right away; the flush deletes it once the mail
  /// changes queued before it are sent, and only then its cache goes. A
  /// refusal (mail on the server without [removeEmails], subfolders)
  /// becomes a failed change and the folder shows again.
  @override
  Future<void> deleteMailbox(
    String accountId,
    String mailboxPath, {
    bool removeEmails = false,
  }) async {
    final row = await _requireRow(accountId, mailboxPath);
    if (row.isLocal) {
      // Created offline and not on the server yet: giving up its creation
      // is all a delete needs (the changes waiting for it fail).
      await _discardLocal(row);
      return;
    }
    if (await _hasShownSubfolders(row)) {
      throw Exception(
        'The folder "${row.name}" has subfolders; delete them first',
      );
    }
    final op = await _writer.enqueueDelete(row, removeEmails: removeEmails);
    unawaited(
      _appLogger?.info(
        'mailbox.delete',
        'Deleted folder "${row.displayPath}"'
            '${removeEmails ? ' with its mail' : ''}; queued for the server',
        accountId: accountId,
        mailboxPath: row.path,
        data: {'changeId': op, 'removeEmails': removeEmails},
      ),
    );
    _queuedCtrl.add(accountId);
  }

  /// Whether a folder that shows has [row] as its parent: on JMAP by the
  /// effective `parentId`, on IMAP by the display path and the account's
  /// hierarchy separator.
  Future<bool> _hasShownSubfolders(MailboxRow row) async {
    final jmap = (await _accounts.getAccount(row.accountId))?.type ==
        account_model.AccountType.jmap;
    final separator = await _writer.imapSeparator(row.accountId);
    for (final r in await _shownRows(row.accountId)) {
      if (r.id == row.id) continue;
      final child = jmap
          ? effectiveMailboxParent(
                parentId: r.parentId,
                localParent: r.localParent,
              ) ==
              row.path
          : r.displayPath.startsWith('${row.displayPath}$separator');
      if (child) return true;
    }
    return false;
  }

  /// The mailboxes of [accountId] that show (not hidden, not a failed
  /// create).
  Future<List<MailboxRow>> _shownRows(String accountId) async => [
        for (final r in await _db.customSelect(
          'SELECT m.* FROM mailboxes m WHERE m.account_id = ?1 '
          'AND ${mailboxShownSql('m')}',
          variables: [Variable.withString(accountId)],
          readsFrom: {_db.mailboxes, _db.pendingChanges},
        ).get())
          _db.mailboxes.map(r.data),
      ];

  /// Discards the queued create of local [row] (and with it the row).
  Future<void> _discardLocal(MailboxRow row) async {
    final creates = await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.resourceType.equals(mailboxResourceType) &
                t.resourceId.equals(row.id) &
                t.changeType.equals(createMailboxOp),
          ))
        .get();
    for (final op in creates) {
      if (op.state == 'inflight') {
        throw Exception(
          'The folder "${row.name}" is being created on the server right '
          'now; try again in a moment',
        );
      }
      _writer.logDependents(op, await _writer.discard(op));
    }
  }

  /// Moves the folder locally at once and queues the move on the server
  /// (`move_mailbox`, phase 5b), offline too: it shows below its new
  /// parent right away, with its subfolders. A folder or parent created
  /// offline is moved once it is on the server (the move waits for it).
  @override
  Future<model.Mailbox> moveMailbox(
    String accountId,
    String mailboxPath, {
    required String? newParentDisplayPath,
  }) async {
    final row = await _requireRow(accountId, mailboxPath);
    final newParent = await _findParent(accountId, newParentDisplayPath);
    if (newParent != null && newParent.id == row.id) {
      throw Exception('Cannot move a folder into itself');
    }
    final separator = (await _accounts.getAccount(accountId))?.type ==
            account_model.AccountType.jmap
        ? '/'
        : await _writer.imapSeparator(accountId);
    if (newParent != null &&
        newParent.displayPath.startsWith('${row.displayPath}$separator')) {
      throw Exception('Cannot move a folder into one of its descendants');
    }
    final (row: moved, op: op) =
        await _writer.enqueueMove(row, newParent?.path);
    unawaited(
      _appLogger?.info(
        'mailbox.move',
        'Moved folder "${row.displayPath}" to '
            '"${newParent?.displayPath ?? '(top level)'}"'
            '${op == null ? ' (back where the server has it)' : ''}; '
            'queued for the server',
        accountId: accountId,
        mailboxPath: row.path,
        data: {'changeId': op, 'parent': newParent?.path},
      ),
    );
    _queuedCtrl.add(accountId);
    return _toModel(moved);
  }

  @override
  Future<bool> undoFolderChange(String accountId, String mailboxId) async {
    final row = await _writer.rowById(mailboxId);
    if (row == null || row.accountId != accountId) return false;
    final undo = await _writer.undoLatest(row);
    unawaited(
      _appLogger?.info(
        'mailbox.undo',
        switch (undo) {
          MailboxUndo.nothing => 'Nothing to undo for folder "${row.name}"',
          MailboxUndo.cancelled =>
            'Undid the folder change of "${row.name}" before it was sent',
          MailboxUndo.reversed =>
            'Moving folder "${row.name}" back; queued for the server',
          MailboxUndo.tooLate => 'Could not undo deleting folder '
              '"${row.name}": the delete may have reached the server',
        },
        accountId: accountId,
        mailboxPath: row.path,
      ),
    );
    if (undo == MailboxUndo.reversed) _queuedCtrl.add(accountId);
    return undo != MailboxUndo.tooLate;
  }

  Future<MailboxRow> _requireRow(String accountId, String mailboxPath) async {
    final row = await (_db.select(_db.mailboxes)
          ..where(
            (t) => t.accountId.equals(accountId) & t.path.equals(mailboxPath),
          )
          ..limit(1))
        .getSingleOrNull();
    if (row == null) {
      throw Exception('Mailbox "$mailboxPath" not found in local cache');
    }
    return row;
  }
}

const folderHasMailText =
    'the folder is not empty on the server any more — reload the folder '
    'list and confirm deleting its mail';

/// A readable sentence for a `Mailbox/set` SetError (RFC 8620 §5.3,
/// RFC 8621 §2.5), keeping the raw type in brackets for bug reports.
String jmapMailboxSetErrorText(Map<String, dynamic> err) {
  final type = err['type'];
  final reason = switch (type) {
    'mailboxHasChild' => 'the folder still has subfolders on the server',
    'mailboxHasEmail' => folderHasMailText,
    'notFound' => 'the folder no longer exists on the server',
    'forbidden' => 'the server does not allow changing this folder',
    'alreadyExists' => 'a folder with this name already exists',
    'invalidProperties' => 'the server rejected the new name or place',
    _ => err['description'] as String? ?? 'the server refused',
  };
  // The server's own words, when it gave some the sentence does not hold.
  final description = err['description'];
  final detail =
      description is String && description != reason ? ': $description' : '';
  return '$reason ($type$detail)';
}

/// The enough_mail [imap.Mailbox] for the folder at [path], for RENAME and
/// DELETE, with the server's hierarchy [separator]. The stored `path` is the
/// decoded Unicode form, but enough_mail writes `encodedPath` verbatim, so
/// it is re-encoded to modified UTF-7 first (#633).
imap.Mailbox imapMailboxFor(String path, String separator) {
  final encodedPath = encodeImapMailboxPath(path, separator);
  final leafIndex = encodedPath.lastIndexOf(separator);
  return imap.Mailbox(
    encodedName:
        leafIndex == -1 ? encodedPath : encodedPath.substring(leafIndex + 1),
    encodedPath: encodedPath,
    flags: <imap.MailboxFlag>[],
    pathSeparator: separator,
  );
}

/// The IMAP hierarchy separator of a LIST answer [listed]: the one the
/// server gives its folders; `/` when it gives none. The one source of the
/// separator: sync records it ([MailboxStateWriter.recordImapSeparator]),
/// and subfolder paths, display paths, renames and the folder flush all go
/// by it.
String imapSeparatorOf(List<imap.Mailbox> listed) {
  for (final m in listed) {
    if (m.pathSeparator.isNotEmpty) return m.pathSeparator;
  }
  return '/';
}

/// [imapSeparatorOf] the server's LIST over [client].
Future<String> imapPathSeparator(imap.ImapClient client) async =>
    imapSeparatorOf(await client.listMailboxes());

/// Deletes the local cache rows that belong to a single mailbox that no
/// longer exists on the server.
///
/// Removes the row in `mailboxes`, every `threads` row, the IMAP
/// per-mailbox checkpoint in `sync_states`. Queued `pending_changes` whose
/// JSON payload references the path as `mailboxPath`, `src` or `dest` are
/// not deleted but marked failed (they can no longer apply, and must not
/// protect anything from sync), so the user sees them on the Pending Changes
/// screen; each is logged to [appLogger] as a warning. The mails the server
/// had in the folder are marked gone and deleted unless a change is still
/// in flight or acked for them ([EmailStateWriter.markFolderGone]); a mail
/// the user moved into the folder shows in its source again, where the
/// server still has it (its failed move no longer folds, #1239).
/// Idempotent — safe to call when nothing matches.
Future<void> removeLocalMailbox(
  AppDatabase db,
  String accountId,
  String path, {
  AppLogger? appLogger,
  bool deletedByUser = false,
}) async {
  final folders = MailboxStateWriter(db, appLogger: appLogger);
  // A folder created offline has no server copy that could be gone: a
  // SELECT or listing that misses it says nothing about it.
  if ((await folders.rowByPath(accountId, path))?.isLocal ?? false) {
    log('Not removing "$path": created offline, not on the server yet');
    return;
  }
  final why = deletedByUser ? 'folder deleted' : 'folder removed on the server';
  final failed = <PendingChangeRow>[];
  var kept = <String>{};
  final writer = EmailStateWriter(db, appLogger: appLogger);
  await db.transaction(() async {
    await (db.delete(db.threads)
          ..where(
            (t) => t.accountId.equals(accountId) & t.mailboxPath.equals(path),
          ))
        .go();
    await (db.delete(db.syncStates)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.resourceType.equals('IMAP:$path'),
          ))
        .go();

    // pending_changes payloads are protocol-specific JSON; fail any queued
    // row referring to the gone path so the queue doesn't keep retrying.
    final pending = await (db.select(db.pendingChanges)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.state.isIn(const ['pending', 'stuck', 'parked']),
          ))
        .get();
    for (final row in pending) {
      Map<String, dynamic> payload;
      try {
        payload = jsonDecode(row.payload) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      final refs = [payload['mailboxPath'], payload['src'], payload['dest']];
      if (!refs.contains(path)) continue;
      await (db.update(db.pendingChanges)..where((t) => t.id.equals(row.id)))
          .write(
        PendingChangesCompanion(
          state: const Value('failed'),
          lastError: Value(why),
        ),
      );
      failed.add(row);
    }
    // The folder's own queued changes (a rename) can no longer apply
    // either, nor what waits for them.
    failed.addAll(await folders.failOpsOfRemoved(accountId, path, why));
    // A failed change no longer folds: a mail it showed elsewhere shows the
    // server's folder and read/star/snooze state again.
    final shownElsewhere = await writer.refoldAll([
      for (final row in failed)
        if (row.resourceType != mailboxResourceType) row.resourceId,
    ]);
    // Their shadows on a counterpart account go with them.
    shownElsewhere.addAll((await writer.dropOrphanedShadows()).keys);
    kept = await writer.markFolderGone(accountId, path);
    for (final row in await (db.select(db.emails)
          ..where((t) => t.id.isIn(shownElsewhere)))
        .get()) {
      await refreshThreadAggregate(
        db,
        accountId,
        row.mailboxPath,
        row.threadId ?? row.id,
      );
    }

    await folders.deleteRow(accountId, path);
  });
  if (kept.isNotEmpty) {
    unawaited(
      appLogger?.warn(
        'email.server_gone_with_changes',
        'The folder "$path" was removed on the server: ${kept.length} '
            'mail(s) of it are kept, hidden, while a change of them is being '
            'sent or confirmed',
        accountId: accountId,
        mailboxPath: path,
        data: {'emailIds': kept.take(100).toList()},
      ),
    );
  }
  for (final row in failed) {
    unawaited(
      appLogger?.warn(
        'pending_change.folder_removed',
        'Could not apply a queued ${row.changeType} change — the folder '
            '"$path" ${deletedByUser ? 'was deleted' : 'was removed on the '
                'server'}; kept on the Pending Changes screen',
        accountId: accountId,
        emailId:
            row.resourceType == mailboxResourceType ? null : row.resourceId,
        data: {'changeType': row.changeType, 'mailboxPath': path},
      ),
    );
  }
}
