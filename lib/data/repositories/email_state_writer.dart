import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/db/keyword_fold.dart';

/// The email state writer of SYNC-REDESIGN.md §2 for the `keywords` overlay
/// (`is_seen`, `is_flagged`, `snoozed_until`). Every write of these columns
/// goes through it, and it writes the effective column in the same statement
/// as the `srv_` or `local_` column it changes, so the invariant
/// `<field> = COALESCE(local_<field>, srv_<field>)` holds after every
/// statement. It only sets the columns it changes, never the whole row (a
/// whole-row write re-fires the FTS update trigger).
///
/// Its three roles:
/// - the **server-write gate** ([beginRead], [KeywordRead.write],
///   [withServerKeywords]): the only way sync sets these fields. A read
///   writes `srv_*` only if it started no earlier than the read that last
///   wrote them (`srv_keywords_seq`), and settles the row's acked ops;
/// - the **fold** ([refold]): recomputes `local_*` from the row's foldable
///   ops; called in the transaction of anything that changes them;
/// - **rows without a server copy** ([writeOwn]): a local virtual row (or
///   a mail whose server id is unknown) has no op to fold, so the user's
///   value is its "server" value until phase 4 adds parked ops.
///
/// Its own file and class, so `mailbox_repository_impl.dart` can use it too.
class EmailStateWriter {
  EmailStateWriter(this._db, {AppLogger? appLogger}) : _appLogger = appLogger;

  final AppDatabase _db;
  final AppLogger? _appLogger;

  /// The next value of the read sequence (SYNC-REDESIGN.md §4.1). Take it
  /// right before sending a server read, and at an ack.
  Future<int> nextReadSeq() async {
    final row = await _db
        .customSelect(
          'INSERT INTO sync_read_seq (id, seq) VALUES (1, 1) '
          'ON CONFLICT(id) DO UPDATE SET seq = seq + 1 RETURNING seq',
        )
        .getSingle();
    return row.read<int>('seq');
  }

  /// Starts a server read of the `keywords` group for [accountId]: call
  /// right before the request (IMAP `UID FETCH` of FLAGS, JMAP `Email/get`
  /// with `keywords`), then [KeywordRead.write] each answer.
  Future<KeywordRead> beginRead(String accountId) async {
    final seq = await nextReadSeq();
    return KeywordRead._(
      this,
      accountId,
      seq,
      Zone.current[_syncRunKey] as int? ?? seq,
    );
  }

  /// Runs [body] as one sync run: the reads it begins share the run's start
  /// sequence. An acked op a read contradicted is dropped only by a read of
  /// a later run (or one outside a run), never by a second read moments
  /// later in the same run, which would tell nothing new about a server
  /// whose reads lag its writes.
  Future<T> inSyncRun<T>(Future<T> Function() body) async {
    final start = await nextReadSeq();
    return runZoned(body, zoneValues: {_syncRunKey: start});
  }

  /// [row], a companion for a **new** row, with the `keywords` group of a
  /// server read [seq] (0 for a row no read wrote, e.g. the Sent copy).
  static EmailsCompanion withServerKeywords(
    EmailsCompanion row,
    ServerKeywords keywords, {
    required int seq,
  }) =>
      row.copyWith(
        srvIsSeen: Value(keywords.seen),
        srvIsFlagged: Value(keywords.flagged),
        srvSnoozedUntil: Value(keywords.snoozedUntil),
        srvKeywordsSeq: Value(seq),
        localIsSeen: const Value(null),
        localIsFlagged: const Value(null),
        localSnoozedUntil: const Value(null),
        isSeen: Value(keywords.seen),
        isFlagged: Value(keywords.flagged),
        snoozedUntil: Value(keywords.snoozedUntil),
      );

