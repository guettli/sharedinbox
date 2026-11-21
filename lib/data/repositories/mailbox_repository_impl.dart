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
import 'package:sharedinbox/data/imap/imap_errors.dart';
import 'package:sharedinbox/data/imap/mailbox_id_status.dart';
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

/// What a check of one folder a listing left out says about it
/// ([MailboxRepositoryImpl._prune]).
enum _FolderCheck { gone, present, unknown }

/// One listed IMAP folder's STATUS: the read sequence taken right before
/// it, and its answer or the error it failed with.
typedef _ListedStatus = ({
  int readSeq,
  ImapFolderStatus? status,
  (Object, StackTrace)? error,
});

/// A match [MailboxRepositoryImpl._followRenamesElsewhere] found for a
/// cached folder ([row]): the listed paths it may be at now ([to]), by
/// which rule ([how]), and the server id it went by ([id], MAILBOXID).
typedef _RenameMatch = ({
  List<String> to,
  String how,
  MailboxRow row,
  String? id,
});

/// A folder a listing that was not trusted left out: since when, and how
/// many listings (that one included) have left it out since.
typedef _Missing = ({DateTime since, int listings});

class MailboxRepositoryImpl implements MailboxRepository {
  MailboxRepositoryImpl(
    this._db,
    this._accounts, {
    ImapConnectFn imapConnect = connectImap,
    StatusWithMailboxIdFn statusWithMailboxId = statusWithMailboxIdFromServer,
    http.Client? httpClient,
    AppLogger? appLogger,
    DateTime Function()? now,
  })  : _imapConnect = imapConnect,
        _statusWithMailboxId = statusWithMailboxId,
        _httpClient = httpClient ?? http.Client(),
        _appLogger = appLogger,
        _now = now ?? DateTime.now,
        _writer = MailboxStateWriter(_db, appLogger: appLogger);

  final AppDatabase _db;
  final AccountRepository _accounts;
  final ImapConnectFn _imapConnect;
  final StatusWithMailboxIdFn _statusWithMailboxId;

  /// Connections whose server advertises OBJECTID but refused a STATUS
  /// with `MAILBOXID` that went through without it ([_status]).
  final _mailboxIdsRefused = Expando<bool>('mailboxIdsRefused');
  final http.Client _httpClient;
  final AppLogger? _appLogger;
  final DateTime Function() _now;

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
      // Every listed folder's STATUS first, each with the read sequence of
      // its count (SYNC-REDESIGN.md §7): with its MAILBOXID where the
      // server gives folder ids, which the renames elsewhere go by (#1315).
      final statusOf = <String, _ListedStatus>{};
      for (final mb in mailboxes) {
        final readSeq = await EmailStateWriter(_db).nextReadSeq();
        try {
          final status = await _status(client, mb, [
            imap.StatusFlags.messages,
            imap.StatusFlags.unseen,
            imap.StatusFlags.uidValidity,
          ]);
          statusOf[mb.path] = (readSeq: readSeq, status: status, error: null);
        } catch (e, stack) {
          statusOf[mb.path] =
              (readSeq: readSeq, status: null, error: (e, stack));
        }
      }
      // A connection lost on the way: no folder is followed or pruned on
      // the STATUS answers that are missing.
      if (!client.isConnected) {
        for (final listed in statusOf.values) {
          if (listed.error case (final e, final stack)) {
            Error.throwWithStackTrace(e, stack);
          }
        }
      }
      // A folder another client renamed or moved: its mail and the changes
      // queued for it follow instead of failing as "folder removed".
      final (moved: followed, :hold, :doubt) = await _followRenamesElsewhere(
        client,
        account.id,
        [
          for (final mb in mailboxes)
            if (!MailboxStateWriter.isRenamedAway(mb.path, arriving, separator))
              mb,
        ],
        listSeq,
        allListed: serverPaths,
        statusOf: statusOf,
      );
      final (:trusted, settled: _) = await _prune(
        account.id,
        serverPaths,
        listSeq,
        jmap: false,
        check: (path) => _imapFolderCheck(client, path, separator),
        doubt: doubt,
      );
      final renamedAway = await _writer.renamedAwaySince(account.id, listSeq);

