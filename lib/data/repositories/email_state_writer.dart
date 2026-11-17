import 'dart:async';
import 'dart:convert';
import 'dart:math';

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

  /// The rows that break the overlay's invariants (SYNC-REDESIGN.md §2):
  /// an effective column that is not `COALESCE(local, srv)`, or a `local_*`
  /// value that is not the fold of the row's foldable ops (which covers one
  /// on a row without any). Rows of [accountId] (all accounts when null);
  /// only [emailIds] when given, otherwise every row that has a `local_*`
  /// value, a foldable op or an effective column out of line. Empty when
  /// consistent. For tests, the fuzz property and [checkSample].
  Future<List<ConsistencyProblem>> consistencyProblems({
    String? accountId,
    Iterable<String>? emailIds,
  }) async {
    final rows = <QueryRow>[];
    if (emailIds == null) {
      rows.addAll(
        await _db.customSelect(
          '$_overlaySelect WHERE ('
          'e.is_seen IS NOT COALESCE(e.local_is_seen, e.srv_is_seen) '
          'OR e.is_flagged IS NOT COALESCE(e.local_is_flagged, '
          'e.srv_is_flagged) '
          'OR e.snoozed_until IS NOT NULLIF(COALESCE(e.local_snoozed_until, '
          'e.srv_snoozed_until), 0) '
          'OR e.local_is_seen IS NOT NULL OR e.local_is_flagged IS NOT NULL '
          'OR e.local_snoozed_until IS NOT NULL '
          'OR EXISTS (SELECT 1 FROM pending_changes p '
          'WHERE p.resource_id = e.id AND p.state IN ($_foldableSql)))'
          '${accountId == null ? '' : ' AND e.account_id = ?1'}',
          variables: [if (accountId != null) Variable.withString(accountId)],
        ).get(),
      );
    } else {
      final ids = emailIds.toSet().toList();
      for (var i = 0; i < ids.length; i += 500) {
        final chunk = ids.sublist(i, min(i + 500, ids.length));
        rows.addAll(
          await _db.customSelect(
            '$_overlaySelect WHERE e.id IN '
            '(${List.filled(chunk.length, '?').join(', ')})'
            '${accountId == null ? '' : ' AND e.account_id = ?'}',
            variables: [
              for (final id in chunk) Variable.withString(id),
              if (accountId != null) Variable.withString(accountId),
            ],
          ).get(),
        );
      }
    }
    final opsByRow = <String, List<PendingChangeRow>>{};
    final rowIds = [for (final r in rows) r.read<String>('id')];
    for (var i = 0; i < rowIds.length; i += 500) {
      final chunk = rowIds.sublist(i, min(i + 500, rowIds.length));
      for (final op in await (_db.select(_db.pendingChanges)
            ..where(
              (t) => t.state.isIn(foldableOpStates) & t.resourceId.isIn(chunk),
            ))
          .get()) {
        (opsByRow[op.resourceId] ??= []).add(op);
      }
    }
    return [
      for (final r in rows)
        if (_problemOf(r, opsByRow[r.read<String>('id')] ?? const [])
            case final problem?)
          problem,
    ];
  }

  static const _overlaySelect = 'SELECT e.id, e.account_id, '
      'e.is_seen, e.is_flagged, e.snoozed_until, '
      'e.srv_is_seen, e.srv_is_flagged, e.srv_snoozed_until, '
      'e.local_is_seen, e.local_is_flagged, e.local_snoozed_until '
      'FROM emails e';

  static final _foldableSql = foldableOpStates.map((s) => "'$s'").join(', ');

  /// The invariants of one row read with [_overlaySelect] and its foldable
  /// [ops]; null when it keeps them.
  ConsistencyProblem? _problemOf(QueryRow r, List<PendingChangeRow> ops) {
    final seen = r.read<bool>('is_seen');
    final flagged = r.read<bool>('is_flagged');
    final snooze = r.readNullable<int>('snoozed_until');
    final srvSeen = r.read<bool>('srv_is_seen');
    final srvFlagged = r.read<bool>('srv_is_flagged');
    final srvSnooze = r.readNullable<int>('srv_snoozed_until');
    final localSeen = r.readNullable<bool>('local_is_seen');
    final localFlagged = r.readNullable<bool>('local_is_flagged');
    final localSnooze = r.readNullable<int>('local_snoozed_until');
    final folded = foldKeywords(ops.map(foldOpOf));
    final foldSnooze =
        folded.snoozedUntil == null ? null : _seconds(folded.snoozedUntil!);
    final shownSnooze = localSnooze ?? srvSnooze;
    final fields = [
      if (seen != (localSeen ?? srvSeen)) 'is_seen',
      if (flagged != (localFlagged ?? srvFlagged)) 'is_flagged',
      if (snooze != (shownSnooze == 0 ? null : shownSnooze)) 'snoozed_until',
      if (localSeen != folded.seen) 'local_is_seen',
      if (localFlagged != folded.flagged) 'local_is_flagged',
      if (localSnooze != foldSnooze) 'local_snoozed_until',
    ];
    if (fields.isEmpty) return null;
    return ConsistencyProblem(
      emailId: r.read<String>('id'),
      accountId: r.read<String>('account_id'),
      fields: fields,
      withoutOps: ops.isEmpty,
      values: {
        'effective': {'seen': seen, 'flagged': flagged, 'snoozedUntil': snooze},
        'srv': {
          'seen': srvSeen,
          'flagged': srvFlagged,
          'snoozedUntil': srvSnooze,
        },
        'local': {
          'seen': localSeen,
          'flagged': localFlagged,
          'snoozedUntil': localSnooze,
        },
        'fold': {
          'seen': folded.seen,
          'flagged': folded.flagged,
          'snoozedUntil': foldSnooze,
        },
        'ops': [for (final op in ops) '#${op.id} ${op.state} ${op.changeType}'],
      },
    );
  }

  /// The sampled form of [consistencyProblems] that runs after sync runs
  /// in every build ([OverlayConsistencySampler]), bounded so it stays cheap
  /// on a large mailbox: the rows of [accountId] with the [sampleSize] most
  /// recent foldable ops, plus [sampleSize] rows in `rowid` order from a
  /// random start (wrapping around). It reads in one transaction, so an
  /// enqueue and its fold cannot fall between reading a row and its ops.
  ///
  /// Each problem is logged first (App Log error `overlay.inconsistent`,
  /// the mismatching fields and the row's values in `data`) and then
  /// repaired by re-folding the row ([refold]: `local_*` from its ops, the
  /// effective columns from both). Logging first keeps the bug visible;
  /// repairing spares the user a wrong read/star/snooze state until the
  /// row's next server read. The log line says that it repaired.
  Future<List<ConsistencyProblem>> checkSample(
    String accountId, {
    int sampleSize = 200,
    Random? random,
  }) async {
    final problems = await _db.transaction(() async {
      final ids = await sampleIds(
        accountId,
        sampleSize: sampleSize,
        random: random ?? Random(),
      );
      return consistencyProblems(accountId: accountId, emailIds: ids);
    });
    for (final p in problems) {
      await _appLogger?.error(
        'overlay.inconsistent',
        'Read/star/snooze columns out of line (${p.fields.join(', ')}); '
            're-folding the row to repair it',
        accountId: p.accountId,
        emailId: p.emailId,
        data: {'fields': p.fields, 'withoutOps': p.withoutOps, ...p.values},
      );
      await refold(p.emailId);
    }
    return problems;
  }

  /// The rows [checkSample] looks at, see there.
  Future<Set<String>> sampleIds(
    String accountId, {
    required int sampleSize,
    required Random random,
  }) async {
    final ids = <String>{
      for (final r in await _db.customSelect(
        'SELECT resource_id AS id FROM pending_changes '
        'WHERE account_id = ?1 AND state IN ($_foldableSql) '
        'GROUP BY resource_id ORDER BY MAX(id) DESC LIMIT ?2',
        variables: [
          Variable.withString(accountId),
          Variable.withInt(sampleSize),
        ],
      ).get())
        r.read<String>('id'),
    };
    final bounds = await _db
        .customSelect('SELECT MIN(rowid) AS lo, MAX(rowid) AS hi FROM emails')
        .getSingle();
    final lo = bounds.readNullable<int>('lo');
    final hi = bounds.readNullable<int>('hi');
    if (lo == null || hi == null) return ids;
    final start = lo + random.nextInt(hi - lo + 1);
    Future<List<String>> block(String range, int limit) async => [
          for (final r in await _db.customSelect(
            'SELECT id FROM emails WHERE account_id = ?1 AND rowid $range ?2 '
            'ORDER BY rowid LIMIT ?3',
            variables: [
              Variable.withString(accountId),
              Variable.withInt(start),
              Variable.withInt(limit),
            ],
          ).get())
            r.read<String>('id'),
        ];
    final after = await block('>=', sampleSize);
    ids.addAll(after);
    if (after.length < sampleSize) {
      ids.addAll(await block('<', sampleSize - after.length));
    }
    return ids;
  }

  // ── Other columns ──────────────────────────────────────────────────────
  // Writes of `emails` that touch no overlay column, kept here so that one
  // file holds the table's writers (scripts/check_email_writes.sh; the
  // location writes still elsewhere are on its allow-list until phase 4).

  /// Deletes row [emailId]; its body and downloaded attachments cascade.
  /// Phase 4's clean-up rule (a row with ops is hidden, not deleted) will
  /// live here.
  Future<void> deleteRow(String emailId) =>
      (_db.delete(_db.emails)..where((t) => t.id.equals(emailId))).go();

  /// Deletes every row [accountId] shows in [mailboxPath] (a folder that is
  /// gone, or whose UIDVALIDITY changed), or every row of the account when
  /// [mailboxPath] is null (force resync).
  Future<void> deleteRowsOf(String accountId, {String? mailboxPath}) =>
      (_db.delete(_db.emails)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  (mailboxPath == null
                      ? const Constant(true)
                      : t.mailboxPath.equals(mailboxPath)),
            ))
          .go();

  /// Fills header columns of row [emailId] that a later schema added or an
  /// earlier sync missed (null leaves a column alone). No user intent, so
  /// any read may write them (SYNC-REDESIGN.md §2).
  Future<void> writeHeaders(
    String emailId, {
    String? preview,
    String? listUnsubscribeHeader,
    String? replyToJson,
    String? bccJson,
  }) =>
      (_db.update(_db.emails)..where((t) => t.id.equals(emailId))).write(
        EmailsCompanion(
          preview: Value.absentIfNull(preview),
          listUnsubscribeHeader: Value.absentIfNull(listUnsubscribeHeader),
          replyToJson: Value.absentIfNull(replyToJson),
          bccJson: Value.absentIfNull(bccJson),
        ),
      );

  /// Stores the message sizes in [sizeById] (email row id → bytes) in one
  /// batch.
  Future<void> writeSizes(Map<String, int> sizeById) async {
    if (sizeById.isEmpty) return;
    await _db.batch((b) {
      for (final MapEntry(key: id, value: size) in sizeById.entries) {
        b.update(
          _db.emails,
          EmailsCompanion(sizeBytes: Value(size)),
          where: (t) => t.id.equals(id),
        );
      }
    });
  }

  /// The foreign-move carry-over (`_carryOverMovedRow`): row [keepId] takes
  /// everything [copy] recorded except its id, the read/star/snooze state
  /// with the stamp it was read under included, and the fold of [keepId]'s
  /// ops (the copy's point here by now) goes over it.
  Future<void> takeOverRow(String keepId, Email copy) async {
    await (_db.update(_db.emails)..where((t) => t.id.equals(keepId)))
        .write(copy.toCompanion(false).copyWith(id: const Value.absent()));
    await refold(keepId);
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

/// A row that breaks the `keywords` overlay's invariants
/// ([EmailStateWriter.consistencyProblems]).
class ConsistencyProblem {
  const ConsistencyProblem({
    required this.emailId,
    required this.accountId,
    required this.fields,
    required this.withoutOps,
    required this.values,
  });

  final String emailId;
  final String accountId;

  /// The columns out of line: an effective column (`is_seen`,
  /// `is_flagged`, `snoozed_until`) that is not `COALESCE(local, srv)`, or
  /// a `local_*` column that is not the fold of the row's ops.
  final List<String> fields;

  /// Whether the row has no foldable op (then every `local_*` must be NULL).
  final bool withoutOps;

  /// The row's effective, `srv_*` and `local_*` values, the fold and the
  /// ops, for the App Log.
  final Map<String, Object?> values;

  @override
  String toString() => '$emailId: ${fields.join(' ')}'
      '${withoutOps ? ' (no foldable op)' : ''} $values';
}

/// Runs [EmailStateWriter.checkSample] after a sync run, at most once per
/// [interval] per account, on at most twice [sampleSize] rows
/// (SYNC-REDESIGN.md §8 phase 3b). In memory, so per isolate and reset on
/// restart: the first sync run of an account after a start checks.
class OverlayConsistencySampler {
  OverlayConsistencySampler({
    this.interval = const Duration(minutes: 30),
    this.sampleSize = 200,
    DateTime Function() now = DateTime.now,
    Random? random,
  })  : _now = now,
        _random = random ?? Random();

  final Duration interval;
  final int sampleSize;
  final DateTime Function() _now;
  final Random _random;
  final Map<String, DateTime> _lastRun = {};

  /// Checks a sample of [accountId]'s rows through [writer] unless that ran
  /// less than [interval] ago; returns the problems found (empty when
  /// skipped). Never throws: a check must not fail a sync.
  Future<List<ConsistencyProblem>> afterSyncRun(
    EmailStateWriter writer,
    String accountId,
  ) async {
    final now = _now();
    final last = _lastRun[accountId];
    if (last != null && now.difference(last) < interval) return const [];
    _lastRun[accountId] = now;
    try {
      return await writer.checkSample(
        accountId,
        sampleSize: sampleSize,
        random: _random,
      );
    } catch (e, st) {
      await writer._appLogger?.warn(
        'overlay.check_failed',
        'The sampled read/star/snooze consistency check failed',
        accountId: accountId,
        error: e,
        stack: st,
      );
      return const [];
    }
  }
}