  /// Recomputes the `local_*` keyword columns of row [emailId] from its
  /// foldable ops ([foldKeywords]) and its effective columns with them.
  /// Returns whether the effective value changed. Run it in the transaction
  /// that changed the row's ops; it runs in a transaction (a savepoint when
  /// nested) of its own as well, so reading the ops and writing the row
  /// cannot interleave with another writer's enqueue and fold.
  Future<bool> refold(String emailId) => _db.transaction(() async {
        final ops = await (_db.select(_db.pendingChanges)
              ..where(
                (t) =>
                    t.resourceId.equals(emailId) &
                    t.state.isIn(foldableOpStates),
              ))
            .get();
        final local = foldKeywords(ops.map(foldOpOf));
        final before = await _effective(emailId);
        if (before == null) return false;
        final snooze = local.snoozedUntil;
        await _db.customUpdate(
          'UPDATE emails SET '
          'local_is_seen = ?1, local_is_flagged = ?2, local_snoozed_until = ?3, '
          'is_seen = COALESCE(?1, srv_is_seen), '
          'is_flagged = COALESCE(?2, srv_is_flagged), '
          'snoozed_until = NULLIF(COALESCE(?3, srv_snoozed_until), 0) '
          'WHERE id = ?4',
          variables: [
            Variable<bool>(local.seen),
            Variable<bool>(local.flagged),
            Variable<int>(snooze == null ? null : _seconds(snooze)),
            Variable.withString(emailId),
          ],
          updates: {_db.emails},
          updateKind: UpdateKind.update,
        );
        return before != await _effective(emailId);
      });

  /// [refold] for each of [emailIds]; returns those whose effective value
  /// changed.
  Future<Set<String>> refoldAll(Iterable<String> emailIds) async {
    final changed = <String>{};
    for (final id in emailIds.toSet()) {
      if (await refold(id)) changed.add(id);
    }
    return changed;
  }

  /// Sets the keyword values of row [emailId] that has no server copy to
  /// change (a local virtual row, a mail whose server id is unknown): no op
  /// is queued for it, so the value is stored as its server value. Null
  /// leaves a field; [snoozedUntil] [snoozeCleared] ends a snooze.
  Future<void> writeOwn(
    String emailId, {
    bool? seen,
    bool? flagged,
    DateTime? snoozedUntil,
  }) async {
    if (seen == null && flagged == null && snoozedUntil == null) return;
    await _db.customUpdate(
      'UPDATE emails SET '
      'srv_is_seen = COALESCE(?1, srv_is_seen), '
      'srv_is_flagged = COALESCE(?2, srv_is_flagged), '
      'srv_snoozed_until = CASE WHEN ?3 IS NULL THEN srv_snoozed_until '
      'ELSE NULLIF(?3, 0) END, '
      'is_seen = COALESCE(local_is_seen, ?1, srv_is_seen), '
      'is_flagged = COALESCE(local_is_flagged, ?2, srv_is_flagged), '
      'snoozed_until = NULLIF(COALESCE(local_snoozed_until, ?3, '
      'srv_snoozed_until), 0) '
      'WHERE id = ?4',
      variables: [
        Variable<bool>(seen),
        Variable<bool>(flagged),
        Variable<int>(snoozedUntil == null ? null : _seconds(snoozedUntil)),
        Variable.withString(emailId),
      ],
      updates: {_db.emails},
      updateKind: UpdateKind.update,
    );
  }

  /// The bulk form of the fold for `markAllAsRead`: each of [emailIds] just
  /// got a `flag_seen` op with `seen: true` as its newest, so the fold
  /// gives `local_is_seen = 1` and nothing else changes.
  Future<void> foldSeenBulk(List<String> emailIds) async {
    for (var i = 0; i < emailIds.length; i += 500) {
      final chunk = emailIds.sublist(
        i,
        i + 500 > emailIds.length ? emailIds.length : i + 500,
      );
      await _db.customUpdate(
        'UPDATE emails SET local_is_seen = 1, is_seen = 1 '
        'WHERE id IN (${List.filled(chunk.length, '?').join(', ')})',
        variables: [for (final id in chunk) Variable.withString(id)],
        updates: {_db.emails},
        updateKind: UpdateKind.update,
      );
    }
  }