      // Pre-load existing DB roles so we can preserve manually-set roles for
      // folders the server doesn't tag with a special-use attribute (after
      // the renames elsewhere were followed: a role moves with its folder).
      final existingRows = await (_db.select(
        _db.mailboxes,
      )..where((t) => t.accountId.equals(account.id)))
          .get();
      final existingRoles = {for (final r in existingRows) r.path: r.role};
      // The ids cached folders have: a new folder with another id is no
      // cached folder, also in a listing in doubt.
      final cachedIds = {
        for (final r in existingRows)
          if (r.srvMailboxId case final id?) id,
      };
      // The roles the server's flags or the folder names give: a folder
      // followed to another path keeps its old role only when no listed
      // folder has it that way (a renamed "Archive" next to a new one).
      final listedRoles = {
        for (final mb in mailboxes)
          if (_imapRole(mb) case final role?) role,
      };

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

        final listed = statusOf[path]!;
        final readSeq = listed.readSeq;
        final unread = listed.status?.unseen ?? 0;
        final total = listed.status?.messages ?? 0;
        // An id the follow could not settle is not stored yet, nor any of
        // a listing that had ids refused on the way.
        final mailboxId = !_idsUsable(client) || hold.contains(path)
            ? null
            : listed.status?.mailboxId;
        if (listed.error case (final e, final stack)) {
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
        // A listing in doubt about folder ids stores no new folder: one of
        // them may be a cached folder whose id did not come (the next
        // listing follows it there instead of making a second row).
        if (doubt != null &&
            !_storableInDoubt(listed, cachedIds, client) &&
            await _writer.rowByPath(account.id, path) == null) {
          unawaited(
            _appLogger?.info(
              'mailbox.listing_skipped_unsure',
              'Not storing "$path" from this listing yet: $doubt',
              accountId: account.id,
              mailboxPath: path,
            ),
          );
          continue;
        }

        // Use the server-assigned role when available; fall back to the
        // existing DB role so that manually-created folders (e.g. a user
        // who just created their Archive folder) keep their role across syncs
        // when the IMAP server does not expose a special-use attribute.
        final kept = existingRoles[path];
        final role = _imapRole(mb) ??
            (followed.contains(path) && listedRoles.contains(kept)
                ? null
                : kept);

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
          mailboxId: mailboxId,
        );
      }
      await _writer.rebuildDisplayPaths(account.id);
      await _afterListing(account.id, listSeq, trusted: trusted);
      // Every folder of this listing is stored now: a mail gone from one
      // folder that waits for a foreign move's destination does not stop
      // waiting before the folders listed after it synced
      // ([EmailStateWriter.expireForeignMoveWaits], #1313).
      await _saveSyncState(
        account.id,
        EmailStateWriter.folderListedKey,
        '$listSeq',
      );
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
    final (:trusted, :settled) = await _prune(
      accountId,
      serverIds,
      readSeq,
      jmap: true,
      check: (id) => _jmapFolderCheck(jmap, id),
    );

    await _upsertJmapMailboxes(accountId, mailboxes, readSeq: readSeq);
    await _afterListing(accountId, readSeq, trusted: trusted);
    // While a folder it left out is kept, no state: the next sync lists in
    // full again, and that listing confirms the absence or not
    // (`Mailbox/changes` would never name the folders it left out).
    if (settled) await _saveSyncState(accountId, 'Mailbox', newState);
    log(
      'JMAP full mailbox sync: ${mailboxes.length} mailboxes, state=$newState'
      '${settled ? '' : ' (folders kept unconfirmed, state not kept)'}',
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
        await _db.transaction(() async {
          final marks = await _loadPendingPrune(accountId);
          marks[jmapId] ??= (since: _now(), listings: 1);
          await _savePendingPrune(accountId, marks);
        });
        unawaited(
          _appLogger?.warn(
            'mailbox.listing_untrusted',
            'The server reports the inbox "${row.name}" destroyed: kept, and '
                'the folder list is read in full again; it is removed only '
                'when that listing does not have it either and the server '
                'confirms it is gone',
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

  /// The folders (paths; JMAP ids) listings that were not trusted left
  /// out, with since when and how often ([_prune]).
  Future<Map<String, _Missing>> _loadPendingPrune(String accountId) async {
    final raw = await _loadSyncState(accountId, pendingPruneKey);
    if (raw == null) return {};
    try {
      return {
        for (final MapEntry(:key, :value)
            in (jsonDecode(raw) as Map<String, dynamic>).entries)
          key: _missingFromJson(value as Map<String, dynamic>),
      };
    } catch (_) {
      return {};
    }
  }

  static _Missing _missingFromJson(Map<String, dynamic> json) => (
        since: DateTime.parse(json['since'] as String),
        listings: json['listings'] as int,
      );

  Future<void> _savePendingPrune(
    String accountId,
    Map<String, _Missing> marks,
  ) async {
    if (marks.isEmpty) return _forgetSyncState(accountId, pendingPruneKey);
    await _saveSyncState(
      accountId,
      pendingPruneKey,
      jsonEncode({
        for (final path in marks.keys.toList()..sort())
          path: {
            'since': marks[path]!.since.toUtc().toIso8601String(),
            'listings': marks[path]!.listings,
          },
      }),
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
  /// A listing that was not [trusted] ([_prune]: it had a reason to doubt
  /// it, whatever it removed) drops no stand-in either.
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
  /// phase 5b; #1315): a rename elsewhere lists as a folder gone plus a new
  /// one. A cached folder the listing (its paths [allListed], started at
  /// [readSeq]; each listed folder's STATUS in [statusOf]) no longer has,
  /// and that has no delete queued, is taken for renamed to a new folder of
  /// [listed] (the listed folders less the paths an own rename or move
  /// being sent puts a folder at), when that match is unique both ways (one
  /// new folder for it, no other folder matching that one), and
  /// - on a server that gives folder ids (RFC 8474 `OBJECTID`), when the
  ///   cached folder has one (`srv_mailbox_id`, stored by an earlier
  ///   listing): the listed folder has the same `MAILBOXID`, wherever it
  ///   went (a rename and a move at once too) and whatever it holds (an
  ///   empty folder too, under a new UIDVALIDITY too). A folder whose id
  ///   differs is never taken for it by its contents. A cached folder still
  ///   listed at its path but under another id is "replaced" there: it
  ///   follows its id the same way (two folders that swapped names), and a
  ///   replaced folder whose id is listed nowhere is removed when another
  ///   one follows its id onto its path (deleted, another renamed onto its
  ///   name), or when it has a delete queued (the delete counts as done);
  ///   otherwise it stays, and [MailboxStateWriter.writeServer] re-matches
  ///   its mail (`mailbox.id_changed`);
  /// - else (no ids, or a folder no listing read the id of yet), the new
  ///   folder shares its leaf (a move) or its parent (a rename) with it,
  ///   gives no id or one no other vanished folder has, and
  ///   - has its UIDVALIDITY (from its sync checkpoint; STATUS of the new
  ///     one; RFC 3501 servers keep it across RENAME), and holds the
  ///     Message-IDs cached for it when there are any; or, as that fails on
  ///     servers that give a renamed folder a new one (Stalwart),
  ///   - holds every Message-ID cached for it (at most [_renameProbeIds] of
  ///     them, searched with `UID SEARCH HEADER Message-ID`) and exactly as
  ///     many messages as are cached: an empty folder cannot be recognised
  ///     this way.
  /// The cached folder (its row id stays), its subfolders, its mail and the
  /// queued changes naming it follow ([MailboxStateWriter.serverPathChanged],
  /// [MailboxStateWriter.serverPathsChanged]; App Log warn
  /// `mailbox.renamed_elsewhere`, saying which rule matched). The checkpoint
  /// follows too: a new UIDVALIDITY is then a UIDVALIDITY change of the
  /// folder, whose mail is re-matched by Message-ID (#1314). Anything else
  /// is left to the prune: the changes queued for the folder fail, listed.
  ///
  /// The removals of replaced folders need every listed folder's id: when
  /// a STATUS failed or gave none (ids refused on the way), a folder whose
  /// id seems listed nowhere may be at that path, so nothing is removed,
  /// a replaced folder keeps its stored id ([hold], written without one),
  /// and the listing is not trusted ([doubt], for [_prune]: the #1312
  /// marks and checks decide about the folders it left out).
  ///
  /// Returns the paths of the folders it [moved], the paths whose listed id
  /// is not stored ([hold]), and why the listing is in doubt, or null.
  Future<({Set<String> moved, Set<String> hold, String? doubt})>
      _followRenamesElsewhere(
    imap.ImapClient client,
    String accountId,
    List<imap.Mailbox> listed,
    int readSeq, {
    required Set<String> allListed,
    required Map<String, _ListedStatus> statusOf,
  }) async {
    // Ids refused on the way: this listing goes by the old rules.
    final byId = _idsUsable(client);
    final rows = await (_db.select(_db.mailboxes)
          ..where((t) => t.accountId.equals(accountId)))
        .get();
    final listedPaths = {for (final mb in listed) mb.path};
    String? listedIdAt(String path) =>
        listedPaths.contains(path) ? statusOf[path]?.status?.mailboxId : null;
    // Every listed folder answered with its id: an id found nowhere is gone.
    // A folder that cannot be selected (`\Noselect`, `\NonExistent`: a
    // shared-folders root, a placeholder parent) holds no mail and may
    // answer no STATUS; it does not count.
    final idsComplete = byId &&
        listed
            .where((mb) => !_unselectable(mb))
            .every((mb) => listedIdAt(mb.path) != null);
    // The cached folders whose path the server gives another folder now.
    final replaced = <MailboxRow>[];
    if (byId) {
      for (final r in rows) {
        final id = r.srvMailboxId;
        final now = listedIdAt(r.path);
        if (id == null || now == null || now == id) continue;
        if (r.isLocal || r.srvSeq > readSeq) continue;
        if (await _writer.mayBeMoving(r.id)) continue;
        replaced.add(r);
      }
    }
    final vanished = await _writer.prunable(accountId, allListed, readSeq);
    const none = (moved: <String>{}, hold: <String>{}, doubt: null);
    if (vanished.isEmpty && replaced.isEmpty) {
      // Nothing replaced: the marks of earlier listings are cleared, so a
      // row replaced again later waits from the start.
      await _ageReplaced(accountId, const []);
      return none;
    }
    final cached = {for (final r in rows) r.path};
    final fresh = [
      for (final mb in listed)
        if (!cached.contains(mb.path)) mb.path,
    ];
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
    final freshStatus = {
      for (final path in fresh)
        if (statusOf[path]?.status case final status?) path: status,
    };
    // The paths a folder may have been renamed to, by id: the new ones
    // and the ones another folder took.
    final idTargets = {
      for (final path in [...fresh, for (final r in replaced) r.path])
        if (listedIdAt(path) case final id?) path: id,
    };
    String? idOf(MailboxRow row) => byId ? row.srvMailboxId : null;
    // A new folder whose id a vanished folder has is that one's alone.
    final claimed = {
      for (final v in [...vanished, ...replaced])
        if (idOf(v) case final id?) id,
    };
    final separator = imapSeparatorOf(listed);
    String parentOf(String path) {
      final cut = path.lastIndexOf(separator);
      return cut < 0 ? '' : path.substring(0, cut);
    }

    String leafOf(String path) {
      final cut = path.lastIndexOf(separator);
      return cut < 0 ? path : path.substring(cut + separator.length);
    }

    // Every folder's matches first, so a match is taken only when it is
    // unique both ways: one new folder for the gone one, and no other
    // folder matching that new one.
    final matchesOf = <String, _RenameMatch>{};
    final removeFirst = <MailboxRow>[];
    for (final r in replaced) {
      // Its delete counts as done, as for a vanished folder: the folder at
      // its path is another one, never deleted for it.
      if (await _hasQueuedDelete(r.id)) {
        if (idsComplete) removeFirst.add(r);
        continue;
      }
      final id = r.srvMailboxId!;
      matchesOf[r.path] = (
        to: [
          for (final MapEntry(key: path, value: other) in idTargets.entries)
            if (other == id) path,
        ],
        how: 'MAILBOXID',
        row: r,
        id: id,
      );
    }
    for (final v in vanished) {
      // A folder the user deleted (queued) is never followed: a wrong match
      // would delete another folder. Its delete counts as done by the
      // prune ([MailboxStateWriter.failOpsOfRemoved]).
      if (await _hasQueuedDelete(v.id)) continue;
      final from = v.path;
      final id = idOf(v);
      if (id != null) {
        final same = [
          for (final MapEntry(key: path, value: other) in idTargets.entries)
            if (other == id) path,
        ];
        if (same.isNotEmpty) {
          // The server's own folder id: no guess by name or contents.
          matchesOf[from] = (to: same, how: 'MAILBOXID', row: v, id: id);
          continue;
        }
      }
      final candidates = [
        for (final MapEntry(key: path, value: status) in freshStatus.entries)
          if ((leafOf(from) == leafOf(path) ||
                  parentOf(from) == parentOf(path)) &&
              // Ids that differ (or that name another gone folder): not
              // this folder, whatever it holds.
              (status.mailboxId == null ||
                  (id == null && !claimed.contains(status.mailboxId))))
            path,
      ];
      if (candidates.isEmpty) continue;
      final ids = await _cachedMessageIds(accountId, from);
      final validity = validityOf[from];
      if (validity != null &&
          validityOf.values.where((x) => x == validity).length == 1) {
        final byValidity = [
          for (final path in candidates)
            if (freshStatus[path]!.uidValidity == validity) path,
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
            row: v,
            id: null,
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
        row: v,
        id: null,
      );
    }
    // The unique matches, parents first: their subfolders move with them.
    final ordered = matchesOf.keys.toList()
      ..sort((a, b) => a.length.compareTo(b.length));
    final taken = <String>[];
    for (final from in ordered) {
      final to = matchesOf[from]!.to;
      if (to.length != 1) continue;
      final rivals = matchesOf.entries
          .where((e) => e.key != from && e.value.to.contains(to.single));
      if (rivals.isEmpty) taken.add(from);
    }
    final byIdMoves = [
      for (final from in taken)
        if (matchesOf[from]!.how == 'MAILBOXID') from,
    ];
    // A replaced folder whose id is listed nowhere, onto whose path another
    // folder follows its id: gone (deleted elsewhere, another renamed onto
    // its name).
    final movingIds = {for (final from in byIdMoves) matchesOf[from]!.row.id};
    for (final r in replaced) {
      if (!idsComplete) break;
      if (movingIds.contains(r.id) || removeFirst.contains(r)) continue;
      if (byIdMoves.any((from) => matchesOf[from]!.to.single == r.path)) {
        removeFirst.add(r);
      }
    }
    for (final r in removeFirst) {
      log('Mailbox "${r.path}" is another folder on the server now — '
          'removing local cache');
      await removeLocalMailbox(_db, accountId, r.path, appLogger: _appLogger);
    }
    final before = {for (final r in rows) r.id: r.path};
    // A move onto a path a folder holds that is not moving waits for a
    // later listing ([MailboxStateWriter.serverPathsChanged]).
    final blocked = byIdMoves.isEmpty
        ? const <String>{}
        : await _writer.serverPathsChanged(accountId, [
            for (final from in byIdMoves)
              (matchesOf[from]!.row.id, matchesOf[from]!.to.single),
          ]);
    // A subfolder that went where its parent went is no rename of its own.
    bool carried(String from, String target) => taken.any(
          (p) =>
              p != from &&
              from.startsWith('$p$separator') &&
              target == '${matchesOf[p]!.to.single}${from.substring(p.length)}',
        );
    for (final from in taken) {
      final (:to, :how, :row, :id) = matchesOf[from]!;
      final target = to.single;
      if (how != 'MAILBOXID') {
        // Where the folder is now: a parent's rename may have taken it
        // along, to the target, or onto a listed folder it is not.
        final current = await _writer.rowById(row.id);
        if (current == null || current.path == target) continue;
        if (current.path != from && allListed.contains(current.path)) continue;
        if (await _writer.rowByPath(accountId, target) != null) continue;
        await _writer.serverPathChanged(accountId, current.path, target);
      } else if ((await _writer.rowById(row.id))?.path != target) {
        continue;
      }
      if (carried(from, target)) continue;
      final recognisedBy = how == 'MAILBOXID'
          ? 'its server folder id (MAILBOXID $id), whatever its UIDVALIDITY '
              'and contents'
          : 'its $how';
      unawaited(
        _appLogger?.warn(
          'mailbox.renamed_elsewhere',
          'The folder "$from" is "$target" on the server now (renamed or '
              'moved by another client, recognised by $recognisedBy); its '
              'mail and the changes queued for it follow',
          accountId: accountId,
          mailboxPath: target,
          data: {
            'from': from,
            'to': target,
            'by': how,
            if (id != null) 'mailboxId': id,
          },
        ),
      );
    }
    final after = await (_db.select(_db.mailboxes)
          ..where((t) => t.accountId.equals(accountId)))
        .get();
    // A replaced folder whose id is listed nowhere while ids are missing:
    // held (its id kept) until it has been so for [_pruneMinAge] and
    // [_pruneMinListings] listings, as the #1312 marks; then the new id is
    // taken ([MailboxStateWriter.writeServer]: `mailbox.id_changed`), so a
    // STATUS that always fails cannot keep a listing in doubt for good.
    final unsettled = [
      for (final r in after)
        if (byId && !idsComplete)
          if (r.srvMailboxId case final id?)
            if (listedIdAt(r.path) case final now? when now != id) r,
    ];
    final aged = await _ageReplaced(accountId, unsettled);
    // Ids missing (a STATUS failed, or ids were refused on the way) while
    // a cached folder with an id is gone or replaced: it may be at a path
    // whose id did not come.
    final unsure = supportsMailboxIds(client.serverInfo) &&
        !idsComplete &&
        (unsettled.any((r) => !aged.contains(r.id)) ||
            vanished.any((v) => v.srvMailboxId != null));
    return (
      moved: {
        for (final r in after)
          if (before[r.id] case final old? when old != r.path) r.path,
      },
      hold: {
        for (final r in unsettled)
          if (!aged.contains(r.id)) r.path,
      },
      doubt: blocked.isNotEmpty
          ? 'a folder renamed elsewhere waits for a path'
          : unsure
              ? 'folder ids incomplete'
              : null,
    );
  }

  /// Whether a new folder of a listing in doubt ([listed], its STATUS) is
  /// stored anyway: its id is known and no cached folder has it, so it is
  /// no cached folder whose id did not come.
  bool _storableInDoubt(
    _ListedStatus listed,
    Set<String> cachedIds,
    imap.ImapClient client,
  ) {
    final id = listed.status?.mailboxId;
    return _idsUsable(client) && id != null && !cachedIds.contains(id);
  }

  /// `sync_states` key (per account) of the cached folders a listing found
  /// replaced at their path while folder ids were missing (#1315): row id,
  /// since when, and by how many listings ([_ageReplaced]).
  static const _pendingReplaceKey = 'Mailbox:PendingReplace';

  /// Records that the rows [unsettled] were replaced at their paths in one
  /// more listing (marks of other rows are dropped) and returns the ids of
  /// those replaced for at least [_pruneMinAge] and [_pruneMinListings]
  /// listings.
  Future<Set<String>> _ageReplaced(
    String accountId,
    List<MailboxRow> unsettled,
  ) async {
    final raw = await _loadSyncState(accountId, _pendingReplaceKey);
    var marks = <String, _Missing>{};
    if (raw != null) {
      try {
        marks = {
          for (final MapEntry(:key, :value)
              in (jsonDecode(raw) as Map<String, dynamic>).entries)
            key: _missingFromJson(value as Map<String, dynamic>),
        };
      } catch (_) {}
    }
    final now = _now();
    final next = <String, _Missing>{
      for (final r in unsettled)
        r.id: switch (marks[r.id]) {
          final m? => (since: m.since, listings: m.listings + 1),
          null => (since: now, listings: 1),
        },
    };
    if (next.isEmpty) {
      if (raw != null) await _forgetSyncState(accountId, _pendingReplaceKey);
      return const {};
    }
    await _saveSyncState(
      accountId,
      _pendingReplaceKey,
      jsonEncode({
        for (final MapEntry(:key, :value) in next.entries)
          key: {
            'since': value.since.toUtc().toIso8601String(),
            'listings': value.listings,
          },
      }),
    );
    return {
      for (final MapEntry(:key, :value) in next.entries)
        if (now.difference(value.since) >= _pruneMinAge &&
            value.listings >= _pruneMinListings)
          key,
    };
  }

  /// A folder that cannot be selected: `\Noselect` or `\NonExistent`.
  static bool _unselectable(imap.Mailbox mb) =>
      mb.isNotSelectable || mb.hasFlag(imap.MailboxFlag.nonExistent);

  /// Whether [client]'s server gives folder ids and none was refused on
  /// this connection ([_status]).
  bool _idsUsable(imap.ImapClient client) =>
      supportsMailboxIds(client.serverInfo) &&
      !(_mailboxIdsRefused[client] ?? false);

  /// `STATUS` of [box] for [flags], with the folder's `MAILBOXID` when the
  /// server gives folder ids ([supportsMailboxIds]; #1315). A server that
  /// advertises them but refuses the item while a plain `STATUS` of the
  /// folder works is asked without it on this connection from then on.
  Future<ImapFolderStatus> _status(
    imap.ImapClient client,
    imap.Mailbox box,
    List<imap.StatusFlags> flags,
  ) async {
    Future<ImapFolderStatus> plain() async {
      final status = await client.statusMailbox(box, flags);
      return (
        messages: status.messagesExists,
        unseen: status.messagesUnseen,
        uidValidity: status.uidValidity,
        mailboxId: null,
      );
    }

    if (!supportsMailboxIds(client.serverInfo) ||
        (_mailboxIdsRefused[client] ?? false)) {
      return plain();
    }
    try {
      return await _statusWithMailboxId(client, box, flags);
    } catch (e) {
      if (!client.isConnected) rethrow;
      // The folder's own failure (gone, say) fails the plain one too.
      final status = await plain();
      _mailboxIdsRefused[client] = true;
      log('STATUS with MAILBOXID refused for ${box.path}: $e');
      unawaited(
        _appLogger?.warn(
          'mailbox.mailbox_ids_refused',
          'The server advertises folder ids (OBJECTID) but did not give the '
              'MAILBOXID of "${box.path}" while a plain STATUS works: this '
              'listing goes on without folder ids',
          mailboxPath: box.path,
          error: e,
        ),
      );
      return status;
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
  /// (#1312, [_untrustedReason]): it is empty, leaves out the inbox or a
  /// folder with a role, or leaves out at least 2 cached server folders
  /// that are more than half of them. The folders it left out are kept and
  /// marked in `sync_states` ([pendingPruneKey]: since when, and by how many
  /// listings). A marked folder that a later untrusted listing leaves out
  /// again is asked about on its own ([check]: IMAP `STATUS`, JMAP
  /// `Mailbox/get` of its id): removed when the server says it is gone
  /// (`NONEXISTENT`, `notFound`); kept when it is there; when the answer
  /// says neither, removed only once it has been missing for at least
  /// [_pruneMinAge] and [_pruneMinListings] listings, so a glitch that
  /// outlasts a sync interval does not confirm itself. The IMAP INBOX is
  /// never removed (RFC 3501: every account has one). A listing that lists
  /// a marked folder again clears its mark (App Log info
  /// `mailbox.listing_untrusted_cleared`); App Log warn
  /// `mailbox.listing_untrusted` gives the counts of an untrusted one.
  ///
  /// Returns whether the listing was [trusted] (no reason to doubt it) and
  /// whether it is [settled] (no folder it left out is kept).
  Future<({bool trusted, bool settled})> _prune(
    String accountId,
    Set<String> keepPaths,
    int readSeq, {
    required bool jmap,
    required Future<_FolderCheck> Function(String path) check,
    String? doubt,
  }) async {
    final candidates = await _writer.prunable(accountId, keepPaths, readSeq);
    final reason = candidates.isNotEmpty && doubt != null
        ? doubt
        : await _untrustedReason(accountId, keepPaths, candidates);
    bool neverRemoved(MailboxRow r) => !jmap && r.path.toUpperCase() == 'INBOX';
    // The server is asked (network) before the marks are read and written
    // in one transaction: only about folders an earlier listing marked.
    final checks = <String, _FolderCheck>{};
    if (reason != null) {
      final marked = await _loadPendingPrune(accountId);
      for (final r in candidates) {
        if (!marked.containsKey(r.path) || neverRemoved(r)) continue;
        checks[r.path] = await check(r.path);
      }
    }
    final now = _now();
    final remove = <MailboxRow>[];
    final held = <MailboxRow>[];
    final confirmed = <String>[];
    final aged = <String>[];
    final present = <String>[];
    final cleared = <String>[];
    // One transaction: a concurrent listing (the folder diagnostics screen)
    // reads the marks this one wrote, never a half.
    await _db.transaction(() async {
      final marks = await _loadPendingPrune(accountId);
      final next = <String, _Missing>{};
      for (final r in candidates) {
        final mark = marks[r.path];
        final missing = mark == null
            ? (since: now, listings: 1)
            : (since: mark.since, listings: mark.listings + 1);
        if (reason == null && !neverRemoved(r)) {
          remove.add(r);
          continue;
        }
        if (mark != null && !neverRemoved(r)) {
          final verdict = checks[r.path] ?? _FolderCheck.unknown;
          if (verdict == _FolderCheck.gone) {
            confirmed.add(r.path);
            remove.add(r);
            continue;
          }
          if (verdict == _FolderCheck.present) present.add(r.path);
          if (verdict == _FolderCheck.unknown &&
              now.difference(missing.since) >= _pruneMinAge &&
              missing.listings >= _pruneMinListings) {
            aged.add(r.path);
            remove.add(r);
            continue;
          }
        }
        next[r.path] = missing;
        held.add(r);
      }
      for (final path in marks.keys) {
        if (keepPaths.contains(path)) cleared.add(path);
      }
      await _savePendingPrune(accountId, next);
    });
    if (reason != null) {
      unawaited(
        _appLogger?.warn(
          'mailbox.listing_untrusted',
          'The server listed ${keepPaths.length} folder(s) and left out '
              '${candidates.length} cached one(s) ($reason): this may be a '
              'glitch, so ${held.length} of them are kept until the server '
              'confirms they are gone; ${remove.length} are removed '
              '(${confirmed.length} confirmed gone, ${aged.length} missing '
              'for ${_pruneMinAge.inMinutes} min and $_pruneMinListings '
              'listings)',
          accountId: accountId,
          data: {
            'reason': reason,
            'listed': keepPaths.length,
            'missing': candidates.length,
            'kept': held.length,
            'removed': remove.length,
            'confirmedGone': confirmed.length,
            'removedAfterWaiting': aged.length,
            'stillThere': present.length,
            'keptPaths': [for (final r in held.take(50)) r.path],
          },
        ),
      );
    }
    if (cleared.isNotEmpty) {
      unawaited(
        _appLogger?.info(
          'mailbox.listing_untrusted_cleared',
          'The server lists ${cleared.length} folder(s) again that an '
              'earlier listing left out; they were kept and are no longer '
              'marked',
          accountId: accountId,
          data: {'paths': cleared.take(50).toList()},
        ),
      );
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
    return (trusted: reason == null, settled: held.isEmpty);
  }

  /// How long a folder an untrusted listing left out is kept at least when
  /// the server's answer about it is not definite ([_prune]).
  static const _pruneMinAge = Duration(hours: 1);

  /// How many listings (the first that left it out included) must leave out
  /// a folder before it is removed without a definite answer ([_prune]).
  static const _pruneMinListings = 3;

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
    if (missing.any((r) => r.role?.isNotEmpty ?? false)) {
      return 'role folder missing';
    }
    if (missing.length < 2) return null;
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

  /// [_prune]'s question about the IMAP folder [path] a listing left out:
  /// `STATUS` of it answers (there), or fails with `NONEXISTENT` or an error
  /// a LIST confirms ([confirmImapMailboxGone]: gone); anything else says
  /// nothing.
  Future<_FolderCheck> _imapFolderCheck(
    imap.ImapClient client,
    String path,
    String separator,
  ) async {
    try {
      await client.statusMailbox(
        imap.Mailbox(
          encodedName: path,
          encodedPath: encodeImapMailboxPath(path, separator),
          pathSeparator: separator,
          flags: [],
        ),
        [imap.StatusFlags.messages],
      );
      return _FolderCheck.present;
    } catch (e) {
      if (await confirmImapMailboxGone(client, path, e)) {
        return _FolderCheck.gone;
      }
      return _FolderCheck.unknown;
    }
  }

  /// [_prune]'s question about the JMAP mailbox [id] a listing left out:
  /// `Mailbox/get` of it lists it (there) or names it in `notFound` (gone).
  Future<_FolderCheck> _jmapFolderCheck(JmapClient jmap, String id) async {
    try {
      final responses = await jmap.call([
        [
          'Mailbox/get',
          {
            'accountId': jmap.accountId,
            'ids': [id],
            'properties': ['id'],
          },
          '0',
        ],
      ]);
      final result = _responseArgs(responses, 0, 'Mailbox/get');
      final list = result['list'];
      if (list is List &&
          list.any((m) => m is Map<String, dynamic> && m['id'] == id)) {
        return _FolderCheck.present;
      }
      final notFound = result['notFound'];
      if (notFound is List && notFound.contains(id)) return _FolderCheck.gone;
      return _FolderCheck.unknown;
    } catch (_) {
      return _FolderCheck.unknown;
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
