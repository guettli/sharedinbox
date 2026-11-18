import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/db/keyword_fold.dart' show foldableOpStates;
import 'package:sharedinbox/data/db/mailbox_fold.dart';
import 'package:sharedinbox/data/repositories/email_state_writer.dart';
import 'package:sharedinbox/data/repositories/thread_aggregate.dart';

/// A folder with this name is already there (locally, or on the server).
class MailboxExistsException implements Exception {
  MailboxExistsException(this.name);

  final String name;

  @override
  String toString() => 'A folder named "$name" already exists';
}

/// A mailbox op the server refused for good: it becomes `failed`.
class MailboxOpRefused implements Exception {
  MailboxOpRefused(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What [MailboxStateWriter.undoLatest] did.
enum MailboxUndo {
  /// The folder had no move or delete to undo.
  nothing,

  /// The op was never sent and is gone: the server never learns of it.
  cancelled,

  /// The move may have reached the server: a move back is queued.
  reversed,

  /// The delete was sent before (no answer): it may have reached the
  /// server and cannot be undone.
  tooLate,

  /// The delete is being sent right now (claimed by a flush): it cannot be
  /// cancelled any more; if it fails, the folder shows again.
  sending,
}

/// SQL (correlated on the `mailboxes` alias [m]): whether the mailbox shows.
/// A mailbox created offline shows only while its `create_mailbox` op folds
/// ([localMailboxShown]); a mailbox with a queued delete shows nowhere
/// (`local_hidden`, [foldMailboxHidden]).
String mailboxShownSql(String m) => 'NOT $m.local_hidden AND '
    'NOT ($m.is_local AND NOT EXISTS (SELECT 1 FROM pending_changes p '
    "WHERE p.resource_id = $m.id AND p.change_type = '$createMailboxOp' "
    'AND p.state IN ($_foldableSql)))';

final _foldableSql = foldableOpStates.map((s) => "'$s'").join(', ');

/// Payload key of an acked create: the stand-in path the folder had.
const _localPathKey = 'localPath';

/// Payload key of an acked op whose ack rested on a read of the server.
const _readConfirmedKey = 'readConfirmed';

/// Payload key of a change failed with a folder's create: the folder's id.
const _failedWithFolderKey = 'failedWithFolder';

final _random = Random.secure();

String _hex(int length) =>
    List.generate(length, (_) => _random.nextInt(16).toRadixString(16)).join();

/// The mailbox state writer (SYNC-REDESIGN.md §7, phase 5a): the only
/// writer of the `mailboxes` table. The mailbox overlay works like the
/// email one: `srv_name` is what the server last said, `local_name` the
/// fold of the mailbox's queued ops ([foldMailboxName]), and `name` the
/// effective `COALESCE(local_name, srv_name)`. `display_path` is derived
/// from the effective names ([displayPaths]).
///
/// Its roles:
/// - **user actions** ([createLocal], [enqueueRename], [ensureLocal]):
///   write the local row and queue the op in one transaction;
/// - the **fold** ([refold]);
/// - the **server-write gate** ([writeServer], [prunablePaths]): sync's
///   mailbox listings, monotonic by `srv_seq`, settling acked ops;
/// - the **flush outcomes** ([ack], [fail], [discard], [retry]) and the
///   server facts they record ([serverPathChanged]);
/// - the remaining row writes (removal, force resync, the server-first
///   folder move and delete that phase 5b turns into ops).
///
/// `scripts/check_mailbox_writes.sh` keeps every other file from writing
/// `mailboxes`.
class MailboxStateWriter {
  MailboxStateWriter(
    this._db, {
    AppLogger? appLogger,
    DateTime Function() now = DateTime.now,
  })  : _appLogger = appLogger,
        _now = now,
        _emails = EmailStateWriter(_db, appLogger: appLogger, now: now);

  final AppDatabase _db;
  final AppLogger? _appLogger;
  final DateTime Function() _now;
  final EmailStateWriter _emails;

  // ── Reads ──────────────────────────────────────────────────────────────

  Future<MailboxRow?> rowById(String id) =>
      (_db.select(_db.mailboxes)..where((t) => t.id.equals(id)))
          .getSingleOrNull();

  Future<MailboxRow?> rowByPath(String accountId, String path) =>
      (_db.select(_db.mailboxes)
            ..where((t) => t.accountId.equals(accountId) & t.path.equals(path))
            ..limit(1))
          .getSingleOrNull();

  Future<List<MailboxRow>> _rowsOf(String accountId) =>
      (_db.select(_db.mailboxes)..where((t) => t.accountId.equals(accountId)))
          .get();

  Future<bool> _isJmap(String accountId) async =>
      (await _db.customSelect(
        'SELECT account_type FROM accounts WHERE id = ?1',
        variables: [Variable.withString(accountId)],
      ).getSingleOrNull())
          ?.read<String>('account_type') ==
      'jmap';

  /// The ops of mailbox [mailboxId], oldest first.
  Future<List<PendingChangeRow>> _opsOf(String mailboxId) =>
      (_db.select(_db.pendingChanges)
            ..where(
              (t) =>
                  t.resourceType.equals(mailboxResourceType) &
                  t.resourceId.equals(mailboxId),
            )
            ..orderBy([(t) => OrderingTerm.asc(t.id)]))
          .get();

  /// `sync_states` key of the IMAP hierarchy separator the server's LIST
  /// last gave for the account.
  static const _separatorKey = 'Mailbox:ImapSeparator';

  /// Records [separator], the hierarchy separator an IMAP LIST of
  /// [accountId] answered with: subfolder paths, display paths and the
  /// subfolders a rename moves all go by it.
  Future<void> recordImapSeparator(String accountId, String separator) async {
    if (separator.isEmpty) return;
    await _db.into(_db.syncStates).insertOnConflictUpdate(
          SyncStatesCompanion.insert(
            accountId: accountId,
            resourceType: _separatorKey,
            state: separator,
            syncedAt: _now(),
          ),
        );
  }

  /// The IMAP hierarchy separator of [accountId]: the one its last LIST
  /// gave; before any, `.` when its folders live below `INBOX.`, else `/`.
  Future<String> imapSeparator(String accountId) async {
    final stored = await (_db.select(_db.syncStates)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.resourceType.equals(_separatorKey),
          ))
        .getSingleOrNull();
    if (stored != null && stored.state.isNotEmpty) return stored.state;
    final rows = await _rowsOf(accountId);
    return rows.any((r) => r.path.startsWith('INBOX.')) ? '.' : '/';
  }

  /// The paths of [accountId]'s mailboxes that have no server copy yet:
  /// an email op naming one waits for its create.
  Future<Set<String>> localPaths(String accountId) async => {
        for (final r in await _db.customSelect(
          'SELECT path FROM mailboxes WHERE account_id = ?1 AND is_local = 1',
          variables: [Variable.withString(accountId)],
        ).get())
          r.read<String>('path'),
      };

  /// The folder path a change naming [path] means: [path] itself while a
  /// mailbox has it, else the path of the folder whose create had [path]
  /// as its stand-in (`localPath` of the acked create: a screen opened
  /// before the ack still names it), else null (no such folder).
  Future<String?> resolveStandIn(String accountId, String path) async {
    if (await rowByPath(accountId, path) != null) return path;
    for (final op in await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.resourceType.equals(mailboxResourceType) &
                t.changeType.equals(createMailboxOp),
          ))
        .get()) {
      if (_payloadOf(op)?[_localPathKey] != path) continue;
      return (await rowById(op.resourceId))?.path;
    }
    return null;
  }

  /// The paths of [accountId]'s folders a rename, move or delete of which
  /// is being sent, with their subfolders on IMAP (a rename or move takes
  /// them along): a mail change naming one waits, or it would name a
  /// folder the server is just renaming, moving or deleting.
  Future<Set<String>> pathsBeingRenamed(String accountId) async {
    final paths = <String>{
      for (final op in await (_db.select(_db.pendingChanges)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.resourceType.equals(mailboxResourceType) &
                  t.changeType.isIn(
                    const [renameMailboxOp, moveMailboxOp, deleteMailboxOp],
                  ) &
                  t.state.equals('inflight'),
            ))
          .get())
        if (await rowById(op.resourceId) case final row?) row.path,
    };
    if (paths.isEmpty || await _isJmap(accountId)) return paths;
    final separator = await imapSeparator(accountId);
    return {
      ...paths,
      for (final r in await _rowsOf(accountId))
        if (paths.any((p) => r.path.startsWith('$p$separator'))) r.path,
    };
  }

  /// Whether [path] is [folder] or (IMAP, with [separator]) one of its
  /// subfolders.
  static bool _isAtOrBelow(String path, String folder, String? separator) =>
      path == folder ||
      (separator != null && path.startsWith('$folder$separator'));

  /// Whether a mail change of [accountId] naming folder [path] (or, on
  /// IMAP, a subfolder of it) is being sent right now (another flush): a
  /// rename, move or delete of the folder waits for it.
  Future<bool> mailChangeInFlightFor(String accountId, String path) =>
      mailChangeQueuedFor(accountId, path, states: const ['inflight']);

  /// Whether a mail change of [accountId] in one of [states] (and queued
  /// before op [before], when given) names folder [path] or, on IMAP, a
  /// subfolder of it.
  Future<bool> mailChangeQueuedFor(
    String accountId,
    String path, {
    required List<String> states,
    int? before,
  }) async {
    final separator =
        await _isJmap(accountId) ? null : await imapSeparator(accountId);
    for (final op in await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.resourceType.equals(mailboxResourceType).not() &
                t.state.isIn(states) &
                (before == null
                    ? const Constant(true)
                    : t.id.isSmallerThanValue(before)),
          ))
        .get()) {
      final payload = _payloadOf(op);
      for (final key in emailOpFolderKeys) {
        final named = payload?[key];
        if (named is String && _isAtOrBelow(named, path, separator)) {
          return true;
        }
      }
    }
    return false;
  }

  /// Whether a mail change of [accountId] in one of [states], queued at any
  /// time, takes mail out of folder [path] (or, on IMAP, a subfolder): it
  /// names the folder as its source (`src`, `mailboxPath`) and puts the mail
  /// elsewhere (or changes it in place). A delete of the folder waits for
  /// it, so the mail is saved before the folder goes.
  Future<bool> mailLeavingQueuedFor(
    String accountId,
    String path, {
    required List<String> states,
  }) async {
    final separator =
        await _isJmap(accountId) ? null : await imapSeparator(accountId);
    for (final op in await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.resourceType.equals(mailboxResourceType).not() &
                t.state.isIn(states),
          ))
        .get()) {
      final payload = _payloadOf(op);
      final dest = payload?['dest'];
      if (dest is String && _isAtOrBelow(dest, path, separator)) continue;
      for (final key in const ['src', 'mailboxPath']) {
        final named = payload?[key];
        if (named is String && _isAtOrBelow(named, path, separator)) {
          return true;
        }
      }
    }
    return false;
  }

  /// Whether a rename or move of mailbox [mailboxId] is being sent or may
  /// have reached the server (sent before without an answer).
  Future<bool> mayBeMoving(String mailboxId) async =>
      (await _opsOf(mailboxId)).any(
        (o) =>
            (o.changeType == renameMailboxOp ||
                o.changeType == moveMailboxOp) &&
            (o.state == 'inflight' ||
                (o.attempts > 0 &&
                    const ['pending', 'stuck'].contains(o.state))),
      );

  /// Whether a subfolder (on the server) of [mailbox] has a folder op
  /// queued before op [before] that is not done yet (queued, being sent,
  /// stuck): a delete of [mailbox] waits for it (a subfolder being moved
  /// out or deleted first).
  Future<bool> subfolderOpQueued(
    MailboxRow mailbox, {
    required int before,
  }) async {
    final jmap = await _isJmap(mailbox.accountId);
    final separator = await imapSeparator(mailbox.accountId);
    for (final r in await _rowsOf(mailbox.accountId)) {
      final child = jmap
          ? r.parentId == mailbox.path
          : r.path.startsWith('${mailbox.path}$separator');
      if (!child) continue;
      final queued = (await _opsOf(r.id)).any(
        (o) =>
            o.id < before &&
            const ['pending', 'inflight', 'stuck'].contains(o.state),
      );
      if (queued) return true;
    }
    return false;
  }

  /// The folders of [accountId] with a delete queued, being sent or stuck,
  /// by path, with the id of that delete: a mail change queued after it
  /// that names the folder waits until it settles (an Undo's move back
  /// into the folder must not be sent and then deleted with it); once the
  /// delete is done it fails, listed ("folder deleted").
  Future<Map<String, int>> pathsBeingDeleted(String accountId) async => {
        for (final op in await (_db.select(_db.pendingChanges)
              ..where(
                (t) =>
                    t.accountId.equals(accountId) &
                    t.resourceType.equals(mailboxResourceType) &
                    t.changeType.equals(deleteMailboxOp) &
                    t.state.isIn(const ['pending', 'inflight', 'stuck']),
              ))
            .get())
          if (await rowById(op.resourceId) case final row?) row.path: op.id,
      };

  /// A free `mailboxes.id` for a new row at [path]: `account:path` as
  /// sync has always made them, or a random one when a renamed row keeps
  /// that id (ids are frozen, the path is not).
  Future<String> _freeId(String accountId, String path) async {
    final plain = '$accountId:$path'; // not an email id
    if (await rowById(plain) == null) return plain;
    return '$accountId:#mailbox-${_hex(16)}'; // not an email id
  }

  // ── User actions ───────────────────────────────────────────────────────

  /// Creates the folder [segments] (a nested name, outermost first) of
  /// [accountId] below [parent] (top level when null), locally and at once:
  /// every level that is not cached yet gets a local row (`is_local`) and a
  /// queued `create_mailbox` op, in one transaction. The leaf gets [role].
  /// Returns the leaf's row. Throws [MailboxExistsException] when the leaf
  /// is cached (and shown) already.
  ///
  /// A local row's `path` is a stand-in until its create's ack: on IMAP the
  /// path it will most likely have (the parent's path, the hierarchy
  /// separator the account's paths use, the name), on JMAP
  /// [localJmapMailboxPrefix] and a random part. Mail moved into it waits
  /// for the create ([localPaths]).
  Future<MailboxRow> createLocal({
    required String accountId,
    required List<String> segments,
    String? role,
    MailboxRow? parent,
  }) async {
    final jmap = await _isJmap(accountId);
    final created = <String>[];
    final leaf = await _db.transaction(() async {
      final rows = await _rowsOf(accountId);
      final shown = await _shownIds(accountId);
      final separator = await imapSeparator(accountId);
      var parentPath = parent?.path;
      MailboxRow? current;
      for (var i = 0; i < segments.length; i++) {
        final segment = segments[i];
        final isLeaf = i == segments.length - 1;
        final imapPath =
            parentPath == null ? segment : '$parentPath$separator$segment';
        final existing = rows
            .where(
              (r) =>
                  shown.contains(r.id) &&
                  r.name == segment &&
                  (jmap
                      ? effectiveMailboxParent(
                            parentId: r.parentId,
                            localParent: r.localParent,
                          ) ==
                          parentPath
                      : r.path == imapPath),
            )
            .firstOrNull;
        if (existing != null) {
          if (isLeaf) throw MailboxExistsException(segments.join('/'));
          parentPath = existing.path;
          current = existing;
          continue;
        }
        final path = jmap ? '$localJmapMailboxPrefix${_hex(32)}' : imapPath;
        final hidden = await rowByPath(accountId, path);
        if (hidden != null) {
          // A folder created offline whose create failed or was given up,
          // at the path this one gets: it is queued again.
          if (!hidden.isLocal || shown.contains(hidden.id)) {
            throw MailboxExistsException(segments.join('/'));
          }
          await _queueCreate(hidden, segment, parentPath, isLeaf ? role : null);
          created.add(hidden.id);
          parentPath = hidden.path;
          current = hidden;
          continue;
        }
        final id = await _freeId(accountId, path);
        await _db.into(_db.mailboxes).insert(
              MailboxesCompanion.insert(
                id: id,
                accountId: accountId,
                path: path,
                name: segment,
                localName: Value(segment),
                isLocal: const Value(true),
                role: Value(isLeaf ? role : null),
                displayPath: Value(path),
                parentId: Value(jmap ? parentPath : null),
              ),
            );
        await _insertOp(
          accountId,
          id,
          createMailboxOp,
          _createPayload(segment, parentPath, isLeaf ? role : null),
        );
        created.add(id);
        parentPath = path;
        current = await rowById(id);
      }
      for (final id in created) {
        await _refoldRow(id);
      }
      await rebuildDisplayPaths(accountId);
      return rowById(current!.id);
    });
    return leaf!;
  }

  /// Makes sure [accountId] has a mailbox at [path] (the JMAP `Snoozed`
  /// stand-in a snooze uses before the server's Snoozed folder is known):
  /// a local row with a queued create, or the create queued again when an
  /// earlier one failed. Nothing when the mailbox exists or is being
  /// created.
  Future<void> ensureLocal({
    required String accountId,
    required String path,
    required String name,
    String? role,
  }) =>
      _db.transaction(() async {
        final row = await rowByPath(accountId, path);
        if (row == null) {
          final id = await _freeId(accountId, path);
          await _db.into(_db.mailboxes).insert(
                MailboxesCompanion.insert(
                  id: id,
                  accountId: accountId,
                  path: path,
                  name: name,
                  localName: Value(name),
                  isLocal: const Value(true),
                  role: Value(role),
                  displayPath: Value(name),
                ),
              );
          await _insertOp(
            accountId,
            id,
            createMailboxOp,
            _createPayload(name, null, role),
          );
          await _refoldRow(id);
          await rebuildDisplayPaths(accountId);
          return;
        }
        if (!row.isLocal) return;
        final ops = await _opsOf(row.id);
        if (localMailboxShown(ops.map(_foldOpOf))) return;
        await _queueCreate(row, name, null, role);
        await _refoldRow(row.id);
      });

  /// The folder of counterpart account [accountId] that stands for a
  /// folder called [name] (role [role]) which another account's move
  /// ([primarySeq]) puts a shared server mail into, while [accountId] does
  /// not know that folder yet (SYNC-REDESIGN.md §6, §7; phase 5b): a local
  /// row whose `create_mailbox` is a shadow of [primarySeq], never sent
  /// (the other account creates or has the folder on the shared server).
  /// The twin's shadow move names its path and so waits on it, shown
  /// there. A listing that finds the folder adopts the row
  /// ([writeServer]); one that started after the primary's ack and does
  /// not, drops it ([dropOrphanedCounterpartFolders]). Reuses such a row
  /// already made for the name. Returns its path.
  Future<String> ensureCounterpartFolder({
    required String accountId,
    required String name,
    required String? role,
    required int primarySeq,
  }) =>
      _db.transaction(() async {
        for (final r in await _rowsOf(accountId)) {
          if (!r.isLocal || r.localHidden || r.name != name) continue;
          if (await _counterpartCreateOf(r.id) == null) continue;
          // One shadow create per move that needs the stand-in: the row
          // stays while any of them is live (an Undo of the first move
          // must not drop the folder a later twin shows in).
          final origin = EmailStateWriter.shadowOrigin(primarySeq);
          final mine = (await _opsOf(r.id)).any((o) => o.origin == origin);
          if (!mine) {
            await _insertShadowCreate(accountId, r.id, name, role, primarySeq);
          }
          return r.path;
        }
        final jmap = await _isJmap(accountId);
        final path = jmap ? '$localJmapMailboxPrefix${_hex(32)}' : name;
        if (await rowByPath(accountId, path) != null) {
          // A folder of this account has the path the stand-in would get
          // (hidden or failed): the twin waits under a random one.
          return _insertCounterpartFolder(
            accountId,
            '$localJmapMailboxPrefix${_hex(32)}',
            name,
            role,
            primarySeq,
          );
        }
        return _insertCounterpartFolder(
          accountId,
          path,
          name,
          role,
          primarySeq,
        );
      });

  Future<String> _insertCounterpartFolder(
    String accountId,
    String path,
    String name,
    String? role,
    int primarySeq,
  ) async {
    final id = await _freeId(accountId, path);
    await _db.into(_db.mailboxes).insert(
          MailboxesCompanion.insert(
            id: id,
            accountId: accountId,
            path: path,
            name: name,
            localName: Value(name),
            isLocal: const Value(true),
            role: Value(role),
            displayPath: Value(name),
          ),
        );
    await _insertShadowCreate(accountId, id, name, role, primarySeq);
    await _refoldRow(id);
    await rebuildDisplayPaths(accountId);
    _log(
      (logger) => logger.info(
        'mailbox.counterpart_folder',
        'Showing "$name" for a mail another account moved into a folder of '
            'that name, which this account has not listed yet',
        accountId: accountId,
        mailboxPath: path,
        data: {'primaryChangeId': primarySeq},
      ),
    );
    return path;
  }

  /// A `create_mailbox` of counterpart stand-in [mailboxId], a shadow of
  /// move [primarySeq]: folded, never sent, ended with its primary.
  Future<void> _insertShadowCreate(
    String accountId,
    String mailboxId,
    String name,
    String? role,
    int primarySeq,
  ) =>
      _db.into(_db.pendingChanges).insert(
            PendingChangesCompanion.insert(
              accountId: accountId,
              resourceType: mailboxResourceType,
              resourceId: mailboxId,
              changeType: createMailboxOp,
              payload: _createPayload(name, null, role),
              createdAt: _now(),
              state: const Value('shadow'),
              origin: Value(EmailStateWriter.shadowOrigin(primarySeq)),
            ),
          );

  /// The counterpart shadow create of mailbox [mailboxId] (shadow, or
  /// acked with its primary), or null.
  Future<PendingChangeRow?> _counterpartCreateOf(String mailboxId) async =>
      (await _opsOf(mailboxId))
          .where(
            (o) =>
                o.changeType == createMailboxOp &&
                (o.origin?.startsWith('counterpart:') ?? false) &&
                const ['shadow', 'acked'].contains(o.state),
          )
          .firstOrNull;

  /// Drops the counterpart shadow creates of mailbox [mailboxId]: a
  /// listing found the folder on the server.
  Future<void> _dropShadowCreates(String mailboxId) async {
    final dropped = await (_db.delete(_db.pendingChanges)
          ..where(
            (t) =>
                t.resourceType.equals(mailboxResourceType) &
                t.resourceId.equals(mailboxId) &
                t.changeType.equals(createMailboxOp) &
                t.origin.like('counterpart:%'),
          ))
        .go();
    if (dropped > 0) await _refoldRow(mailboxId);
  }

  /// A counterpart's stand-in folder ([ensureCounterpartFolder]) of
  /// [accountId] called [name] (below [parentId] on JMAP) that a listing
  /// lists at [path], which no row has: the row takes that path (its id
  /// stays; the twin's shadow move follows, [serverPathChanged]). Returns
  /// whether one was adopted.
  Future<bool> _adoptCounterpartFolder(
    String accountId,
    String path,
    String name,
    String? parentId,
  ) async {
    final jmap = await _isJmap(accountId);
    final candidates = <MailboxRow>[];
    for (final r in await _rowsOf(accountId)) {
      if (!r.isLocal || r.name != name) continue;
      if (jmap && r.parentId != parentId) continue;
      if (await _counterpartCreateOf(r.id) != null) candidates.add(r);
    }
    if (candidates.length != 1) return false;
    final local = candidates.single;
    await serverPathChanged(accountId, local.path, path);
    _log(
      (logger) => logger.warn(
        'mailbox.counterpart_folder_adopted',
        'The folder "$name" shown for a counterpart\'s move is the server\'s '
            'folder now; the mail waiting for it follows',
        accountId: accountId,
        mailboxPath: path,
        data: {'from': local.path, 'to': path, 'mailboxId': local.id},
      ),
    );
    return true;
  }

  /// Drops [accountId]'s counterpart stand-in folders that will not be
  /// found: their shadow create was dropped with its primary (the move it
  /// stood for failed or was undone), or, with [listedSeq], a listing
  /// started after the primary's ack did not find the folder. The row
  /// goes (a mail still shown in it shows where its account has it once
  /// its own shadow settles); App Log warn `mailbox.counterpart_folder_dropped`.
  Future<void> dropOrphanedCounterpartFolders(
    String accountId, {
    int? listedSeq,
  }) =>
      _db.transaction(() async {
        for (final r in await _rowsOf(accountId)) {
          if (!r.isLocal) continue;
          final ops = await _opsOf(r.id);
          final creates =
              ops.where((o) => o.changeType == createMailboxOp).toList();
          final counterpart = creates
              .where((o) => o.origin?.startsWith('counterpart:') ?? false)
              .toList();
          if (creates.length != counterpart.length) continue;
          final live = counterpart.where(
            (o) =>
                o.state == 'shadow' ||
                (o.state == 'acked' &&
                    (listedSeq == null || (o.ackSeq ?? 0) >= listedSeq)),
          );
          if (live.isNotEmpty) continue;
          // Created by sync for the counterpart, never by the user: with
          // no create left the row is dropped.
          if (creates.isEmpty && ops.isNotEmpty) continue;
          for (final o in counterpart) {
            await _deleteOp(o.id);
          }
          // Changes the user queued for it on this account fail, listed.
          final dependents = <PendingChangeRow>[];
          await _failDependentsOf(
            r,
            'the folder "${r.name}" was not found on the server',
            dependents,
          );
          logDependents(null, dependents);
          await (_db.delete(_db.mailboxes)..where((t) => t.id.equals(r.id)))
              .go();
          _log(
            (logger) => logger.warn(
              'mailbox.counterpart_folder_dropped',
              'Removed the folder "${r.name}" shown for another account\'s '
                  'move: ${counterpart.isEmpty ? 'that move ended' : 'the '
                      'server does not list it'}',
              accountId: accountId,
              mailboxPath: r.path,
              data: {'mailboxId': r.id},
            ),
          );
        }
        await rebuildDisplayPaths(accountId);
      });

  /// Queues a create of local [row] again (its earlier one failed or was
  /// lost), replacing the failed ones.
  Future<void> _queueCreate(
    MailboxRow row,
    String name,
    String? parentPath,
    String? role,
  ) async {
    await (_db.delete(_db.pendingChanges)
          ..where(
            (t) =>
                t.resourceType.equals(mailboxResourceType) &
                t.resourceId.equals(row.id) &
                t.changeType.equals(createMailboxOp) &
                t.state.equals('failed'),
          ))
        .go();
    await _insertOp(
      row.accountId,
      row.id,
      createMailboxOp,
      _createPayload(name, parentPath, role),
    );
  }

  /// Renames [row] to [newName] locally and queues the rename. A queued
  /// rename of it that was never sent (no attempt), and a failed one, is
  /// replaced (a rename writes the whole name); one that may have reached
  /// the server stays, so its outcome is still settled, and the new one
  /// follows it. Back to the server's name with nothing sent, no op is
  /// needed at all.
  Future<MailboxRow> enqueueRename(MailboxRow row, String newName) =>
      _db.transaction(() async {
        await (_db.delete(_db.pendingChanges)
              ..where(
                (t) =>
                    t.resourceType.equals(mailboxResourceType) &
                    t.resourceId.equals(row.id) &
                    t.changeType.equals(renameMailboxOp) &
                    (t.state.equals('failed') |
                        (t.state.equals('pending') & t.attempts.equals(0))),
              ))
            .go();
        var current = (await rowById(row.id))!;
        if (!current.isLocal &&
            current.srvName == null &&
            current.localName == null) {
          // A row stored without the server's name (before the overlay):
          // with no op folded, the name it shows is the server's.
          await (_db.update(_db.mailboxes)..where((t) => t.id.equals(row.id)))
              .write(MailboxesCompanion(srvName: Value(current.name)));
          current = (await rowById(row.id))!;
        }
        final live = (await _opsOf(row.id))
            .where((o) => foldableOpStates.contains(o.state))
            .toList();
        final backToServer = !current.isLocal &&
            current.srvName == newName &&
            !live.any((o) => o.changeType == renameMailboxOp);
        if (!backToServer) {
          await _insertOp(
            row.accountId,
            row.id,
            renameMailboxOp,
            jsonEncode({mailboxOpName: newName}),
          );
        }
        await _refoldRow(row.id);
        await rebuildDisplayPaths(row.accountId);
        return (await rowById(row.id))!;
      });

  /// The parent `path` the server has [row] below (null: top level): the
  /// JMAP `parentId`, or on IMAP the path up to its last [separator].
  static String? serverParentOf(
    MailboxRow row, {
    required bool jmap,
    required String separator,
  }) {
    if (jmap) return row.parentId;
    final cut = row.path.lastIndexOf(separator);
    return cut <= 0 ? null : row.path.substring(0, cut);
  }

  /// The parent `path` [row] shows below now (null: top level): its
  /// pending move's, else the server's ([serverParentOf]).
  Future<String?> shownParentOf(MailboxRow row) async {
    final local = row.localParent;
    if (local != null) return local.isEmpty ? null : local;
    return serverParentOf(
      row,
      jmap: await _isJmap(row.accountId),
      separator: await imapSeparator(row.accountId),
    );
  }

  /// Moves [row] below [parentPath] (the top level when null) locally and
  /// queues the move (`move_mailbox`, phase 5b): it shows there at once,
  /// with its subfolders. A queued move of it that was never sent, and a
  /// failed one, is replaced; one that may have reached the server stays
  /// and the new one follows it. Back below the server's parent with
  /// nothing sent, no op is needed. Returns the row and the id of the op
  /// queued (null when none was).
  Future<({MailboxRow row, int? op})> enqueueMove(
    MailboxRow row,
    String? parentPath,
  ) =>
      _db.transaction(() async {
        final from = await shownParentOf((await rowById(row.id))!);
        await (_db.delete(_db.pendingChanges)
              ..where(
                (t) =>
                    t.resourceType.equals(mailboxResourceType) &
                    t.resourceId.equals(row.id) &
                    t.changeType.equals(moveMailboxOp) &
                    (t.state.equals('failed') |
                        (t.state.equals('pending') & t.attempts.equals(0))),
              ))
            .go();
        final current = (await rowById(row.id))!;
        final live = (await _opsOf(row.id))
            .where((o) => foldableOpStates.contains(o.state))
            .toList();
        final server = serverParentOf(
          current,
          jmap: await _isJmap(row.accountId),
          separator: await imapSeparator(row.accountId),
        );
        final backToServer = !current.isLocal &&
            server == parentPath &&
            !live.any((o) => o.changeType == moveMailboxOp);
        int? op;
        if (!backToServer) {
          op = await _insertOp(
            row.accountId,
            row.id,
            moveMailboxOp,
            jsonEncode(
              {mailboxOpParent: parentPath, mailboxOpFromParent: from},
            ),
          );
        }
        await _refoldRow(row.id);
        await rebuildDisplayPaths(row.accountId);
        return (row: (await rowById(row.id))!, op: op);
      });

  /// Deletes [row] locally and queues the delete (`delete_mailbox`, phase
  /// 5b): the folder is hidden at once (`local_hidden`), everywhere. With
  /// [removeEmails] the server deletes the mail it has with it (the user
  /// confirmed); without, a folder that has mail on the server is refused
  /// and shows again. A queued delete of it stays (returned); a failed one
  /// is replaced. Returns the op's id.
  Future<int> enqueueDelete(
    MailboxRow row, {
    required bool removeEmails,
    int? confirmedMessages,
  }) =>
      _db.transaction(() async {
        final ops = await _opsOf(row.id);
        final live = ops
            .where(
              (o) =>
                  o.changeType == deleteMailboxOp &&
                  foldableOpStates.contains(o.state),
            )
            .firstOrNull;
        if (live != null) return live.id;
        await (_db.delete(_db.pendingChanges)
              ..where(
                (t) =>
                    t.resourceType.equals(mailboxResourceType) &
                    t.resourceId.equals(row.id) &
                    t.changeType.equals(deleteMailboxOp) &
                    t.state.equals('failed'),
              ))
            .go();
        final op = await _insertOp(
          row.accountId,
          row.id,
          deleteMailboxOp,
          jsonEncode({
            mailboxOpRemoveEmails: removeEmails,
            if (removeEmails && confirmedMessages != null)
              mailboxOpConfirmedMessages: confirmedMessages,
          }),
        );
        await _refoldRow(row.id);
        await rebuildDisplayPaths(row.accountId);
        return op;
      });

  /// Undo of the latest folder move or delete of [row] (phase 5b): one that
  /// was never sent (queued, no attempt) is cancelled, so the folder shows
  /// where, and as, the server has it; a move that may have reached the
  /// server is followed by a move back to the parent it showed below
  /// before ([enqueueMove]). A delete that may have reached the server
  /// cannot be undone (its mail may be gone): [MailboxUndo.tooLate].
  Future<MailboxUndo> undoLatest(MailboxRow row) async {
    final latest = (await _opsOf(row.id))
        .where(
          (o) =>
              (o.changeType == moveMailboxOp ||
                  o.changeType == deleteMailboxOp) &&
              o.state != 'failed',
        )
        .lastOrNull;
    if (latest == null) return MailboxUndo.nothing;
    final cancelled = await _db.transaction(() async {
      final count = await (_db.delete(_db.pendingChanges)
            ..where(
              (t) =>
                  t.id.equals(latest.id) &
                  t.state.equals('pending') &
                  t.attempts.equals(0),
            ))
          .go();
      if (count == 0) return false;
      await _refoldRow(row.id);
      await rebuildDisplayPaths(row.accountId);
      return true;
    });
    if (cancelled) return MailboxUndo.cancelled;
    if (latest.changeType == deleteMailboxOp) {
      final now = await (_db.select(_db.pendingChanges)
            ..where((t) => t.id.equals(latest.id)))
          .getSingleOrNull();
      return now?.state == 'inflight' && now!.attempts == 0
          ? MailboxUndo.sending
          : MailboxUndo.tooLate;
    }
    await enqueueMove(
      (await rowById(row.id))!,
      _payloadOf(latest)?[mailboxOpFromParent] as String?,
    );
    return MailboxUndo.reversed;
  }

  static String _createPayload(String name, String? parent, String? role) =>
      jsonEncode({
        mailboxOpName: name,
        if (parent != null) mailboxOpParent: parent,
        if (role != null) mailboxOpRole: role,
      });

  Future<int> _insertOp(
    String accountId,
    String mailboxId,
    String type,
    String payload,
  ) =>
      _db.into(_db.pendingChanges).insert(
            PendingChangesCompanion.insert(
              accountId: accountId,
              resourceType: mailboxResourceType,
              resourceId: mailboxId,
              changeType: type,
              payload: payload,
              createdAt: _now(),
            ),
          );

  Future<Set<String>> _shownIds(String accountId) async => {
        for (final r in await _db.customSelect(
          'SELECT m.id FROM mailboxes m WHERE m.account_id = ?1 '
          'AND ${mailboxShownSql('m')}',
          variables: [Variable.withString(accountId)],
        ).get())
          r.read<String>('id'),
      };

  // ── The fold ───────────────────────────────────────────────────────────

  /// Recomputes `local_name` (and the effective `name`), `local_parent`
  /// and `local_hidden` of mailbox [mailboxId] from its foldable ops, then
  /// the account's display paths.
  Future<void> refold(String mailboxId) => _db.transaction(() async {
        final row = await _refoldRow(mailboxId);
        if (row != null) await rebuildDisplayPaths(row.accountId);
      });

  Future<MailboxRow?> _refoldRow(String mailboxId) async {
    final ops = (await _opsOf(mailboxId)).map(_foldOpOf).toList();
    final local = foldMailboxName(ops);
    await _db.customUpdate(
      'UPDATE mailboxes SET local_name = ?1, '
      'name = COALESCE(?1, srv_name, name), local_parent = ?2, '
      'local_hidden = ?3 WHERE id = ?4',
      variables: [
        Variable<String>(local),
        Variable<String>(foldMailboxParent(ops)),
        Variable.withBool(foldMailboxHidden(ops)),
        Variable.withString(mailboxId),
      ],
      updates: {_db.mailboxes},
      updateKind: UpdateKind.update,
    );
    return rowById(mailboxId);
  }

  /// Rewrites the `display_path` of [accountId]'s mailboxes whose derived
  /// value ([displayPaths]) changed.
  Future<void> rebuildDisplayPaths(String accountId) async {
    final rows = await _rowsOf(accountId);
    final jmap = await _isJmap(accountId);
    final derived = displayPaths(
      [
        for (final r in rows)
          DisplayPathRow(
            path: r.path,
            name: r.name,
            localName: r.localName,
            srvName: r.srvName,
            parentId: effectiveMailboxParent(
              parentId: r.parentId,
              localParent: r.localParent,
            ),
            localParent: jmap ? null : r.localParent,
          ),
      ],
      jmap: jmap,
      separator: await imapSeparator(accountId),
    );
    for (final r in rows) {
      final display = derived[r.path];
      if (display == null || display == r.displayPath) continue;
      await (_db.update(_db.mailboxes)..where((t) => t.id.equals(r.id)))
          .write(MailboxesCompanion(displayPath: Value(display)));
    }
  }

  // ── The server-write gate ──────────────────────────────────────────────

  /// Stores what a mailbox listing that started at read sequence [readSeq]
  /// says about the mailbox at [path]: its [name] (when no later read or
  /// ack wrote it: `srv_seq`), [role], [parentId] (JMAP) and its counts
  /// (read at [unreadSeq]). The mailbox exists on the server, so a row
  /// created offline at that path has its server copy now. Settles the
  /// row's acked ops against the name (SYNC-REDESIGN.md §4.5): dropped
  /// when it agrees; on a contradiction the first read is recorded and a
  /// later one drops it (App Log `op.contradicted`). A new row gets
  /// [displayPath]; the caller rebuilds the display paths after the
  /// listing ([rebuildDisplayPaths]).
  Future<void> writeServer({
    required String accountId,
    required String path,
    required String name,
    required String? role,
    required String? parentId,
    required int unreadCount,
    required int totalCount,
    required int unreadSeq,
    required int readSeq,
    String? displayPath,
  }) =>
      _db.transaction(() async {
        final row = await rowByPath(accountId, path) ??
            (await _adoptCounterpartFolder(accountId, path, name, parentId)
                ? await rowByPath(accountId, path)
                : null);
        if (row == null) {
          await _db.into(_db.mailboxes).insert(
                MailboxesCompanion.insert(
                  id: await _freeId(accountId, path),
                  accountId: accountId,
                  path: path,
                  name: name,
                  srvName: Value(name),
                  srvSeq: Value(readSeq),
                  unreadCount: Value(unreadCount),
                  unreadSeq: Value(unreadSeq),
                  totalCount: Value(totalCount),
                  role: Value(role),
                  displayPath: Value(displayPath ?? path),
                  parentId: Value(parentId),
                ),
              );
          return;
        }
        await (_db.update(_db.mailboxes)..where((t) => t.id.equals(row.id)))
            .write(
          MailboxesCompanion(
            unreadCount: Value(unreadCount),
            unreadSeq: Value(unreadSeq),
            totalCount: Value(totalCount),
            role: Value(role),
          ),
        );
        // The name and the parent: only when no later read or ack wrote
        // them (a stale listing must not put a confirmed rename or move
        // back).
        if (readSeq < row.srvSeq) return;
        if (row.isLocal && await _hasUnsentCreate(row.id)) {
          // Created offline and never sent: the server's folder at this
          // path is someone else's. The create's flush reports the clash
          // (a visible failed change) instead of the listing adopting it.
          return;
        }
        await _db.customUpdate(
          'UPDATE mailboxes SET srv_name = ?1, srv_seq = ?2, is_local = 0, '
          'name = COALESCE(local_name, ?1), parent_id = ?4 WHERE id = ?3',
          variables: [
            Variable.withString(name),
            Variable.withInt(readSeq),
            Variable.withString(row.id),
            Variable<String>(parentId),
          ],
          updates: {_db.mailboxes},
          updateKind: UpdateKind.update,
        );
        // A counterpart's stand-in for this folder is the server's now.
        await _dropShadowCreates(row.id);
        final jmap = await _isJmap(accountId);
        await _settleAcked(
          row.id,
          name,
          readSeq,
          srvParent: jmap
              ? parentId
              : serverParentOf(
                  row,
                  jmap: false,
                  separator: await imapSeparator(accountId),
                ),
        );
      });

  /// Whether mailbox [mailboxId] has a create that is queued and was never
  /// sent (no attempt).
  Future<bool> _hasUnsentCreate(String mailboxId) async => (await _opsOf(
        mailboxId,
      ))
          .any(
        (o) =>
            o.changeType == createMailboxOp &&
            o.attempts == 0 &&
            const ['pending', 'stuck', 'inflight'].contains(o.state),
      );

  /// After a folder listing started at [readSeq]: drops the acked ops of
  /// [accountId] whose ack already rested on a read of the server (a create
  /// that found the folder there, `readConfirmed`). A JMAP `Mailbox/changes`
  /// does not name a folder that did not change, so nothing else would.
  Future<void> settleReadConfirmed(String accountId, int readSeq) =>
      _db.transaction(() async {
        final ops = await (_db.select(_db.pendingChanges)
              ..where(
                (t) =>
                    t.accountId.equals(accountId) &
                    t.resourceType.equals(mailboxResourceType) &
                    t.state.equals('acked') &
                    t.ackSeq.isSmallerThanValue(readSeq),
              ))
            .get();
        for (final op in ops) {
          if (_payloadOf(op)?[_readConfirmedKey] != true) continue;
          await _deleteOp(op.id);
          await _refoldRow(op.resourceId);
        }
      });

  /// After a folder listing started at [readSeq]: drops [accountId]'s acked
  /// deletes acked before it (the listing no longer had to be kept from
  /// bringing the folder back, [renamedAwaySince]; a folder it lists anyway
  /// is a new one another client made).
  Future<void> settleAckedDeletes(String accountId, int readSeq) =>
      _db.customUpdate(
        'DELETE FROM pending_changes WHERE account_id = ?1 '
        "AND resource_type = '$mailboxResourceType' "
        "AND change_type = '$deleteMailboxOp' AND state = 'acked' "
        'AND ack_seq < ?2',
        variables: [Variable.withString(accountId), Variable.withInt(readSeq)],
        updates: {_db.pendingChanges},
        updateKind: UpdateKind.delete,
      );

  /// IMAP renames and moves a listing proves done although their answer
  /// was lost: a queued rename or move that may have been sent (attempts)
  /// of a folder the listing [listedPaths] no longer has, while it has the
  /// path the op gives. It is acked as if answered (path, subfolders and
  /// mail follow, [serverPathChanged]). Returns the paths moved, old → new.
  Future<Map<String, String>> completeLostRenames(
    String accountId,
    Set<String> listedPaths,
  ) async {
    final moved = <String, String>{};
    final separator = await imapSeparator(accountId);
    for (final row in await _rowsOf(accountId)) {
      if (row.isLocal || listedPaths.contains(row.path)) continue;
      final ops = await _opsOf(row.id);
      final lost = ops
          .where(
            (o) =>
                (o.changeType == renameMailboxOp ||
                    o.changeType == moveMailboxOp) &&
                o.attempts > 0 &&
                const ['pending', 'stuck'].contains(o.state),
          )
          .firstOrNull;
      if (lost == null) continue;
      final cut = row.path.lastIndexOf(separator);
      final String target;
      final String name;
      if (lost.changeType == moveMailboxOp) {
        name = cut < 0 ? row.path : row.path.substring(cut + separator.length);
        final parent = _payloadOf(lost)?[mailboxOpParent] as String?;
        target = parent == null ? name : '$parent$separator$name';
      } else {
        final renamed = _payloadOf(lost)?[mailboxOpName];
        if (renamed is! String) continue;
        name = renamed;
        target =
            cut < 0 ? name : '${row.path.substring(0, cut)}$separator$name';
      }
      if (!listedPaths.contains(target)) continue;
      final done = await _db.transaction(() async {
        final count = await (_db.update(_db.pendingChanges)
              ..where(
                (t) =>
                    t.id.equals(lost.id) &
                    t.state.isIn(const ['pending', 'stuck']),
              ))
            .write(const PendingChangesCompanion(state: Value('inflight')));
        if (count == 0) return false;
        final claimed = (await (_db.select(_db.pendingChanges)
              ..where((t) => t.id.equals(lost.id)))
            .getSingle());
        return ack(claimed, serverPath: target, serverName: name);
      });
      if (!done) continue;
      moved[row.path] = target;
      _log(
        (logger) => logger.warn(
          'mailbox.rename_found_done',
          'The ${_describe(lost)} of "${row.path}" to "$target" reached the '
              'server although its answer was lost; the folder and its mail '
              'follow',
          accountId: accountId,
          mailboxPath: target,
          data: {
            'from': row.path,
            'to': target,
            'changeId': lost.id,
            'changeType': lost.changeType,
          },
        ),
      );
    }
    return moved;
  }

  /// Settles the acked ops of mailbox [mailboxId] against [srvName], read
  /// at [readSeq].
  Future<void> _settleAcked(
    String mailboxId,
    String srvName,
    int readSeq, {
    required String? srvParent,
  }) async {
    final acked = (await _opsOf(mailboxId)).where(
      (o) =>
          o.state == 'acked' &&
          (o.ackSeq ?? 0) < readSeq &&
          // An acked delete is settled by the listing as a whole
          // ([settleAckedDeletes]).
          o.changeType != deleteMailboxOp,
    );
    var changed = false;
    for (final op in acked) {
      if (mailboxReadAgrees(_foldOpOf(op), srvName, srvParent: srvParent)) {
        await _deleteOp(op.id);
        changed = true;
        continue;
      }
      final first = op.contradictedSeq;
      if (first == null) {
        await (_db.update(_db.pendingChanges)..where((t) => t.id.equals(op.id)))
            .write(PendingChangesCompanion(contradictedSeq: Value(readSeq)));
        continue;
      }
      if (readSeq <= first) continue;
      await _deleteOp(op.id);
      changed = true;
      final row = await rowById(mailboxId);
      _log(
        (logger) => logger.warn(
          'op.contradicted',
          op.changeType == moveMailboxOp
              ? 'The server has the folder "$srvName" below '
                  '"${srvParent ?? '(top level)'}" after a confirmed '
                  '${_describe(op)}; showing it where the server has it'
              : 'The server calls the folder "$srvName" after a confirmed '
                  '${_describe(op)}; showing the server\'s name',
          accountId: op.accountId,
          mailboxPath: row?.path,
          data: {
            'changeId': op.id,
            'changeType': op.changeType,
            'name': _payloadOf(op)?[mailboxOpName],
            if (op.changeType == moveMailboxOp)
              'parent': _payloadOf(op)?[mailboxOpParent],
            'serverName': srvName,
            if (op.changeType == moveMailboxOp) 'serverParent': srvParent,
          },
        ),
      );
    }
    if (changed) await _refoldRow(mailboxId);
  }

  /// The cached mailboxes of [accountId] that a listing which started at
  /// [readSeq] and returned [keepPaths] says are gone: not listed, not
  /// created offline (no server copy to be gone), not written by a later
  /// read or ack (a folder just created or renamed, §4.3), and not renamed
  /// by a queued rename that may have reached the server (being sent, or
  /// sent before without an answer): the listing may show its new path
  /// ([completeLostRenames]) or a later one will.
  Future<List<MailboxRow>> prunable(
    String accountId,
    Set<String> keepPaths,
    int readSeq,
  ) async {
    final out = <MailboxRow>[];
    final rows = await _rowsOf(accountId);
    final jmap = await _isJmap(accountId);
    final separator = await imapSeparator(accountId);
    // On IMAP a rename or move takes the subfolders along: they are not
    // gone either while it may have reached the server.
    final moving = <String>[];
    for (final r in rows) {
      final maybeMoved = (await _opsOf(r.id)).any(
        (o) =>
            (o.changeType == renameMailboxOp ||
                o.changeType == moveMailboxOp) &&
            (o.state == 'inflight' ||
                (o.attempts > 0 &&
                    const ['pending', 'stuck'].contains(o.state))),
      );
      if (maybeMoved) moving.add(r.path);
    }
    for (final r in rows) {
      if (keepPaths.contains(r.path) || r.isLocal || r.srvSeq > readSeq) {
        continue;
      }
      if (moving.contains(r.path)) continue;
      if (!jmap && moving.any((p) => r.path.startsWith('$p$separator'))) {
        continue;
      }
      // A delete being sent: its flush settles it. A queued one the
      // listing proves done is settled by the removal
      // ([failOpsOfRemoved]).
      final deleting = (await _opsOf(r.id)).any(
        (o) => o.changeType == deleteMailboxOp && o.state == 'inflight',
      );
      if (deleting) continue;
      out.add(r);
    }
    return out;
  }

  /// Server paths an acked IMAP rename moved a folder away from after
  /// [readSeq] (also through earlier renames of a chain, carried forward):
  /// a listing that started before it may still list them, or their
  /// subfolders, and must not bring the old folders back
  /// ([isRenamedAway]).
  Future<Set<String>> renamedAwaySince(String accountId, int readSeq) async => {
        for (final op in await (_db.select(_db.pendingChanges)
              ..where(
                (t) =>
                    t.accountId.equals(accountId) &
                    t.resourceType.equals(mailboxResourceType) &
                    t.state.equals('acked') &
                    t.ackSeq.isBiggerThanValue(readSeq),
              ))
            .get())
          ..._fromPathsOf(op),
      };

  /// Whether [path] is one of [renamedAway] or a subfolder of one (with
  /// the account's [separator]).
  static bool isRenamedAway(
    String path,
    Set<String> renamedAway,
    String separator,
  ) =>
      renamedAway
          .any((from) => path == from || path.startsWith('$from$separator'));

  static List<String> _fromPathsOf(PendingChangeRow op) =>
      switch (_payloadOf(op)?[mailboxOpFromPath]) {
        final String from => [from],
        final List<dynamic> from => from.whereType<String>().toList(),
        _ => const <String>[],
      };

  // ── Flush outcomes ─────────────────────────────────────────────────────

  /// Settles [claimed], a mailbox op the server applied (or found already
  /// done): `acked` with `ack_seq` = the next read sequence, and what the
  /// server confirmed recorded at once, stamped with it: the mailbox
  /// exists at [serverPath] under [serverName]. A path other than the
  /// row's (a JMAP create's new id, an IMAP create whose separator was
  /// guessed wrong, an IMAP rename) moves everything naming the old one
  /// ([serverPathChanged]). The op keeps folding until a mailbox listing
  /// started after the ack settles it ([writeServer]); with [readConfirmed]
  /// (the flush found the folder in a read of the server: a create of a
  /// folder that exists) the next listing drops it whatever it lists
  /// ([settleReadConfirmed]). A create keeps the stand-in path it had in
  /// `localPath`, so a change queued from a screen that still names it is
  /// pointed at the server's ([resolveStandIn]); a rename keeps the paths
  /// the folder had (`fromPath`, also those of older acked renames it
  /// replaces), so a stale listing does not bring them back. Returns false
  /// when the flush no longer owned the claim.
  Future<bool> ack(
    PendingChangeRow claimed, {
    required String serverPath,
    required String serverName,
    bool readConfirmed = false,
    bool jmapParentConfirmed = false,
    String? serverParent,
  }) async {
    var released = 0;
    final ok = await _db.transaction(() async {
      final ackSeq = await _emails.nextReadSeq();
      final row = await rowById(claimed.resourceId);
      final payload = _payloadOf(claimed) ?? {};
      if (readConfirmed) payload[_readConfirmedKey] = true;
      if (row != null && row.path != serverPath) {
        if (claimed.changeType == createMailboxOp) {
          payload[_localPathKey] = row.path;
        }
        if (claimed.changeType == renameMailboxOp ||
            claimed.changeType == moveMailboxOp) {
          final older = await (_db.select(_db.pendingChanges)
                ..where(
                  (t) =>
                      t.resourceType.equals(mailboxResourceType) &
                      t.resourceId.equals(row.id) &
                      t.state.equals('acked') &
                      t.id.isSmallerThanValue(claimed.id),
                ))
              .get();
          payload[mailboxOpFromPath] = {
            for (final o in older) ..._fromPathsOf(o),
            row.path,
          }.toList();
        }
      }
      final count = await (_db.update(_db.pendingChanges)
            ..where((t) => _ownsClaim(t, claimed)))
          .write(
        PendingChangesCompanion(
          state: const Value('acked'),
          ackSeq: Value(ackSeq),
          contradictedSeq: const Value(null),
          leaseUntil: const Value(null),
          claimToken: const Value(null),
          lastError: const Value(null),
          payload: Value(jsonEncode(payload)),
        ),
      );
      if (count == 0) return false;
      if (row == null) {
        await _deleteOp(claimed.id);
        return true;
      }
      var mailboxId = row.id;
      if (row.path != serverPath) {
        released +=
            await serverPathChanged(row.accountId, row.path, serverPath);
        // A merge into a cached row of that path re-keyed the op.
        mailboxId = (await (_db.select(_db.pendingChanges)
                      ..where((t) => t.id.equals(claimed.id)))
                    .getSingleOrNull())
                ?.resourceId ??
            mailboxId;
      }
      await _db.customUpdate(
        'UPDATE mailboxes SET is_local = 0, srv_name = ?1, '
        'srv_seq = MAX(srv_seq, ?2), name = COALESCE(local_name, ?1) '
        'WHERE id = ?3',
        variables: [
          Variable.withString(serverName),
          Variable.withInt(ackSeq),
          Variable.withString(mailboxId),
        ],
        updates: {_db.mailboxes},
        updateKind: UpdateKind.update,
      );
      if (jmapParentConfirmed) {
        // A JMAP move: the server put the folder below [serverParent].
        await (_db.update(_db.mailboxes)..where((t) => t.id.equals(mailboxId)))
            .write(MailboxesCompanion(parentId: Value(serverParent)));
      }
      // Older acked ops of the mailbox no longer show anywhere: this one
      // names the whole folder.
      await _db.customUpdate(
        "DELETE FROM pending_changes WHERE resource_type = '$mailboxResourceType' "
        "AND resource_id = ?1 AND state = 'acked' AND id < ?2",
        variables: [
          Variable.withString(mailboxId),
          Variable.withInt(claimed.id),
        ],
        updates: {_db.pendingChanges},
        updateKind: UpdateKind.delete,
      );
      await _refoldRow(mailboxId);
      final current = await rowById(mailboxId);
      if (current != null) await rebuildDisplayPaths(current.accountId);
      return true;
    });
    if (released > 0) {
      _log(
        (logger) => logger.warn(
          'mailbox.rename.server_location_released',
          'Moving the folder to "$serverPath": $released cached message(s) '
              'still recorded a place in "$serverPath" on the server, which '
              'no longer holds them; sync no longer updates those copies.',
          accountId: claimed.accountId,
          mailboxPath: serverPath,
        ),
      );
    }
    return ok;
  }

  /// Settles [claimed], a `delete_mailbox` the server applied (or found
  /// done: the folder was gone already): `acked` with `ack_seq` and the
  /// folder's path as `fromPath`, so a listing that started before the ack
  /// does not bring the folder back ([renamedAwaySince]); the next listing
  /// drops it ([settleAckedDeletes]). The caller then removes the folder's
  /// cache (`removeLocalMailbox`, which keeps this op). With [claimed] not
  /// being sent (a queued delete a listing proves done), [owned] is false.
  /// Returns the folder's path, or null when the flush no longer owned the
  /// claim.
  Future<String?> ackDelete(PendingChangeRow claimed, {bool owned = true}) =>
      _db.transaction(() async {
        final ackSeq = await _emails.nextReadSeq();
        final row = await rowById(claimed.resourceId);
        final payload = _payloadOf(claimed) ?? {};
        if (row != null) payload[mailboxOpFromPath] = [row.path];
        final count = await (_db.update(_db.pendingChanges)
              ..where(
                (t) => owned
                    ? _ownsClaim(t, claimed)
                    : t.id.equals(claimed.id) &
                        t.state.isIn(const ['pending', 'stuck']),
              ))
            .write(
          PendingChangesCompanion(
            state: const Value('acked'),
            ackSeq: Value(ackSeq),
            contradictedSeq: const Value(null),
            leaseUntil: const Value(null),
            claimToken: const Value(null),
            lastError: const Value(null),
            payload: Value(jsonEncode(payload)),
          ),
        );
        if (count == 0) return null;
        if (row == null) {
          await _deleteOp(claimed.id);
          return null;
        }
        return row.path;
      });

  /// Marks [op] `failed` with [error]: the server refused it, or (with
  /// [claimed] false) the folder is gone. A failed op stops folding: a
  /// rename shows the server's name again, a folder created offline is
  /// hidden. The changes that depend on a failed create fail with it
  /// (SYNC-REDESIGN.md §5): mail moved into the folder goes back where the
  /// server has it, subfolders created in it and renames of it fail, each
  /// naming the cause. Returns those dependents (empty when there are
  /// none), or null when the flush no longer owned the claim; log them
  /// with [logDependents] after the transaction.
  Future<List<PendingChangeRow>?> fail(
    PendingChangeRow op,
    String error, {
    bool claimed = true,
  }) =>
      _db.transaction(() async {
        final count = await (_db.update(_db.pendingChanges)
              ..where(
                (t) => claimed
                    ? _ownsClaim(t, op)
                    : t.id.equals(op.id) &
                        t.state.isIn(const ['pending', 'stuck']),
              ))
            .write(
          PendingChangesCompanion(
            attempts: Value(op.attempts + (claimed ? 1 : 0)),
            lastError: Value(error),
            state: const Value('failed'),
            leaseUntil: const Value(null),
            claimToken: const Value(null),
          ),
        );
        if (count == 0) return null;
        final dependents = <PendingChangeRow>[];
        if (op.changeType == createMailboxOp) {
          final row = await rowById(op.resourceId);
          if (row != null && row.isLocal) {
            final name = _payloadOf(op)?[mailboxOpName] ?? row.name;
            await _failDependentsOf(
              row,
              'the folder "$name" could not be created: $error',
              dependents,
            );
          }
        }
        final row = await _refoldRow(op.resourceId);
        if (row != null) await rebuildDisplayPaths(row.accountId);
        return dependents;
      });

  /// Fails every queued change that needs local mailbox [row] to exist on
  /// the server, with [cause]; collects them in [into].
  Future<void> _failDependentsOf(
    MailboxRow row,
    String cause,
    List<PendingChangeRow> into,
  ) async {
    const waiting = ['pending', 'stuck', 'parked'];
    final ops = await (_db.select(_db.pendingChanges)
          ..where(
            (t) => t.accountId.equals(row.accountId) & t.state.isIn(waiting),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();
    final emailRows = <String>{};
    final childRows = <String>{};
    for (final op in ops) {
      final payload = _payloadOf(op);
      final bool depends;
      if (op.resourceType == mailboxResourceType) {
        // Its own ops, creates of subfolders in it, and moves of other
        // folders into it.
        depends = op.resourceId == row.id ||
            ((op.changeType == createMailboxOp ||
                    op.changeType == moveMailboxOp) &&
                payload?[mailboxOpParent] == row.path);
        if (depends && op.resourceId != row.id) childRows.add(op.resourceId);
      } else {
        depends = emailOpFolderKeys.any((k) => payload?[k] == row.path);
        if (depends) emailRows.add(op.resourceId);
      }
      if (!depends) continue;
      await (_db.update(_db.pendingChanges)
            ..where((t) => t.id.equals(op.id) & t.state.isIn(waiting)))
          .write(
        PendingChangesCompanion(
          state: const Value('failed'),
          lastError: Value(cause),
          leaseUntil: const Value(null),
          // Retry of the folder's create queues it again too.
          payload: Value(
            jsonEncode({...?payload, _failedWithFolderKey: row.id}),
          ),
        ),
      );
      into.add(op.copyWith(state: 'failed', lastError: Value(cause)));
    }
    // Their mails show where the server has them again.
    for (final id in emailRows) {
      final refold = await _emails.refoldRow(id);
      if (refold != null) await _rethread(id, refold);
    }
    // Their counterpart shadows go with them.
    for (final MapEntry(key: id, value: refold)
        in (await _emails.dropOrphanedShadows()).entries) {
      await _rethread(id, refold);
    }
    for (final id in childRows) {
      final child = await _refoldRow(id);
      if (child == null || !child.isLocal) continue;
      await _failDependentsOf(
        child,
        'its parent folder could not be created: $cause',
        into,
      );
    }
  }

  /// Refreshes the threads of email row [emailId] in the folders it showed
  /// in before and after [refold].
  Future<void> _rethread(String emailId, Refold refold) async {
    if (!refold.changed) return;
    final email = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(emailId)))
        .getSingleOrNull();
    if (email == null) return;
    for (final path in {refold.before, refold.after}) {
      await refreshThreadAggregate(
        _db,
        email.accountId,
        path,
        email.threadId ?? email.id,
      );
    }
  }

  /// Fails mail change [op], which names [path], a stand-in of a folder
  /// created offline that no folder has (its create was discarded, or the
  /// row is gone): sent, it would name a mailbox the server never gave.
  /// The mail shows where the server has it again; logged like a change
  /// that failed with its folder's create.
  Future<void> failStandIn(PendingChangeRow op, String path) async {
    final cause = 'the folder it names was never created ($path)';
    final done = await _db.transaction(() async {
      final count = await (_db.update(_db.pendingChanges)
            ..where(
              (t) =>
                  t.id.equals(op.id) &
                  t.state.isIn(const ['pending', 'stuck', 'parked']),
            ))
          .write(
        PendingChangesCompanion(
          state: const Value('failed'),
          lastError: Value(cause),
          leaseUntil: const Value(null),
        ),
      );
      if (count == 0) return false;
      final refold = await _emails.refoldRow(op.resourceId);
      if (refold != null) await _rethread(op.resourceId, refold);
      return true;
    });
    if (!done) return;
    logDependents(null, [
      op.copyWith(state: 'failed', lastError: Value(cause)),
    ]);
  }

  /// Logs each change in [dependents] that failed because the folder it
  /// needs was not created ([cause], the create's op when there is one):
  /// App Log warn `pending_change.folder_not_created`.
  void logDependents(
    PendingChangeRow? cause,
    List<PendingChangeRow> dependents,
  ) {
    for (final d in dependents) {
      _log(
        (logger) => logger.warn(
          'pending_change.folder_not_created',
          'Gave up on a queued ${_describe(d)}: it needs a folder that was '
              'not created on the server; kept on the Pending Changes screen',
          accountId: d.accountId,
          emailId: d.resourceType == mailboxResourceType ? null : d.resourceId,
          data: {
            'changeId': d.id,
            'changeType': d.changeType,
            if (cause != null) 'causeChangeId': cause.id,
            'error': d.lastError,
          },
        ),
      );
    }
  }

  /// The user discards mailbox op [op] (not one being sent). A discarded
  /// create of a folder that has no server copy removes the folder, and
  /// the changes waiting for it fail; a discarded rename shows the server's
  /// name again. Returns the dependents failed, to log with
  /// [logDependents].
  Future<List<PendingChangeRow>> discard(PendingChangeRow op) =>
      _db.transaction(() async {
        final dependents = <PendingChangeRow>[];
        final current = await (_db.select(_db.pendingChanges)
              ..where((t) => t.id.equals(op.id)))
            .getSingleOrNull();
        if (current == null || current.state == 'inflight') return dependents;
        await _deleteOp(op.id);
        final row = await rowById(op.resourceId);
        if (row == null) return dependents;
        if (op.changeType == createMailboxOp && row.isLocal) {
          if (current.attempts > 0 && current.state != 'failed') {
            // It may have reached the server: the next listing would show
            // the folder again, as the server's.
            _log(
              (logger) => logger.warn(
                'mailbox.create_discarded_maybe_sent',
                'Discarded the creation of "${row.name}", which may already '
                    'have reached the server; if it did, the folder shows '
                    'again after the next sync',
                accountId: row.accountId,
                data: {'changeId': op.id, 'attempts': current.attempts},
              ),
            );
          }
          if (current.state != 'failed') {
            await _failDependentsOf(
              row,
              'creating the folder "${row.name}" was discarded',
              dependents,
            );
          }
          await (_db.delete(_db.mailboxes)..where((t) => t.id.equals(row.id)))
              .go();
          await rebuildDisplayPaths(row.accountId);
          return dependents;
        }
        await _refoldRow(row.id);
        await rebuildDisplayPaths(row.accountId);
        return dependents;
      });

  /// Retries failed mailbox op [op]: queued again at the end of the queue
  /// (a new `seq`), folding again. A retried create also returns the ids of
  /// the failed mail changes that failed with it (to be retried by the
  /// caller, which owns the mail side of Retry); the failed creates and
  /// renames of its subfolders and of itself are retried here. Nothing,
  /// with an App Log line, when its folder is gone.
  Future<List<int>> retry(PendingChangeRow op) async {
    final emailOps = <int>[];
    var gone = false;
    await _db.transaction(() async {
      final current = await (_db.select(_db.pendingChanges)
            ..where((t) => t.id.equals(op.id) & t.state.equals('failed')))
          .getSingleOrNull();
      if (current == null) return;
      final row = await rowById(op.resourceId);
      if (row == null) {
        gone = true;
        return;
      }
      await _insertOp(
        current.accountId,
        current.resourceId,
        current.changeType,
        current.changeType == deleteMailboxOp
            // A retried delete does not carry the old yes to deleting the
            // folder's mail (it may have more now): the server refuses a
            // folder with mail, and deleting it again asks again.
            ? jsonEncode({mailboxOpRemoveEmails: false})
            : _withoutRetryMarks(current.payload),
      );
      await _deleteOp(current.id);
      await _refoldRow(row.id);
      if (current.changeType == createMailboxOp) {
        for (final d in await (_db.select(_db.pendingChanges)
              ..where(
                (t) =>
                    t.accountId.equals(row.accountId) &
                    t.state.equals('failed'),
              )
              ..orderBy([(t) => OrderingTerm.asc(t.id)]))
            .get()) {
          if (_payloadOf(d)?[_failedWithFolderKey] != row.id) continue;
          if (d.resourceType != mailboxResourceType) {
            emailOps.add(d.id);
            continue;
          }
          emailOps.addAll(await retry(d));
        }
      }
      await rebuildDisplayPaths(row.accountId);
    });
    if (gone) {
      _log(
        (logger) => logger.warn(
          'pending_change.retry_folder_gone',
          'Could not retry the ${_describe(op)}: its folder is gone; it '
              'stays on the Pending Changes screen for Discard',
          accountId: op.accountId,
          data: {'changeId': op.id, 'mailboxId': op.resourceId},
        ),
      );
    }
    return emailOps;
  }

  /// [payload] without the marks a failure left (`failedWithFolder`).
  static String _withoutRetryMarks(String payload) {
    try {
      final map = jsonDecode(payload);
      if (map is! Map<String, dynamic>) return payload;
      if (map.remove(_failedWithFolderKey) == null) return payload;
      return jsonEncode(map);
    } catch (_) {
      return payload;
    }
  }

  /// The changes of [accountId] that wait for a folder created offline
  /// whose create no longer folds (it failed, or was lost): they would
  /// wait forever, so they fail now, naming the folder. One entry per such
  /// folder that had any: its failed create (null when there is none) and
  /// the changes failed, to log with [logDependents].
  Future<List<({PendingChangeRow? cause, List<PendingChangeRow> dependents})>>
      failOrphanedWaiting(String accountId) => _db.transaction(() async {
            final out = <({
              PendingChangeRow? cause,
              List<PendingChangeRow> dependents,
            })>[];
            for (final row in await _rowsOf(accountId)) {
              if (!row.isLocal) continue;
              final ops = await _opsOf(row.id);
              if (localMailboxShown(ops.map(_foldOpOf))) continue;
              final dependents = <PendingChangeRow>[];
              await _failDependentsOf(
                row,
                'the folder "${row.name}" was not created on the server',
                dependents,
              );
              if (dependents.isEmpty) continue;
              final cause =
                  ops.where((o) => o.changeType == createMailboxOp).lastOrNull;
              out.add((cause: cause, dependents: dependents));
            }
            return out;
          });

  /// Mailbox ops of [accountId]'s mailbox at [path] that can no longer
  /// apply: the folder was removed on the server. They become `failed`
  /// (listed, never dropped), and so do their dependents. Returns them all.
  Future<List<PendingChangeRow>> failOpsOfRemoved(
    String accountId,
    String path, [
    String why = 'folder removed on the server',
  ]) async {
    final row = await rowByPath(accountId, path);
    final failed = <PendingChangeRow>[];
    // The folder's own ops, and creates of subfolders below it and moves
    // of folders into it (on IMAP a CREATE or RENAME of one would bring the
    // removed folder back).
    final ops = [
      if (row != null) ...await _opsOf(row.id),
      for (final o in await (_db.select(_db.pendingChanges)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.resourceType.equals(mailboxResourceType) &
                  t.changeType.isIn(const [createMailboxOp, moveMailboxOp]),
            ))
          .get())
        if (_payloadOf(o)?[mailboxOpParent] == path) o,
    ];
    for (final op in ops) {
      if (!const ['pending', 'stuck'].contains(op.state)) continue;
      if (failed.any((f) => f.id == op.id)) continue;
      if (op.changeType == deleteMailboxOp && op.resourceId == row?.id) {
        // The folder is gone, as its queued delete wanted: done, not
        // failed (§5 "satisfied").
        if (await ackDelete(op, owned: false) == null) continue;
        _log(
          (logger) => logger.warn(
            'mailbox.delete_found_done',
            'The folder "$path" is gone on the server: its queued delete '
                'counts as done',
            accountId: accountId,
            mailboxPath: path,
            data: {'changeId': op.id, 'attempts': op.attempts},
          ),
        );
        continue;
      }
      final dependents = await fail(op, why, claimed: false);
      if (dependents == null) continue;
      failed
        ..add(op)
        ..addAll(dependents);
    }
    return failed;
  }

  /// Folder [from] of [accountId] is at [to] on the server now: an acked
  /// IMAP rename (with every subfolder, whose paths start with it), the
  /// JMAP id a create got, or an IMAP create whose separator was guessed
  /// wrong. A server fact: the rows keep their ids, and their `path`, the
  /// JMAP parents naming it, the queued mailbox ops naming it as parent,
  /// the threads and the sync checkpoints follow; on the email side the
  /// server folder of its mail and the queued changes naming it follow
  /// ([EmailStateWriter.renameFolder], which re-folds them). A row already
  /// cached at [to] (the server's folder was listed before the create was
  /// confirmed) takes over: the local row is merged into it. Returns how
  /// many mails gave up a stale server location.
  Future<int> serverPathChanged(String accountId, String from, String to) =>
      _db.transaction(() async {
        if (from == to) return 0;
        final jmap = await _isJmap(accountId);
        final separator = await imapSeparator(accountId);
        final rows = await _rowsOf(accountId);
        final moved = [
          for (final r in rows)
            if (r.path == from ||
                (!jmap && r.path.startsWith('$from$separator')))
              r,
        ];
        var released = 0;
        for (final d in moved) {
          final newPath = '$to${d.path.substring(from.length)}';
          final existing =
              rows.where((r) => r.path == newPath && r.id != d.id).firstOrNull;
          if (existing != null) {
            await _merge(d, existing);
          } else {
            await (_db.update(_db.mailboxes)..where((t) => t.id.equals(d.id)))
                .write(MailboxesCompanion(path: Value(newPath)));
          }
          await _db.customUpdate(
            'UPDATE mailboxes SET parent_id = ?3 '
            'WHERE account_id = ?1 AND parent_id = ?2',
            variables: [
              Variable.withString(accountId),
              Variable.withString(d.path),
              Variable.withString(newPath),
            ],
            updates: {_db.mailboxes},
            updateKind: UpdateKind.update,
          );
          await _repointMailboxOps(accountId, d.path, newPath);
          await _moveThreads(accountId, d.path, newPath);
          await _moveCheckpoints(accountId, d.path, newPath);
          released += await _emails.renameFolder(accountId, d.path, newPath);
        }
        await rebuildDisplayPaths(accountId);
        return released;
      });

  /// Local row [local] turned out to be [cached], a row sync already
  /// stored for the server's folder: [local]'s ops move to [cached] and
  /// [local] goes (App Log warn `mailbox.local_merged`).
  Future<void> _merge(MailboxRow local, MailboxRow cached) async {
    await _db.customUpdate(
      'UPDATE pending_changes SET resource_id = ?2 ' // not an email id
      "WHERE resource_type = '$mailboxResourceType' AND resource_id = ?1",
      variables: [
        Variable.withString(local.id),
        Variable.withString(cached.id),
      ],
      updates: {_db.pendingChanges},
      updateKind: UpdateKind.update,
    );
    await (_db.delete(_db.mailboxes)..where((t) => t.id.equals(local.id))).go();
    await _refoldRow(cached.id);
    _log(
      (logger) => logger.warn(
        'mailbox.local_merged',
        'The folder "${local.name}" created on this device is the server\'s '
            'folder "${cached.name}"; they are shown as one',
        accountId: local.accountId,
        mailboxPath: cached.path,
        data: {'localId': local.id, 'mailboxId': cached.id},
      ),
    );
  }

  /// The queued creates and moves of [accountId] whose parent is [from]
  /// name [to] (a move's Undo parent too); the moved folders re-fold.
  Future<void> _repointMailboxOps(
    String accountId,
    String from,
    String to,
  ) async {
    final ops = await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.resourceType.equals(mailboxResourceType) &
                t.changeType.isIn(const [createMailboxOp, moveMailboxOp]),
          ))
        .get();
    for (final op in ops) {
      final payload = _payloadOf(op);
      if (payload == null) continue;
      var changed = false;
      for (final key in const [mailboxOpParent, mailboxOpFromParent]) {
        if (payload[key] != from) continue;
        payload[key] = to;
        changed = true;
      }
      if (!changed) continue;
      await (_db.update(_db.pendingChanges)..where((t) => t.id.equals(op.id)))
          .write(PendingChangesCompanion(payload: Value(jsonEncode(payload))));
      if (op.changeType == moveMailboxOp) await _refoldRow(op.resourceId);
      _log(
        (logger) => logger.warn(
          'pending_change.folder_renamed',
          'A queued ${_describe(op)} naming "$from" as parent names "$to" '
              'now: the server gave the parent folder that path',
          accountId: accountId,
          data: {'changeId': op.id, 'from': from, 'to': to},
        ),
      );
    }
  }

  /// The thread rows of folder [from] become [to]'s. A thread already
  /// stored there (the server's folder was synced before) keeps its row and
  /// is recalculated.
  Future<void> _moveThreads(String accountId, String from, String to) async {
    final clashing = [
      for (final r in await _db.customSelect(
        'SELECT a.id FROM threads a JOIN threads b ON b.id = a.id '
        'AND b.account_id = a.account_id AND b.mailbox_path = ?3 '
        'WHERE a.account_id = ?1 AND a.mailbox_path = ?2',
        variables: [
          Variable.withString(accountId),
          Variable.withString(from),
          Variable.withString(to),
        ],
      ).get())
        r.read<String>('id'),
    ];
    await _db.customUpdate(
      'UPDATE OR IGNORE threads SET mailbox_path = ?3 '
      'WHERE account_id = ?1 AND mailbox_path = ?2',
      variables: [
        Variable.withString(accountId),
        Variable.withString(from),
        Variable.withString(to),
      ],
      updates: {_db.threads},
      updateKind: UpdateKind.update,
    );
    await _db.customUpdate(
      'DELETE FROM threads WHERE account_id = ?1 AND mailbox_path = ?2',
      variables: [Variable.withString(accountId), Variable.withString(from)],
      updates: {_db.threads},
      updateKind: UpdateKind.delete,
    );
    for (final id in clashing) {
      await refreshThreadAggregate(_db, accountId, to, id);
    }
  }

  /// The IMAP sync checkpoints of folder [from] become [to]'s.
  Future<void> _moveCheckpoints(
    String accountId,
    String from,
    String to,
  ) async {
    for (final prefix in const ['IMAP:', 'IMAP:FlagReconcileDue:']) {
      final old = await (_db.select(_db.syncStates)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.resourceType.equals('$prefix$from'),
            ))
          .getSingleOrNull();
      if (old == null) continue;
      await (_db.delete(_db.syncStates)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.resourceType.equals('$prefix$from'),
            ))
          .go();
      await _db.into(_db.syncStates).insertOnConflictUpdate(
            SyncStatesCompanion.insert(
              accountId: accountId,
              resourceType: '$prefix$to',
              state: old.state,
              syncedAt: old.syncedAt,
            ),
          );
    }
  }

  // ── Other row writes ───────────────────────────────────────────────────

  /// Deletes the cached mailbox at [path] (the folder is gone on the
  /// server: `removeLocalMailbox`).
  Future<void> deleteRow(String accountId, String path) async {
    // Its acked ops have nothing left to settle against; failed ones stay
    // listed for the user. An acked delete stays until the next listing
    // ([settleAckedDeletes]): it keeps a stale one from bringing the
    // folder back.
    final row = await rowByPath(accountId, path);
    if (row != null) {
      await (_db.delete(_db.pendingChanges)
            ..where(
              (t) =>
                  t.resourceType.equals(mailboxResourceType) &
                  t.resourceId.equals(row.id) &
                  t.state.equals('acked') &
                  t.changeType.equals(deleteMailboxOp).not(),
            ))
          .go();
    }
    await (_db.delete(_db.mailboxes)
          ..where((t) => t.accountId.equals(accountId) & t.path.equals(path)))
        .go();
    await rebuildDisplayPaths(accountId);
  }

  // ── Consistency ────────────────────────────────────────────────────────

  /// The mailboxes (of [accountId], all when null) that break the
  /// overlay's invariants: `local_name` not the fold of the ops, `name`
  /// not `COALESCE(local_name, srv_name)`, a row created offline without a
  /// create op, and a mailbox op whose mailbox is gone that is not
  /// `failed` (it would wait forever). Empty when consistent.
  Future<List<String>> consistencyProblems({String? accountId}) async {
    final problems = <String>[];
    final rows = await (_db.select(_db.mailboxes)
          ..where(
            (t) => accountId == null
                ? const Constant(true)
                : t.accountId.equals(accountId),
          ))
        .get();
    final ops = await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.resourceType.equals(mailboxResourceType) &
                (accountId == null
                    ? const Constant(true)
                    : t.accountId.equals(accountId)),
          ))
        .get();
    final byMailbox = <String, List<PendingChangeRow>>{};
    for (final op in ops) {
      (byMailbox[op.resourceId] ??= []).add(op);
    }
    for (final r in rows) {
      final own = byMailbox.remove(r.id) ?? const [];
      final foldOps = own.map(_foldOpOf).toList();
      final fold = foldMailboxName(foldOps);
      if (fold != r.localName) {
        problems.add('${r.id}: local_name ${r.localName} != fold $fold');
      }
      final parent = foldMailboxParent(foldOps);
      if (parent != r.localParent) {
        problems.add('${r.id}: local_parent ${r.localParent} != fold $parent');
      }
      final hidden = foldMailboxHidden(foldOps);
      if (hidden != r.localHidden) {
        problems.add('${r.id}: local_hidden ${r.localHidden} != fold $hidden');
      }
      final effective = r.localName ?? r.srvName;
      if (effective != null && effective != r.name) {
        problems.add('${r.id}: name ${r.name} != $effective');
      }
      if (r.isLocal && !own.any((o) => o.changeType == createMailboxOp)) {
        problems.add('${r.id}: created offline without a create op');
      }
    }
    for (final entry in byMailbox.entries) {
      for (final op in entry.value) {
        if (op.state == 'failed') continue;
        // Kept after its folder went, until the next listing.
        if (op.state == 'acked' && op.changeType == deleteMailboxOp) continue;
        problems.add('${entry.key}: ${op.changeType} op ${op.id} '
            '(${op.state}) without its mailbox');
      }
    }
    return problems;
  }

  /// [consistencyProblems] for [accountId], logged (App Log error
  /// `overlay.inconsistent`) and repaired by a re-fold of every mailbox of
  /// the account. Mailboxes are few, so all of them are checked.
  Future<List<String>> checkAndRepair(String accountId) async {
    // A counterpart's stand-in whose shadow create went with its move (in
    // another isolate) is no inconsistency: it is dropped first.
    await dropOrphanedCounterpartFolders(accountId);
    final problems = await consistencyProblems(accountId: accountId);
    if (problems.isEmpty) return problems;
    _log(
      (logger) => logger.error(
        'overlay.inconsistent',
        'Mailbox overlay inconsistent (${problems.length}); repaired by a '
            're-fold',
        accountId: accountId,
        data: {'problems': problems.take(20).toList()},
      ),
    );
    await _db.transaction(() async {
      for (final r in await _rowsOf(accountId)) {
        await _refoldRow(r.id);
      }
      await rebuildDisplayPaths(accountId);
    });
    return problems;
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  Future<void> _deleteOp(int id) =>
      (_db.delete(_db.pendingChanges)..where((t) => t.id.equals(id))).go();

  Expression<bool> _ownsClaim($PendingChangesTable t, PendingChangeRow row) {
    final token = row.claimToken;
    return t.id.equals(row.id) &
        t.state.equals('inflight') &
        (token == null ? t.claimToken.isNull() : t.claimToken.equals(token));
  }

  static String _describe(PendingChangeRow op) => switch (op.changeType) {
        createMailboxOp => 'folder creation',
        renameMailboxOp => 'folder rename',
        moveMailboxOp => 'folder move',
        deleteMailboxOp => 'folder delete',
        'move' => 'move',
        'snooze' => 'snooze',
        'unsnooze' => 'unsnooze',
        'delete' => 'delete',
        final other => '"$other" change',
      };

  /// Runs [write] outside the transaction this runs in: the logger writes
  /// to the same database and would otherwise be tied to (and outlive) it.
  void _log(Future<void>? Function(AppLogger logger) write) {
    final logger = _appLogger;
    if (logger == null) return;
    Zone.root.run(() => unawaited(write(logger)));
  }
}

MailboxFoldOp _foldOpOf(PendingChangeRow op) {
  final payload = _payloadOf(op);
  return MailboxFoldOp(
    seq: op.id,
    type: op.changeType,
    name: payload?[mailboxOpName] as String?,
    state: op.state,
    parent: op.changeType == moveMailboxOp
        ? (payload?[mailboxOpParent] as String? ?? '')
        : null,
  );
}

Map<String, dynamic>? _payloadOf(PendingChangeRow op) {
  try {
    final decoded = jsonDecode(op.payload);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}