  /// Settles [op], a claimed change the server just applied
  /// (SYNC-REDESIGN.md §4.4): one that writes a keyword column becomes
  /// `acked` with `ack_seq` = the next read sequence and keeps folding until
  /// a later read settles it ([KeywordRead.write]). Older acked ops of the
  /// row whose columns it covers are dropped: they no longer show anywhere.
  /// Returns false when [op] is not acked (no keyword column, or its row is
  /// gone), for the caller to delete it as before.
  Future<bool> ack(PendingChangeRow op) async {
    final columns = keywordColumnsOf(op.changeType, _payloadOf(op));
    if (columns.isEmpty) return false;
    return _db.transaction(() async {
      final row = await (_db.selectOnly(_db.emails)
            ..addColumns([_db.emails.id])
            ..where(_db.emails.id.equals(op.resourceId)))
          .getSingleOrNull();
      if (row == null) return false;
      final ackSeq = await nextReadSeq();
      final count = await (_db.update(_db.pendingChanges)
            ..where((t) => t.id.equals(op.id) & t.state.equals('inflight')))
          .write(
        PendingChangesCompanion(
          state: const Value('acked'),
          ackSeq: Value(ackSeq),
          contradictedSeq: const Value(null),
          leaseUntil: const Value(null),
          claimToken: const Value(null),
          lastError: const Value(null),
        ),
      );
      if (count == 0) return true;
      final older = await (_db.select(_db.pendingChanges)
            ..where(
              (t) =>
                  t.resourceId.equals(op.resourceId) &
                  t.state.equals('acked') &
                  t.id.isSmallerThanValue(op.id),
            ))
          .get();
      var dropped = false;
      for (final o in older) {
        if (!columns
            .containsAll(keywordColumnsOf(o.changeType, _payloadOf(o)))) {
          continue;
        }
        await (_db.delete(_db.pendingChanges)..where((t) => t.id.equals(o.id)))
            .go();
        dropped = true;
      }
      if (dropped) await refold(op.resourceId);
      return true;
    });
  }

  /// Deletes acked ops whose row no longer exists (deleted by sync, merged
  /// away): nothing will ever read them back.
  Future<void> dropOrphanedAcks(String accountId) => _db.customUpdate(
        "DELETE FROM pending_changes WHERE state = 'acked' "
        'AND account_id = ?1 '
        'AND resource_id NOT IN (SELECT id FROM emails)',
        variables: [Variable.withString(accountId)],
        updates: {_db.pendingChanges},
        updateKind: UpdateKind.delete,
      );

