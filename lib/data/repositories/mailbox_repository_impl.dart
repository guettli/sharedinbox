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

/// `sync_states` key (per account) of the folders a listing that was not
/// trusted left out (#1312): a JSON list of paths (JMAP: mailbox ids). The
/// next listing that leaves them out too removes them.
const pendingPruneKey = 'Mailbox:PendingPrune';

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

  @override
  Stream<Set<FolderRef>> observeHiddenFolders() =>
      (_db.select(_db.mailboxes)..where((t) => t.localHidden))
          .watch()
          .map(
            (rows) => {
              for (final r in rows) (accountId: r.accountId, path: r.path),
            },
          )
          .distinct((a, b) => a.length == b.length && a.containsAll(b));

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
      // A rename or move being sent that the listing shows done already:
      // its ack moves the folder to the new path (phase 6b).
      final arriving =
          await _writer.pathsArrivingByRename(account.id, serverPaths);
      // A folder another client renamed or moved: its mail and the changes
      // queued for it follow instead of failing as "folder removed".
      await _followRenamesElsewhere(
        client,
        account.id,
        [
          for (final mb in mailboxes)
            if (!MailboxStateWriter.isRenamedAway(mb.path, arriving, separator))
              mb,
        ],
        listSeq,
        allListed: serverPaths,
      );
      final trusted = await _prune(account.id, serverPaths, listSeq);
      final renamedAway = await _writer.renamedAwaySince(account.id, listSeq);

      for (final mb in mailboxes) {
        final path = mb.path;
        // An old path (or a subfolder of one) a rename acked after this
        // listing started moved away from.
        if (MailboxStateWriter.isRenamedAway(path, renamedAway, separator)) {
          continue;
        }
        // The new path of a rename or move being sent: not a second folder
        // next to the one moving there (the ack moves that one).
        if (MailboxStateWriter.isRenamedAway(path, arriving, separator) &&
            await _writer.rowByPath(account.id, path) == null) {
          unawaited(
            _appLogger?.info(
              'mailbox.listing_skipped_arriving',
              'Not storing "$path" from this listing: a rename or move of a '
                  'folder to it is being sent, and its answer moves the '
                  'folder there',
              accountId: account.id,
              mailboxPath: path,
            ),
          );
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
      await _afterListing(account.id, listSeq, trusted: trusted);
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
    final trusted = await _prune(accountId, serverIds, readSeq);

    await _upsertJmapMailboxes(accountId, mailboxes, readSeq: readSeq);
    await _afterListing(accountId, readSeq, trusted: trusted);
    // A listing not trusted keeps no state: the next sync lists in full
    // again, and that listing confirms the absence or not
    // (`Mailbox/changes` would never name the folders it left out).
    if (trusted) await _saveSyncState(accountId, 'Mailbox', newState);
    log(
      'JMAP full mailbox sync: ${mailboxes.length} mailboxes, state=$newState'
      '${trusted ? '' : ' (not trusted, state not kept)'}',
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
    // `destroyed` is explicit and honoured, except for the inbox: an
    // account without one is more likely a server glitch (#1312). It is
    // kept, and the next sync lists in full ([_prune] confirms or not).
    var inboxDestroyed = false;
    for (final jmapId in destroyed) {
      final row = await _writer.rowByPath(accountId, jmapId);
      if (row != null && !row.isLocal && _isInbox(row)) {
        inboxDestroyed = true;
        await _savePendingPrune(
          accountId,
          {...await _loadPendingPrune(accountId), jmapId},
        );
        unawaited(
          _appLogger?.warn(
            'mailbox.listing_untrusted',
            'The server reports the inbox "${row.name}" destroyed: kept, and '
                'the folder list is read in full again; it is removed only '
                'when that listing does not have it either',
            accountId: accountId,
            mailboxPath: jmapId,
            data: {'reason': 'inbox destroyed', 'destroyed': destroyed.length},
          ),
        );
        continue;
      }
      await removeLocalMailbox(
        _db,
        accountId,
        jmapId,
        appLogger: _appLogger,
      );
    }

    await _afterListing(accountId, readSeq);
    if (inboxDestroyed) {
      await _forgetSyncState(accountId, 'Mailbox');
    } else {
      await _saveSyncState(accountId, 'Mailbox', newState);
    }
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

  Future<void> _forgetSyncState(String accountId, String resourceType) =>
      (_db.delete(_db.syncStates)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.resourceType.equals(resourceType),
            ))
          .go();

  /// The folders (paths; JMAP ids) a listing that was not trusted left out
  /// ([_prune]): the next listing that leaves them out too removes them.
  Future<Set<String>> _loadPendingPrune(String accountId) async {
    final raw = await _loadSyncState(accountId, pendingPruneKey);
    if (raw == null) return {};
    try {
      return {...(jsonDecode(raw) as List<dynamic>).cast<String>()};
    } catch (_) {
      return {};
    }
  }

  Future<void> _savePendingPrune(String accountId, Set<String> paths) async {
    if (paths.isEmpty) return _forgetSyncState(accountId, pendingPruneKey);
    await _saveSyncState(
      accountId,
      pendingPruneKey,
      jsonEncode(paths.toList()..sort()),
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
  /// A listing that was not [trusted] ([_prune]) drops no stand-in either.
  Future<void> _afterListing(
    String accountId,
    int readSeq, {
    bool trusted = true,
  }) async {
    await _writer.settleReadConfirmed(accountId, readSeq);
    await _writer.settleAckedDeletes(accountId, readSeq);
    if (!trusted) return;
    await _writer.dropOrphanedCounterpartFolders(
      accountId,
      listedSeq: readSeq,
    );
  }

  /// IMAP folders another client renamed or moved (SYNC-REDESIGN.md §8,
  /// phase 5b): IMAP has no folder ids, so a rename elsewhere lists as a
  /// folder gone plus a new one. A cached folder the listing (its paths
  /// [allListed], started at [readSeq]) no longer has, and that has no
  /// delete queued, is taken for renamed to a new folder of [listed] (the
  /// listed folders less the paths an own rename or move being sent puts a
  /// folder at) that shares its leaf (a move) or
  /// its parent (a rename) with it, when that match is unique both ways (one
  /// new folder for it, no other vanished folder matching that one) and the
  /// new folder
  /// - has its UIDVALIDITY (from its sync checkpoint; STATUS of the new
  ///   one; RFC 3501 servers keep it across RENAME), and holds the
  ///   Message-IDs cached for it when there are any; or, as that fails on
  ///   servers that give a renamed folder a new one (Stalwart),
  /// - holds every Message-ID cached for it (at most [_renameProbeIds] of
  ///   them, searched with `UID SEARCH HEADER Message-ID`) and exactly as
  ///   many messages as are cached: an empty folder cannot be recognised
  ///   this way.
  /// The cached folder, its subfolders, its mail and the queued changes
  /// naming it follow ([MailboxStateWriter.serverPathChanged]; App Log warn
  /// `mailbox.renamed_elsewhere`). Anything else is left to the prune: the
  /// changes queued for the folder fail, listed.
  Future<void> _followRenamesElsewhere(
    imap.ImapClient client,
    String accountId,
    List<imap.Mailbox> listed,
    int readSeq, {
    required Set<String> allListed,
  }) async {
    final vanished = await _writer.prunable(accountId, allListed, readSeq);
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

    // Every vanished folder's matches first, so a match is taken only
    // when it is unique both ways: one new folder for the vanished one,
    // and no other vanished folder matching that new one.
    final matchesOf = <String, ({List<String> to, String how})>{};
    for (final v in vanished) {
      // A folder the user deleted (queued) is never followed: a wrong match
      // would delete another folder. Its delete counts as done by the
      // prune ([MailboxStateWriter.failOpsOfRemoved]).
      if (await _hasQueuedDelete(v.id)) continue;
      final from = v.path;
      final candidates = [
        for (final path in freshStatus.keys)
          if (leafOf(from) == leafOf(path) || parentOf(from) == parentOf(path))
            path,
      ];
      if (candidates.isEmpty) continue;
      final ids = await _cachedMessageIds(accountId, from);
      final validity = validityOf[from];
      if (validity != null &&
          validityOf.values.where((x) => x == validity).length == 1) {
        final byValidity = [
          for (final path in candidates)
            if (freshStatus[path]!.validity == validity) path,
        ];
        if (byValidity.isNotEmpty) {
          // UIDVALIDITY is not unique across folders: the mail cached for
          // it confirms the match when there is any.
          matchesOf[from] = (
            to: [
              for (final path in byValidity)
                if (ids.isEmpty || await _holdsAll(client, path, ids)) path,
            ],
            how: 'UIDVALIDITY',
          );
          continue;
        }
      }
      if (ids.isEmpty) continue;
      // Exactly the folder's mail: as many messages as it has cached (not a
      // folder another client filled with copies and more).
      final count = await _cachedMessageCount(accountId, from);
      matchesOf[from] = (
        to: [
          for (final path in candidates)
            if (freshStatus[path]!.messages == count &&
                await _holdsAll(client, path, ids))
              path,
        ],
        how: 'Message-ID',
      );
    }
    // Parents first: their subfolders move with them.
    final ordered = matchesOf.keys.toList()
      ..sort((a, b) => a.length.compareTo(b.length));
    for (final from in ordered) {
      final (:to, :how) = matchesOf[from]!;
      if (to.length != 1) continue;
      final target = to.single;
      final rivals = matchesOf.entries
          .where((e) => e.key != from && e.value.to.contains(target));
      if (rivals.isNotEmpty) continue;
      if (await _writer.rowByPath(accountId, from) == null) continue;
      if (await _writer.rowByPath(accountId, target) != null) continue;
      await _writer.serverPathChanged(accountId, from, target);
      unawaited(
        _appLogger?.warn(
          'mailbox.renamed_elsewhere',
          'The folder "$from" is "$target" on the server now (renamed or '
              'moved by another client, recognised by its $how); its mail and '
              'the changes queued for it follow',
          accountId: accountId,
          mailboxPath: target,
          data: {'from': from, 'to': target, 'by': how},
        ),
      );
    }
  }

  /// Whether mailbox [mailboxId] has a delete queued, being sent or stuck.
  Future<bool> _hasQueuedDelete(String mailboxId) async =>
      (await (_db.select(_db.pendingChanges)
            ..where(
              (t) =>
                  t.resourceType.equals(mailboxResourceType) &
                  t.resourceId.equals(mailboxId) &
                  t.changeType.equals(deleteMailboxOp) &
                  t.state.isIn(const ['pending', 'inflight', 'stuck']),
            )
            ..limit(1))
          .getSingleOrNull()) !=
      null;

  /// How many mails are cached for the server folder [path] of [accountId].
  Future<int> _cachedMessageCount(String accountId, String path) async =>
      (await _db.customSelect(
        'SELECT COUNT(*) AS n FROM emails WHERE account_id = ?1 '
        'AND srv_mailbox_path = ?2 AND srv_gone = 0 AND is_local = 0',
        variables: [Variable.withString(accountId), Variable.withString(path)],
      ).getSingle())
          .read<int>('n');

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

  /// Force resync, the mark of a mark-and-sweep (SYNC-REDESIGN.md §6): no
  /// mailbox row is deleted (they keep their ids, and the ops naming them
  /// stay valid). The JMAP listing state is forgotten, so the next listing
  /// is a complete `Mailbox/get`; that listing, like every IMAP `LIST`,
  /// writes each folder it lists and prunes the cached ones it does not
  /// ([_prune]: [MailboxStateWriter.prunable] keeps a folder created
  /// offline or one a later read or ack wrote).
  @override
  Future<void> clearForResync(String accountId) => (_db.delete(_db.syncStates)
        ..where(
          (t) =>
              t.accountId.equals(accountId) & t.resourceType.equals('Mailbox'),
        ))
      .go();

  /// Removes any locally cached mailbox for [accountId] whose `path` is not
  /// in [keepPaths] (paths the server still advertises), with the related
  /// emails, threads and sync checkpoints ([removeLocalMailbox]); the
  /// queued changes naming it fail and stay listed. A listing that started
  /// at [readSeq] removes nothing created offline, nor a folder a later
  /// read or ack wrote (just created or renamed): [MailboxStateWriter.prunable].
  ///
  /// A listing that may be a server or connection glitch is not trusted
  /// (#1312, [_untrustedReason]): it is empty, or it would remove the
  /// inbox, or at least [_untrustedMinMissing] cached server folders that
  /// are more than half of them. Then only the folders the previous
  /// untrusted listing left out too are removed (a confirmed absence: a
  /// real mass deletion goes through with the second listing); the others
  /// are kept and remembered in `sync_states` ([pendingPruneKey]), and App
  /// Log warn `mailbox.listing_untrusted` gives the counts. Returns whether
  /// the listing was trusted, i.e. no folder is held back.
  Future<bool> _prune(
    String accountId,
    Set<String> keepPaths,
    int readSeq,
  ) async {
    final candidates = await _writer.prunable(accountId, keepPaths, readSeq);
    final pending = await _loadPendingPrune(accountId);
    var remove = candidates;
    var held = const <MailboxRow>[];
    final reason = await _untrustedReason(accountId, keepPaths, candidates);
    if (reason != null) {
      remove = [
        for (final r in candidates)
          if (pending.contains(r.path)) r,
      ];
      held = [
        for (final r in candidates)
          if (!pending.contains(r.path)) r,
      ];
      unawaited(
        _appLogger?.warn(
          'mailbox.listing_untrusted',
          'The server listed ${keepPaths.length} folder(s) and left out '
              '${candidates.length} cached one(s) ($reason): this may be a '
              'glitch, so ${held.length} of them are kept until the next '
              'listing confirms they are gone; ${remove.length} the previous '
              'listing left out too are removed',
          accountId: accountId,
          data: {
            'reason': reason,
            'listed': keepPaths.length,
            'missing': candidates.length,
            'kept': held.length,
            'removed': remove.length,
            'keptPaths': [for (final r in held.take(50)) r.path],
          },
        ),
      );
    }
    final heldPaths = {for (final r in held) r.path};
    if (pending.length != heldPaths.length || !pending.containsAll(heldPaths)) {
      await _savePendingPrune(accountId, heldPaths);
    }
    for (final row in remove) {
      log('Mailbox "${row.path}" deleted on server — removing local cache');
      await removeLocalMailbox(
        _db,
        accountId,
        row.path,
        appLogger: _appLogger,
      );
    }
    return held.isEmpty;
  }

  /// A listing that leaves out at least this many cached server folders,
  /// and more than half of them, is not trusted ([_prune]).
  static const _untrustedMinMissing = 3;

  /// Why a listing ([keepPaths]) that leaves out the cached folders
  /// [missing] is not trusted, or null when it is.
  Future<String?> _untrustedReason(
    String accountId,
    Set<String> keepPaths,
    List<MailboxRow> missing,
  ) async {
    if (missing.isEmpty) return null;
    if (keepPaths.isEmpty) return 'empty listing';
    if (missing.any(_isInbox)) return 'inbox missing';
    if (missing.length < _untrustedMinMissing) return null;
    final cached = (await (_db.select(_db.mailboxes)
              ..where(
                (t) => t.accountId.equals(accountId) & t.isLocal.equals(false),
              ))
            .get())
        .length;
    if (missing.length * 2 > cached) return 'most folders missing';
    return null;
  }

  /// The account's inbox: role `inbox`, or the IMAP INBOX.
  static bool _isInbox(MailboxRow row) =>
      row.role == 'inbox' || row.path.toUpperCase() == 'INBOX';

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
    final op = await _writer.enqueueDelete(
      row,
      removeEmails: removeEmails,
      confirmedMessages:
          removeEmails ? await _confirmedMessages(accountId, row) : null,
    );
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

  /// How many mails the user saw in [row] when agreeing to delete them with
  /// it: the server's count, plus the mails shown there by a move into it
  /// not on the server yet. More on the server at the flush refuses the
  /// delete.
  Future<int> _confirmedMessages(String accountId, MailboxRow row) async {
    final movedIn = await _db.customSelect(
      'SELECT COUNT(*) AS n FROM emails WHERE account_id = ?1 '
      'AND mailbox_path = ?2 '
      'AND (srv_mailbox_path IS NULL OR srv_mailbox_path <> ?2)',
      variables: [
        Variable.withString(accountId),
        Variable.withString(row.path),
      ],
    ).getSingle();
    return row.totalCount + movedIn.read<int>('n');
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
          MailboxUndo.sending => 'Could not undo deleting folder '
              '"${row.name}": the delete is being sent right now; if the '
              'server refuses it, the folder shows again',
        },
        accountId: accountId,
        mailboxPath: row.path,
      ),
    );
    if (undo == MailboxUndo.reversed) _queuedCtrl.add(accountId);
    return undo != MailboxUndo.tooLate && undo != MailboxUndo.sending;
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
  final cachedFolder = await folders.rowByPath(accountId, path);
  // A folder created offline has no server copy that could be gone: a
  // SELECT or listing that misses it says nothing about it.
  if (cachedFolder?.isLocal ?? false) {
    log('Not removing "$path": created offline, not on the server yet');
    return;
  }
  final why = deletedByUser ? 'folder deleted' : 'folder removed on the server';
  final failed = <PendingChangeRow>[];
  var kept = <String>{};
  var removed = 0;
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
    (kept: kept, removed: removed) =
        await writer.markFolderGone(accountId, path);
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
  if (!deletedByUser && (cachedFolder != null || removed > 0)) {
    // The folder and the mail cached for it vanish from the app: say so
    // (a SELECT error read as "no such folder", a listing without it, a
    // JMAP `destroyed`).
    unawaited(
      appLogger?.warn(
        'mailbox.removed_gone',
        'The folder "$path" is gone on the server (deleted there, maybe '
            'through another account of the same mailbox or another client): '
            'removed it and the $removed mail(s) cached for it',
        accountId: accountId,
        mailboxPath: path,
        data: {'removedEmails': removed, 'kept': kept.length},
      ),
    );
  }
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
