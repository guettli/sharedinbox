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

/// SQL (correlated on the `mailboxes` alias [m]): whether the mailbox shows.
/// A mailbox created offline shows only while its `create_mailbox` op folds
/// ([localMailboxShown]).
String mailboxShownSql(String m) =>
    'NOT ($m.is_local AND NOT EXISTS (SELECT 1 FROM pending_changes p '
    "WHERE p.resource_id = $m.id AND p.change_type = '$createMailboxOp' "
    'AND p.state IN ($_foldableSql)))';

final _foldableSql = foldableOpStates.map((s) => "'$s'").join(', ');

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

  /// The paths of [accountId]'s mailboxes that have no server copy yet:
  /// an email op naming one waits for its create.
  Future<Set<String>> localPaths(String accountId) async => {
        for (final r in await _db.customSelect(
          'SELECT path FROM mailboxes WHERE account_id = ?1 AND is_local = 1',
          variables: [Variable.withString(accountId)],
        ).get())
          r.read<String>('path'),
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
      final separator = _imapSeparator(parent?.path, rows);
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
                  (jmap ? r.parentId == parentPath : r.path == imapPath),
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
  /// rename of it that no flush has claimed yet, and a failed one, is
  /// replaced (a rename writes the whole name); back to the server's name
  /// with nothing sent, no op is needed at all.
  Future<MailboxRow> enqueueRename(MailboxRow row, String newName) =>
      _db.transaction(() async {
        await (_db.delete(_db.pendingChanges)
              ..where(
                (t) =>
                    t.resourceType.equals(mailboxResourceType) &
                    t.resourceId.equals(row.id) &
                    t.changeType.equals(renameMailboxOp) &
                    t.state.isIn(const ['pending', 'failed']),
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

  /// The IMAP hierarchy separator a folder created below [parentPath]
  /// most likely needs: the one in the parent's path, else the one the
  /// account's other paths use, else `/`. A wrong guess is corrected by
  /// the create's ack ([serverPathChanged]).
  static String _imapSeparator(String? parentPath, List<MailboxRow> rows) {
    for (final path in [
      if (parentPath != null) parentPath,
      for (final r in rows) r.path,
    ]) {
      if (path.contains('/')) return '/';
      if (path.contains('.') && path.startsWith('INBOX.')) return '.';
    }
    return '/';
  }

  Future<Set<String>> _shownIds(String accountId) async => {
        for (final r in await _db.customSelect(
          'SELECT m.id FROM mailboxes m WHERE m.account_id = ?1 '
          'AND ${mailboxShownSql('m')}',
          variables: [Variable.withString(accountId)],
        ).get())
          r.read<String>('id'),
      };

  // ── The fold ───────────────────────────────────────────────────────────

  /// Recomputes `local_name` (and the effective `name`) of mailbox
  /// [mailboxId] from its foldable ops, then the account's display paths.
  Future<void> refold(String mailboxId) => _db.transaction(() async {
        final row = await _refoldRow(mailboxId);
        if (row != null) await rebuildDisplayPaths(row.accountId);
      });

  Future<MailboxRow?> _refoldRow(String mailboxId) async {
    final ops = await _opsOf(mailboxId);
    final local = foldMailboxName(ops.map(_foldOpOf));
    await _db.customUpdate(
      'UPDATE mailboxes SET local_name = ?1, '
      'name = COALESCE(?1, srv_name, name) WHERE id = ?2',
      variables: [Variable<String>(local), Variable.withString(mailboxId)],
      updates: {_db.mailboxes},
      updateKind: UpdateKind.update,
    );
    return rowById(mailboxId);
  }

  /// Rewrites the `display_path` of [accountId]'s mailboxes whose derived
  /// value ([displayPaths]) changed.
  Future<void> rebuildDisplayPaths(String accountId) async {
    final rows = await _rowsOf(accountId);
    final derived = displayPaths(
      [
        for (final r in rows)
          DisplayPathRow(
            path: r.path,
            name: r.name,
            localName: r.localName,
            srvName: r.srvName,
            parentId: r.parentId,
          ),
      ],
      jmap: await _isJmap(accountId),
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
        final row = await rowByPath(accountId, path);
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
            parentId: Value(parentId),
          ),
        );
        if (readSeq < row.srvSeq) return;
        await _db.customUpdate(
          'UPDATE mailboxes SET srv_name = ?1, srv_seq = ?2, is_local = 0, '
          'name = COALESCE(local_name, ?1) WHERE id = ?3',
          variables: [
            Variable.withString(name),
            Variable.withInt(readSeq),
            Variable.withString(row.id),
          ],
          updates: {_db.mailboxes},
          updateKind: UpdateKind.update,
        );
        await _settleAcked(row.id, name, readSeq);
      });

  /// Settles the acked ops of mailbox [mailboxId] against [srvName], read
  /// at [readSeq].
  Future<void> _settleAcked(
    String mailboxId,
    String srvName,
    int readSeq,
  ) async {
    final acked = (await _opsOf(mailboxId))
        .where((o) => o.state == 'acked' && (o.ackSeq ?? 0) < readSeq);
    var changed = false;
    for (final op in acked) {
      if (mailboxReadAgrees(_foldOpOf(op), srvName)) {
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
          'The server calls the folder "$srvName" after a confirmed '
              '${_describe(op)}; showing the server\'s name',
          accountId: op.accountId,
          mailboxPath: row?.path,
          data: {
            'changeId': op.id,
            'changeType': op.changeType,
            'name': _payloadOf(op)?[mailboxOpName],
            'serverName': srvName,
          },
        ),
      );
    }
    if (changed) await _refoldRow(mailboxId);
  }

  /// The cached mailboxes of [accountId] that a listing which started at
  /// [readSeq] and returned [keepPaths] says are gone: not listed, not
  /// created offline (no server copy to be gone), and not written by a
  /// later read or ack (a folder just created or renamed, §4.3).
  Future<List<MailboxRow>> prunable(
    String accountId,
    Set<String> keepPaths,
    int readSeq,
  ) async =>
      [
        for (final r in await _rowsOf(accountId))
          if (!keepPaths.contains(r.path) && !r.isLocal && r.srvSeq <= readSeq)
            r,
      ];

  /// Server paths an acked IMAP rename moved a folder away from after
  /// [readSeq]: a listing that started before it may still list them, and
  /// must not bring the old folder back.
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
          if (_payloadOf(op)?[mailboxOpFromPath] case final String from) from,
      };

  // ── Flush outcomes ─────────────────────────────────────────────────────

  /// Settles [claimed], a mailbox op the server applied (or found already
  /// done): `acked` with `ack_seq` = the next read sequence, and what the
  /// server confirmed recorded at once, stamped with it: the mailbox
  /// exists at [serverPath] under [serverName]. A path other than the
  /// row's (a JMAP create's new id, an IMAP create whose separator was
  /// guessed wrong, an IMAP rename) moves everything naming the old one
  /// ([serverPathChanged]). The op keeps folding until a mailbox listing
  /// started after the ack settles it ([writeServer]). Returns false when
  /// the flush no longer owned the claim.
  Future<bool> ack(
    PendingChangeRow claimed, {
    required String serverPath,
    required String serverName,
  }) async {
    var released = 0;
    final ok = await _db.transaction(() async {
      final ackSeq = await _emails.nextReadSeq();
      final row = await rowById(claimed.resourceId);
      final payload = _payloadOf(claimed) ?? {};
      if (row != null &&
          claimed.changeType == renameMailboxOp &&
          row.path != serverPath) {
        payload[mailboxOpFromPath] = row.path;
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
        depends = op.resourceId == row.id ||
            (op.changeType == createMailboxOp &&
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
  /// (a new `seq`), folding again. Nothing when its folder is gone.
  Future<void> retry(PendingChangeRow op) => _db.transaction(() async {
        final current = await (_db.select(_db.pendingChanges)
              ..where((t) => t.id.equals(op.id) & t.state.equals('failed')))
            .getSingleOrNull();
        if (current == null) return;
        final row = await rowById(op.resourceId);
        if (row == null) return;
        await _insertOp(
          current.accountId,
          current.resourceId,
          current.changeType,
          current.payload,
        );
        await _deleteOp(current.id);
        await _refoldRow(row.id);
        await rebuildDisplayPaths(row.accountId);
      });

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
    String path,
  ) async {
    final row = await rowByPath(accountId, path);
    if (row == null) return const [];
    final failed = <PendingChangeRow>[];
    for (final op in await _opsOf(row.id)) {
      if (!const ['pending', 'stuck'].contains(op.state)) continue;
      final dependents =
          await fail(op, 'folder removed on the server', claimed: false);
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
        final rows = await _rowsOf(accountId);
        final moved = [
          for (final r in rows)
            if (r.path == from ||
                (!jmap &&
                    (r.path.startsWith('$from/') ||
                        r.path.startsWith('$from.'))))
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

  /// The queued creates of [accountId] whose parent is [from] name [to].
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
                t.changeType.equals(createMailboxOp),
          ))
        .get();
    for (final op in ops) {
      final payload = _payloadOf(op);
      if (payload == null || payload[mailboxOpParent] != from) continue;
      payload[mailboxOpParent] = to;
      await (_db.update(_db.pendingChanges)..where((t) => t.id.equals(op.id)))
          .write(PendingChangesCompanion(payload: Value(jsonEncode(payload))));
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
    await (_db.delete(_db.mailboxes)
          ..where((t) => t.accountId.equals(accountId) & t.path.equals(path)))
        .go();
    await rebuildDisplayPaths(accountId);
  }

  /// Force resync: forgets [accountId]'s cached mailboxes, except the ones
  /// a queued mailbox op still needs (a folder created offline, a pending
  /// rename): the next listing finds them again by their path.
  Future<void> clearForResync(String accountId) => _db.customUpdate(
        'DELETE FROM mailboxes WHERE account_id = ?1 '
        'AND NOT EXISTS (SELECT 1 FROM pending_changes p '
        "WHERE p.resource_type = '$mailboxResourceType' "
        'AND p.resource_id = mailboxes.id)',
        variables: [Variable.withString(accountId)],
        updates: {_db.mailboxes},
        updateKind: UpdateKind.delete,
      );

  /// The server-first JMAP folder move (phase 5b makes it an op): the
  /// server put [row] below [parentPath].
  Future<void> writeServerParent(MailboxRow row, String? parentPath) async {
    await (_db.update(_db.mailboxes)..where((t) => t.id.equals(row.id)))
        .write(MailboxesCompanion(parentId: Value(parentPath)));
    await rebuildDisplayPaths(row.accountId);
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
      final fold = foldMailboxName(own.map(_foldOpOf));
      if (fold != r.localName) {
        problems.add('${r.id}: local_name ${r.localName} != fold $fold');
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

MailboxFoldOp _foldOpOf(PendingChangeRow op) => MailboxFoldOp(
      seq: op.id,
      type: op.changeType,
      name: _payloadOf(op)?[mailboxOpName] as String?,
      state: op.state,
    );

Map<String, dynamic>? _payloadOf(PendingChangeRow op) {
  try {
    final decoded = jsonDecode(op.payload);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}