  /// The rows of [accountId] (all accounts when null) that break the
  /// overlay's invariants: an effective column that is not
  /// `COALESCE(local, srv)`, or a `local_*` value without a foldable op.
  /// Empty when consistent. For tests, the fuzz property and the sampled
  /// checks of phase 3b.
  Future<List<String>> consistencyProblems({String? accountId}) async {
    final scope = accountId == null ? '' : 'AND e.account_id = ?1';
    final rows = await _db.customSelect(
      '''
      SELECT e.id,
        e.is_seen IS NOT COALESCE(e.local_is_seen, e.srv_is_seen) AS bad_seen,
        e.is_flagged IS NOT COALESCE(e.local_is_flagged, e.srv_is_flagged)
          AS bad_flagged,
        e.snoozed_until IS NOT
          NULLIF(COALESCE(e.local_snoozed_until, e.srv_snoozed_until), 0)
          AS bad_snooze,
        (e.local_is_seen IS NOT NULL OR e.local_is_flagged IS NOT NULL
          OR e.local_snoozed_until IS NOT NULL)
          AND NOT EXISTS (SELECT 1 FROM pending_changes p
            WHERE p.resource_id = e.id
              AND p.state IN ('pending', 'inflight', 'stuck', 'acked'))
          AS orphan_local
      FROM emails e
      WHERE (e.is_seen IS NOT COALESCE(e.local_is_seen, e.srv_is_seen)
        OR e.is_flagged IS NOT COALESCE(e.local_is_flagged, e.srv_is_flagged)
        OR e.snoozed_until IS NOT
          NULLIF(COALESCE(e.local_snoozed_until, e.srv_snoozed_until), 0)
        OR ((e.local_is_seen IS NOT NULL OR e.local_is_flagged IS NOT NULL
            OR e.local_snoozed_until IS NOT NULL)
          AND NOT EXISTS (SELECT 1 FROM pending_changes p
            WHERE p.resource_id = e.id
              AND p.state IN ('pending', 'inflight', 'stuck', 'acked'))))
        $scope
      ''',
      variables: [if (accountId != null) Variable.withString(accountId)],
    ).get();
    final opsByRow = <String, List<PendingChangeRow>>{};
    for (final op in await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.state.isIn(foldableOpStates) &
                (accountId == null
                    ? const Constant(true)
                    : t.accountId.equals(accountId)),
          ))
        .get()) {
      (opsByRow[op.resourceId] ??= []).add(op);
    }
    final notFolded = <String>[];
    final locals = await _db.customSelect(
      'SELECT id, local_is_seen, local_is_flagged, local_snoozed_until '
      'FROM emails e WHERE (local_is_seen IS NOT NULL '
      'OR local_is_flagged IS NOT NULL OR local_snoozed_until IS NOT NULL '
      'OR EXISTS (SELECT 1 FROM pending_changes p '
      'WHERE p.resource_id = e.id '
      "AND p.state IN ('pending', 'inflight', 'stuck', 'acked'))) $scope",
      variables: [if (accountId != null) Variable.withString(accountId)],
    ).get();
    for (final r in locals) {
      final id = r.read<String>('id');
      final snooze = r.readNullable<int>('local_snoozed_until');
      final stored = KeywordLocal(
        seen: r.readNullable<bool>('local_is_seen'),
        flagged: r.readNullable<bool>('local_is_flagged'),
        snoozedUntil: snooze == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(snooze * 1000, isUtc: true),
      );
      final folded = foldKeywords((opsByRow[id] ?? const []).map(foldOpOf));
      // The fold at second precision, as stored.
      final expected = KeywordLocal(
        seen: folded.seen,
        flagged: folded.flagged,
        snoozedUntil: folded.snoozedUntil == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                _seconds(folded.snoozedUntil!) * 1000,
                isUtc: true,
              ),
      );
      if (stored != expected) {
        notFolded.add('$id: local_* $stored, the fold of its ops $expected');
      }
    }
    return [
      ...notFolded,
      for (final r in rows)
        '${r.read<String>('id')}:'
            '${r.read<bool>('bad_seen') ? ' is_seen' : ''}'
            '${r.read<bool>('bad_flagged') ? ' is_flagged' : ''}'
            '${r.read<bool>('bad_snooze') ? ' snoozed_until' : ''}'
            '${r.read<bool>('orphan_local') ? ' local_* without an op' : ''}',
    ];
  }

  Future<_Effective?> _effective(String emailId) async {
    final row = await _db.customSelect(
      'SELECT is_seen, is_flagged, snoozed_until FROM emails WHERE id = ?1',
      variables: [Variable.withString(emailId)],
    ).getSingleOrNull();
    if (row == null) return null;
    return _Effective(
      seen: row.read<bool>('is_seen'),
      flagged: row.read<bool>('is_flagged'),
      snoozedUntil: row.readNullable<int>('snoozed_until'),
    );
  }

  Future<KeywordWrite> _write(
    KeywordRead read,
    String emailId,
    ServerKeywords keywords,
  ) =>
      // One transaction: the write, the settling of the acked ops and the
      // re-fold must not interleave with an enqueue and its fold.
      _db.transaction(() => _writeInTransaction(read, emailId, keywords));

  Future<KeywordWrite> _writeInTransaction(
    KeywordRead read,
    String emailId,
    ServerKeywords keywords,
  ) async {
    final before = await _effective(emailId);
    if (before == null) return KeywordWrite.stale;
    final snooze = keywords.snoozedUntil;
    final count = await _db.customUpdate(
      'UPDATE emails SET '
      'srv_is_seen = ?1, srv_is_flagged = ?2, srv_snoozed_until = ?3, '
      'srv_keywords_seq = ?4, '
      'is_seen = COALESCE(local_is_seen, ?1), '
      'is_flagged = COALESCE(local_is_flagged, ?2), '
      'snoozed_until = NULLIF(COALESCE(local_snoozed_until, ?3), 0) '
      'WHERE id = ?5 AND srv_keywords_seq <= ?4',
      variables: [
        Variable<bool>(keywords.seen),
        Variable<bool>(keywords.flagged),
        Variable<int>(snooze == null ? null : _seconds(snooze)),
        Variable.withInt(read.seq),
        Variable.withString(emailId),
      ],
      updates: {_db.emails},
      updateKind: UpdateKind.update,
    );
    // A read that started before the one that last wrote the row: its
    // answer is older (SYNC-REDESIGN.md §4.3).
    if (count == 0) return KeywordWrite.stale;
    if (await read._hasAcked(emailId)) {
      await _settleAcked(read, emailId, keywords);
    }
    return KeywordWrite(changed: before != await _effective(emailId));
  }

  /// [KeywordRead.writeAll]: rows whose `srv_*` already hold the read's
  /// values and that have no acked op only get the read's stamp, in one
  /// statement per group of equal values (`UPDATE … RETURNING id`, so a row
  /// whose values changed meanwhile is not stamped over them); every other
  /// row goes through [_write]. Returns the rows whose shown value changed.
  Future<Set<String>> _writeAll(
    KeywordRead read,
    Map<String, ServerKeywords> byRow,
  ) =>
      _db.transaction(() async {
        final groups = <(bool, bool, int?), List<String>>{};
        for (final MapEntry(key: id, value: k) in byRow.entries) {
          if (await read._hasAcked(id)) continue;
          final snooze = k.snoozedUntil;
          (groups[(
            k.seen,
            k.flagged,
            snooze == null ? null : _seconds(snooze),
          )] ??= [])
              .add(id);
        }
        final stamped = <String>{};
        for (final MapEntry(key: (seen, flagged, snooze), value: ids)
            in groups.entries) {
          for (var i = 0; i < ids.length; i += 500) {
            final chunk = ids.sublist(
              i,
              i + 500 > ids.length ? ids.length : i + 500,
            );
            final rows = await _db.customSelect(
              'UPDATE emails SET srv_keywords_seq = ?1 '
              'WHERE srv_keywords_seq <= ?1 AND srv_is_seen = ?2 '
              'AND srv_is_flagged = ?3 AND srv_snoozed_until IS ?4 '
              'AND id IN (${List.filled(chunk.length, '?').join(', ')}) '
              'RETURNING id',
              variables: [
                Variable.withInt(read.seq),
                Variable<bool>(seen),
                Variable<bool>(flagged),
                Variable<int>(snooze),
                for (final id in chunk) Variable.withString(id),
              ],
            ).get();
            stamped.addAll(rows.map((r) => r.read<String>('id')));
          }
        }
        final changed = <String>{};
        for (final MapEntry(key: id, value: k) in byRow.entries) {
          if (stamped.contains(id)) continue;
          if ((await _writeInTransaction(read, id, k)).changed) changed.add(id);
        }
        return changed;
      });

  /// SYNC-REDESIGN.md §4.5 for the acked ops of [emailId] after [read]
  /// wrote [keywords] to it: an op acked before the read started is
  /// dropped when the read agrees with it, kept on the first contradicting
  /// read and dropped on a later one (App Log `op.contradicted`: the
  /// server's value replaces the user's). Re-folds when one was dropped.
  Future<void> _settleAcked(
    KeywordRead read,
    String emailId,
    ServerKeywords keywords,
  ) async {
    final ops = await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.resourceId.equals(emailId) & t.state.isIn(foldableOpStates),
          ))
        .get();
    final acked = [
      for (final op in ops)
        if (op.state == 'acked' && (op.ackSeq ?? read.seq) < read.seq) op,
    ];
    var dropped = false;
    for (final op in acked) {
      // A newer change of the same fields shows instead of it: whatever the
      // server says, this one no longer matters (and is no contradiction).
      final columns = keywordColumnsOf(op.changeType, _payloadOf(op));
      final shadowed = ops.any(
        (o) =>
            o.id > op.id &&
            keywordColumnsOf(o.changeType, _payloadOf(o)).containsAll(columns),
      );
      if (shadowed) {
        await (_db.delete(_db.pendingChanges)..where((t) => t.id.equals(op.id)))
            .go();
        dropped = true;
        continue;
      }
      final agrees = readAgreesWith(foldOpOf(op), keywords);
      final contradictedBefore = op.contradictedSeq;
      if (!agrees && contradictedBefore == null) {
        await (_db.update(_db.pendingChanges)..where((t) => t.id.equals(op.id)))
            .write(PendingChangesCompanion(contradictedSeq: Value(read.seq)));
        // The second read must not wait for the 15-minute reconcile: an
        // unchanged mail is not read again before (IMAP CONDSTORE, JMAP).
        await makeFlagReconcileDue(emailId);
        continue;
      }
      if (!agrees && read.runStart <= contradictedBefore!) continue;
      await (_db.delete(_db.pendingChanges)..where((t) => t.id.equals(op.id)))
          .go();
      dropped = true;
      if (!agrees) _logContradicted(op, keywords);
    }
    if (dropped) await refold(emailId);
  }

  /// Makes the flag reconcile of the folder row [emailId] is in on the
  /// server due (the `…ReconcileDue:<folder>` markers the sync reads), so
  /// its next sync reads the row's keywords again.
  Future<void> makeFlagReconcileDue(String emailId) => _db.customUpdate(
        'INSERT OR REPLACE INTO sync_states '
        '(account_id, resource_type, state, synced_at) '
        'SELECT e.account_id, '
        "CASE WHEN a.account_type = 'jmap' "
        "THEN 'JMAP:ReconcileDue:' || e.mailbox_path "
        "ELSE 'IMAP:FlagReconcileDue:' || "
        'COALESCE(e.srv_mailbox_path, e.mailbox_path) END, ?1, ?2 '
        'FROM emails e JOIN accounts a ON a.id = e.account_id '
        'WHERE e.id = ?3',
        variables: [
          Variable.withString(DateTime.now().toIso8601String()),
          Variable.withInt(DateTime.now().millisecondsSinceEpoch ~/ 1000),
          Variable.withString(emailId),
        ],
        updates: {_db.syncStates},
        updateKind: UpdateKind.insert,
      );

  /// App Log line for an acked op that two reads after its ack
  /// contradicted: the row shows the server's value from now on.
  void _logContradicted(PendingChangeRow op, ServerKeywords keywords) {
    final logger = _appLogger;
    if (logger == null) return;
    // Outside the transaction this runs in: the logger writes to the same
    // database and would otherwise be tied to (and outlive) it.
    Zone.root.run(
      () => unawaited(
        logger.warn(
          'op.contradicted',
          'The server applied a change and later reads show something '
              'else; showing the server\'s value',
          accountId: op.accountId,
          emailId: op.resourceId,
          data: {
            'changeType': op.changeType,
            'payload': op.payload,
            'ackSeq': op.ackSeq,
            'serverSeen': keywords.seen,
            'serverFlagged': keywords.flagged,
            'serverSnoozedUntil': keywords.snoozedUntil?.toIso8601String(),
          },
        ),
      ),
    );
  }
}

/// Zone key of the start sequence of the sync run
/// ([EmailStateWriter.inSyncRun]) the code runs in.
final _syncRunKey = Object();

/// A server read of the `keywords` group ([EmailStateWriter.beginRead]).
class KeywordRead {
  KeywordRead._(this._writer, this.accountId, this.seq, this.runStart);

  final EmailStateWriter _writer;
  final String accountId;

  /// This read's sequence, taken before its request was sent.
  final int seq;

  /// The sequence the sync run this read belongs to started at
  /// ([EmailStateWriter.inSyncRun]); [seq] for a read outside a run.
  final int runStart;

  Set<String>? _ackedRows;

  /// The server-write gate for one row: writes [keywords] as row
  /// [emailId]'s `srv_*` values (and the effective ones with them) unless
  /// a read that started later already wrote them, then settles the row's
  /// acked ops.
  Future<KeywordWrite> write(String emailId, ServerKeywords keywords) =>
      _writer._write(this, emailId, keywords);

  /// [write] for many rows at once (a whole folder's FLAGS): unchanged rows
  /// are only stamped, in bulk. Returns the rows whose shown value changed.
  Future<Set<String>> writeAll(Map<String, ServerKeywords> byRow) =>
      _writer._writeAll(this, byRow);

  /// Whether [emailId] may have acked ops: the account's acked rows are
  /// loaded once per read (after its answer arrived; an op acked later has
  /// a larger `ack_seq` than [seq] and is not this read's business).
  Future<bool> _hasAcked(String emailId) async {
    _ackedRows ??= {
      for (final r in await (_writer._db.selectOnly(_writer._db.pendingChanges)
            ..addColumns([_writer._db.pendingChanges.resourceId])
            ..where(
              _writer._db.pendingChanges.accountId.equals(accountId) &
                  _writer._db.pendingChanges.state.equals('acked'),
            ))
          .get())
        r.read(_writer._db.pendingChanges.resourceId)!,
    };
    return _ackedRows!.contains(emailId);
  }
}

/// The outcome of [KeywordRead.write].
class KeywordWrite {
  const KeywordWrite({required this.changed, this.written = true});

  /// Not written: the row is gone, or a later read wrote it already.
  static const stale = KeywordWrite(changed: false, written: false);

  final bool written;

  /// Whether the value the app shows changed (the thread aggregate needs
  /// a refresh then).
  final bool changed;
}

/// [op] for the fold.
FoldOp foldOpOf(PendingChangeRow op) => FoldOp(
      seq: op.id,
      type: op.changeType,
      payload: _payloadOf(op),
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

int _seconds(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

class _Effective {
  const _Effective({
    required this.seen,
    required this.flagged,
    required this.snoozedUntil,
  });

  final bool seen;
  final bool flagged;
  final int? snoozedUntil;

  @override
  bool operator ==(Object other) =>
      other is _Effective &&
      other.seen == seen &&
      other.flagged == flagged &&
      other.snoozedUntil == snoozedUntil;

  @override
  int get hashCode => Object.hash(seen, flagged, snoozedUntil);
}
