import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/db/keyword_fold.dart';

/// The effective `mailbox_path` in SQL (SYNC-REDESIGN.md §2), from the
/// expressions [local] (`local_mailbox_path`), [hidden] (`local_hidden`),
/// [srv] (`srv_mailbox_path`) and [gone] (`srv_gone`). A `SET` expression
/// sees the row's old values, so a statement that changes one of them
/// passes the new value here. The final `mailbox_path` only covers a row
/// whose `srv_mailbox_path` is NULL, which the insert trigger prevents.
String _shownPathSql({
  String local = 'local_mailbox_path',
  String hidden = 'local_hidden',
  String srv = 'srv_mailbox_path',
  String gone = 'srv_gone',
}) =>
    "CASE WHEN $hidden THEN '' WHEN $gone AND $local IS NULL THEN '' "
    'ELSE COALESCE($local, $srv, mailbox_path) END';

/// The email state writer of SYNC-REDESIGN.md §2 for the `keywords` overlay
/// (`is_seen`, `is_flagged`, `snoozed_until`) and the `location` overlay
/// (`mailbox_path`, with `srv_mailbox_path`, `local_mailbox_path`,
/// `local_hidden`, `srv_gone`). Every write of these columns goes through
/// it, and it writes the effective column in the same statement as the
/// `srv_` or `local_` column it changes, so the invariant
/// `<field> = COALESCE(local_<field>, srv_<field>)` holds after every
/// statement. It only sets the columns it changes, never the whole row (a
/// whole-row write re-fires the FTS update trigger).
///
/// Its three roles:
/// - the **server-write gate** ([beginRead], [KeywordRead.write],
///   [KeywordRead.writeLocation], [KeywordRead.markGone],
///   [withServerKeywords], [withServerLocation]): the only way sync sets
///   these fields. A read writes a group only if it started no earlier than
///   the read that last wrote it (`srv_keywords_seq`, `srv_location_seq`),
///   and settles the row's acked ops;
/// - the **fold** ([refold]): recomputes `local_*` from the row's foldable
///   ops; called in the transaction of anything that changes them;
/// - **rows without a server copy** ([writeOwn], [writeOwnLocation]): a
///   local virtual row (or a mail whose server id is unknown) has no op to
///   fold, so the user's value is its "server" value until phase 4b adds
///   parked ops.
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

  /// Starts a server read for [accountId]: call right before the request
  /// (IMAP `UID FETCH` of FLAGS, `UID SEARCH ALL`, JMAP `Email/get`,
  /// `Email/query`, `Email/changes`), then write each answer through it.
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

  /// A **new** row [id] of [accountId] with the server's [headers] (which
  /// must hold `uid` and `receivedAt`), in [mailboxPath] with [keywords] as a
  /// server read [seq] says ([withServerLocation], [withServerKeywords]).
  static Insertable<Email> newRow(
    EmailsCompanion headers, {
    required String id,
    required String accountId,
    required String mailboxPath,
    required ServerKeywords keywords,
    required int seq,
  }) =>
      RawValuesInsertable<Email>({
        ...withServerLocation(
          withServerKeywords(headers, keywords, seq: seq),
          mailboxPath,
          seq: seq,
        ).toColumns(true),
        'id': Variable.withString(id),
        'account_id': Variable.withString(accountId),
      });

  /// [row], a companion for a **new** row, in [mailboxPath] as a server
  /// read [seq] (0 for a row no read placed, e.g. a local virtual row, whose
  /// folder is its own) says: a new row has no pending move.
  static EmailsCompanion withServerLocation(
    EmailsCompanion row,
    String mailboxPath, {
    required int seq,
  }) =>
      row.copyWith(
        mailboxPath: Value(mailboxPath),
        srvMailboxPath: Value(mailboxPath),
        localMailboxPath: const Value(null),
        localHidden: const Value(false),
        srvGone: const Value(false),
        srvLocationSeq: Value(seq),
      );

  /// Recomputes the `local_*` columns of row [emailId] from its foldable
  /// ops ([foldKeywords], [foldLocation]) and its effective columns with
  /// them. Returns whether an effective value changed. Run it in the
  /// transaction that changed the row's ops; it runs in a transaction (a
  /// savepoint when nested) of its own as well, so reading the ops and
  /// writing the row cannot interleave with another writer's enqueue and
  /// fold.
  Future<bool> refold(String emailId) async =>
      (await refoldRow(emailId))?.changed ?? false;

  /// [refold], with the folder the row showed before and shows now (for
  /// the thread aggregates of both); null when the row is gone.
  Future<Refold?> refoldRow(String emailId) => _db.transaction(() async {
        final ops = await (_db.select(_db.pendingChanges)
              ..where(
                (t) =>
                    t.resourceId.equals(emailId) &
                    t.state.isIn(foldableOpStates),
              ))
            .get();
        final folded = ops.map(foldOpOf).toList();
        final local = foldKeywords(folded);
        final location = foldLocation(folded);
        final before = await _effective(emailId);
        if (before == null) return null;
        final snooze = local.snoozedUntil;
        await _db.customUpdate(
          'UPDATE emails SET '
          'local_is_seen = ?1, local_is_flagged = ?2, local_snoozed_until = ?3, '
          'is_seen = COALESCE(?1, srv_is_seen), '
          'is_flagged = COALESCE(?2, srv_is_flagged), '
          'snoozed_until = NULLIF(COALESCE(?3, srv_snoozed_until), 0), '
          'local_mailbox_path = ?4, local_hidden = ?5, '
          'mailbox_path = ${_shownPathSql(local: '?4', hidden: '?5')} '
          'WHERE id = ?6',
          variables: [
            Variable<bool>(local.seen),
            Variable<bool>(local.flagged),
            Variable<int>(snooze == null ? null : _seconds(snooze)),
            Variable<String>(location.mailboxPath),
            Variable<bool>(location.hidden),
            Variable.withString(emailId),
          ],
          updates: {_db.emails},
          updateKind: UpdateKind.update,
        );
        final after = await _effective(emailId);
        return Refold(
          changed: before != after,
          before: before.mailboxPath,
          after: after?.mailboxPath ?? before.mailboxPath,
        );
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

  /// [writeOwn] for the folder: row [emailId], which has no server copy to
  /// move, is in [mailboxPath] now.
  Future<void> writeOwnLocation(String emailId, String mailboxPath) =>
      _db.customUpdate(
        'UPDATE emails SET srv_mailbox_path = ?1, srv_gone = 0, '
        'mailbox_path = ${_shownPathSql(srv: '?1', gone: '0')} '
        'WHERE id = ?2',
        variables: [
          Variable.withString(mailboxPath),
          Variable.withString(emailId),
        ],
        updates: {_db.emails},
        updateKind: UpdateKind.update,
      );

  /// Records the folder a snoozed row [emailId] came from (local-only, the
  /// server keeps only the `snz:` keyword); null clears it.
  Future<void> writeSnoozedFrom(String emailId, String? mailboxPath) =>
      (_db.update(_db.emails)..where((t) => t.id.equals(emailId))).write(
        EmailsCompanion(snoozedFromMailboxPath: Value(mailboxPath)),
      );

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
  /// (SYNC-REDESIGN.md §4.4): one that writes an overlay column becomes
  /// `acked` with `ack_seq` = the next read sequence and keeps folding until
  /// a later read settles it ([KeywordRead.write], [KeywordRead.writeLocation],
  /// [KeywordRead.markGone]). What the server confirmed is written as its
  /// state, stamped with `ack_seq`, so no read that started before the ack
  /// can put the old value back: [confirmedMailboxPath], the folder a JMAP
  /// move put the mail in, or [confirmedGone] for a delete for good. (An
  /// IMAP move records its new location before, [relocate].) Older acked
  /// ops of the row whose columns it covers are dropped: they no longer
  /// show anywhere. Returns false when [op] is not acked (no overlay column,
  /// or its row is gone), for the caller to delete it as before.
  Future<bool> ack(
    PendingChangeRow op, {
    String? confirmedMailboxPath,
    bool confirmedGone = false,
  }) async {
    final columns = overlayColumnsOf(op.changeType, _payloadOf(op));
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
      if (confirmedMailboxPath != null) {
        await _writeLocationAt(ackSeq, op.resourceId, confirmedMailboxPath);
      }
      if (confirmedGone) await _markGoneAt(ackSeq, [op.resourceId]);
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
            .containsAll(overlayColumnsOf(o.changeType, _payloadOf(o)))) {
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

  /// The clean-up rule of SYNC-REDESIGN.md §2: deletes the rows of
  /// [accountId] the server no longer has (`srv_gone`) that have no pending,
  /// in-flight, stuck or acked op left; their bodies and attachments
  /// cascade. Nothing can bring such a row back. A row with a `failed` op
  /// goes too: the op stays on the Pending Changes screen. Returns the ids
  /// and folders (as shown before they were hidden: always `''`) of the
  /// rows deleted.
  Future<List<String>> cleanUpGone(String accountId) async {
    final rows = await _db.customWriteReturning(
      'DELETE FROM emails WHERE account_id = ?1 AND srv_gone = 1 '
      'AND NOT EXISTS (SELECT 1 FROM pending_changes p '
      'WHERE p.resource_id = emails.id AND p.state IN ($_foldableSql)) '
      'RETURNING id',
      variables: [Variable.withString(accountId)],
      updates: {_db.emails},
      updateKind: UpdateKind.delete,
    );
    return [for (final r in rows) r.read<String>('id')];
  }

  /// The rows that break the overlays' invariants (SYNC-REDESIGN.md §2):
  /// an effective column that is not `COALESCE(local, srv)` (for
  /// `mailbox_path`: empty when hidden or gone), a `local_*` value that is
  /// not the fold of the row's foldable ops (which covers one on a row
  /// without any), or no `srv_mailbox_path`. Rows of [accountId] (all
  /// accounts when null); only [emailIds] when given, otherwise every row
  /// that has a `local_*` value, a foldable op or an effective column out of
  /// line. Empty when consistent. For tests, the fuzz property and
  /// [checkSample].
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
          'OR e.local_mailbox_path IS NOT NULL OR e.local_hidden '
          'OR e.srv_mailbox_path IS NULL '
          "OR e.mailbox_path IS NOT (CASE WHEN e.local_hidden THEN '' "
          "WHEN e.srv_gone AND e.local_mailbox_path IS NULL THEN '' "
          'ELSE COALESCE(e.local_mailbox_path, e.srv_mailbox_path) END) '
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
      'e.local_is_seen, e.local_is_flagged, e.local_snoozed_until, '
      'e.mailbox_path, e.srv_mailbox_path, e.local_mailbox_path, '
      'e.local_hidden, e.srv_gone '
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
    final path = r.read<String>('mailbox_path');
    final srvPath = r.readNullable<String>('srv_mailbox_path');
    final localPath = r.readNullable<String>('local_mailbox_path');
    final hidden = r.read<bool>('local_hidden');
    final gone = r.read<bool>('srv_gone');
    final folds = ops.map(foldOpOf).toList();
    final folded = foldKeywords(folds);
    final location = foldLocation(folds);
    final foldSnooze =
        folded.snoozedUntil == null ? null : _seconds(folded.snoozedUntil!);
    final shownSnooze = localSnooze ?? srvSnooze;
    final shownPath = srvPath == null
        ? null
        : effectiveMailboxPath(
            localMailboxPath: localPath,
            localHidden: hidden,
            srvMailboxPath: srvPath,
            srvGone: gone,
          );
    final fields = [
      if (seen != (localSeen ?? srvSeen)) 'is_seen',
      if (flagged != (localFlagged ?? srvFlagged)) 'is_flagged',
      if (snooze != (shownSnooze == 0 ? null : shownSnooze)) 'snoozed_until',
      if (localSeen != folded.seen) 'local_is_seen',
      if (localFlagged != folded.flagged) 'local_is_flagged',
      if (localSnooze != foldSnooze) 'local_snoozed_until',
      if (srvPath == null) 'srv_mailbox_path',
      if (shownPath != null && path != shownPath) 'mailbox_path',
      if (localPath != location.mailboxPath) 'local_mailbox_path',
      if (hidden != location.hidden) 'local_hidden',
    ];
    if (fields.isEmpty) return null;
    return ConsistencyProblem(
      emailId: r.read<String>('id'),
      accountId: r.read<String>('account_id'),
      fields: fields,
      withoutOps: ops.isEmpty,
      values: {
        'effective': {
          'seen': seen,
          'flagged': flagged,
          'snoozedUntil': snooze,
          'mailboxPath': path,
        },
        'srv': {
          'seen': srvSeen,
          'flagged': srvFlagged,
          'snoozedUntil': srvSnooze,
          'mailboxPath': srvPath,
          'gone': gone,
        },
        'local': {
          'seen': localSeen,
          'flagged': localFlagged,
          'snoozedUntil': localSnooze,
          'mailboxPath': localPath,
          'hidden': hidden,
        },
        'fold': {
          'seen': folded.seen,
          'flagged': folded.flagged,
          'snoozedUntil': foldSnooze,
          'mailboxPath': location.mailboxPath,
          'hidden': location.hidden,
        },
        'ops': [for (final op in ops) '#${op.id} ${op.state} ${op.changeType}'],
      },
    );
  }

  /// The sampled form of [consistencyProblems] that runs after sync runs
  /// in every build ([OverlayConsistencySampler]), bounded so it stays cheap
  /// on a large mailbox: the rows of [accountId] with the [sampleSize] most
  /// recent foldable ops, plus [sampleSize] rows of the account in `rowid`
  /// order from a random start (wrapping around). It reads in one
  /// transaction, so an enqueue and its fold cannot fall between reading a
  /// row and its ops.
  ///
  /// Each problem is logged first (App Log error `overlay.inconsistent`,
  /// the mismatching fields and the row's values in `data`; the first
  /// [logEach] rows one line each, the rest in one summary line) and then
  /// repaired by re-folding the row ([refold]: `local_*` from its ops, the
  /// effective columns from both). Logging first keeps the bug visible;
  /// repairing spares the user a wrong read/star/snooze state or folder
  /// until the row's next server read. The log line says that it repaired.
  /// [onRepaired] gets the rows whose shown value the repair changed, for
  /// their thread aggregates.
  Future<List<ConsistencyProblem>> checkSample(
    String accountId, {
    int sampleSize = 200,
    int logEach = 10,
    Random? random,
    Future<void> Function(Set<String> emailIds)? onRepaired,
  }) async {
    final problems = await _db.transaction(() async {
      final ids = await sampleIds(
        accountId,
        sampleSize: sampleSize,
        random: random ?? Random(),
      );
      return consistencyProblems(accountId: accountId, emailIds: ids);
    });
    if (problems.isEmpty) return problems;
    for (final p in problems.take(logEach)) {
      await _appLogger?.error(
        'overlay.inconsistent',
        'Overlay columns (read/star/snooze, folder) out of line '
            '(${p.fields.join(', ')}); re-folding the row to repair it',
        accountId: p.accountId,
        emailId: p.emailId,
        data: {'fields': p.fields, 'withoutOps': p.withoutOps, ...p.values},
      );
    }
    if (problems.length > logEach) {
      final rest = problems.skip(logEach).toList();
      await _appLogger?.error(
        'overlay.inconsistent',
        '${problems.length} rows with overlay columns (read/star/snooze, '
            'folder) out of line in one sample, ${rest.length} more than '
            'logged one by one; re-folding them to repair them',
        accountId: accountId,
        data: {
          'total': problems.length,
          'fields': {for (final p in rest) ...p.fields}.toList(),
          'emailIds': [for (final p in rest.take(100)) p.emailId],
        },
      );
    }
    final changed = <String>{};
    for (final p in problems) {
      if (p.fields.contains('srv_mailbox_path')) {
        // No server folder recorded: the folder it shows is the best guess.
        await _db.customUpdate(
          'UPDATE emails SET srv_mailbox_path = mailbox_path '
          'WHERE id = ?1 AND srv_mailbox_path IS NULL',
          variables: [Variable.withString(p.emailId)],
          updates: {_db.emails},
          updateKind: UpdateKind.update,
        );
      }
      if (await refold(p.emailId)) changed.add(p.emailId);
    }
    if (changed.isNotEmpty) await onRepaired?.call(changed);
    return problems;
  }

  /// The rows [checkSample] looks at, see there. The block query reads
  /// `+account_id` so SQLite walks the `rowid` range (stopping after the
  /// limit) instead of collecting the account's rows by index and sorting
  /// them; the range is the account's own, so a start is uniform over it.
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
    final bounds = await _db.customSelect(
      'SELECT MIN(rowid) AS lo, MAX(rowid) AS hi FROM emails '
      'WHERE account_id = ?1',
      variables: [Variable.withString(accountId)],
    ).getSingle();
    final lo = bounds.readNullable<int>('lo');
    final hi = bounds.readNullable<int>('hi');
    if (lo == null || hi == null) return ids;
    final start = lo + random.nextInt(hi - lo + 1);
    Future<List<String>> block(String range, int limit) async => [
          for (final r in await _db.customSelect(
            'SELECT id FROM emails WHERE +account_id = ?1 AND rowid $range ?2 '
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

  /// When [OverlayConsistencySampler] last checked [accountId], kept in
  /// `sync_states` (`Overlay:ConsistencyCheck`), so the interval holds
  /// across restarts and isolates.
  Future<DateTime?> lastSampleCheck(String accountId) async {
    final row = await (_db.select(_db.syncStates)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.resourceType.equals(_sampleCheckKey),
          ))
        .getSingleOrNull();
    return row == null ? null : DateTime.tryParse(row.state);
  }

  /// Records [at] as [lastSampleCheck] of [accountId].
  Future<void> recordSampleCheck(String accountId, DateTime at) =>
      _db.into(_db.syncStates).insertOnConflictUpdate(
            SyncStatesCompanion.insert(
              accountId: accountId,
              resourceType: _sampleCheckKey,
              state: at.toUtc().toIso8601String(),
              syncedAt: at,
            ),
          );

  static const _sampleCheckKey = 'Overlay:ConsistencyCheck';

  // ── Server location facts ──────────────────────────────────────────────

  /// Records that the server has row [emailId]'s mail at [uid] in
  /// [mailboxPath] now (an IMAP MOVE's answer, the body-fetch healing): its
  /// `uid` and server location, stamped with a fresh read sequence, so no
  /// read that started earlier puts the old location back. The folder it
  /// shows follows unless a later move is pending (the fold).
  Future<void> relocate(
    String emailId, {
    required String mailboxPath,
    required int uid,
    required int? uidValidity,
  }) async {
    final seq = await nextReadSeq();
    await _db.customUpdate(
      'UPDATE emails SET uid = ?1, srv_mailbox_path = ?2, srv_uid = ?1, '
      'srv_uid_validity = ?3, srv_jmap_id = NULL, srv_gone = 0, '
      'srv_location_seq = ?4, '
      'mailbox_path = ${_shownPathSql(srv: '?2', gone: '0')} '
      'WHERE id = ?5',
      variables: [
        Variable.withInt(uid),
        Variable.withString(mailboxPath),
        Variable<int>(uidValidity),
        Variable.withInt(seq),
        Variable.withString(emailId),
      ],
      updates: {_db.emails},
      updateKind: UpdateKind.update,
    );
  }

  /// Forgets the IMAP UID of rows [emailIds]: the server gave their
  /// location to another mail. Their folder stays (it is still the last
  /// one known); sync no longer finds them by location.
  Future<void> releaseLocation(Iterable<String> emailIds) async {
    for (final id in emailIds) {
      await (_db.update(_db.emails)..where((t) => t.id.equals(id))).write(
        const EmailsCompanion(srvUid: Value(null), srvUidValidity: Value(null)),
      );
    }
  }

  /// Folder [from] of [accountId] is called [to] now (an IMAP folder
  /// rename, or the Snoozed placeholder getting its JMAP id): the server
  /// folder of its rows, the destinations and sources of the queued changes
  /// (payload `dest`, `src`, `mailboxPath`), the pending moves folded from
  /// them and `snoozed_from_mailbox_path` follow, in one transaction, and so
  /// does the folder the rows show. A row that still records an IMAP
  /// location under [to] (that folder did not exist on the server) gives it
  /// up first: one location, one row. Returns how many rows gave one up.
  Future<int> renameFolder(String accountId, String from, String to) =>
      _db.transaction(() async {
        final released = await _db.customUpdate(
          'UPDATE emails SET srv_uid = NULL, srv_uid_validity = NULL '
          'WHERE account_id = ?1 AND srv_mailbox_path = ?2 '
          'AND srv_uid IN (SELECT srv_uid FROM emails '
          'WHERE account_id = ?1 AND srv_mailbox_path = ?3 '
          'AND srv_uid IS NOT NULL)',
          variables: [
            Variable.withString(accountId),
            Variable.withString(to),
            Variable.withString(from),
          ],
          updates: {_db.emails},
          updateKind: UpdateKind.update,
        );
        final ops = await (_db.select(_db.pendingChanges)
              ..where((t) => t.accountId.equals(accountId)))
            .get();
        for (final op in ops) {
          final payload = _payloadOf(op);
          if (payload == null) continue;
          var changed = false;
          for (final key in const ['dest', 'src', 'mailboxPath']) {
            if (payload[key] != from) continue;
            payload[key] = to;
            changed = true;
          }
          if (!changed) continue;
          final rewritten = jsonEncode(payload);
          await (_db.update(_db.pendingChanges)
                ..where((t) => t.id.equals(op.id)))
              .write(PendingChangesCompanion(payload: Value(rewritten)));
        }
        await _db.customUpdate(
          'UPDATE emails SET '
          'srv_mailbox_path = CASE WHEN srv_mailbox_path = ?2 THEN ?3 '
          'ELSE srv_mailbox_path END, '
          'local_mailbox_path = CASE WHEN local_mailbox_path = ?2 THEN ?3 '
          'ELSE local_mailbox_path END, '
          'snoozed_from_mailbox_path = CASE '
          'WHEN snoozed_from_mailbox_path = ?2 THEN ?3 '
          'ELSE snoozed_from_mailbox_path END, '
          'mailbox_path = ${_shownPathSql(
            local: 'CASE WHEN local_mailbox_path = ?2 THEN ?3 '
                'ELSE local_mailbox_path END',
            srv: 'CASE WHEN srv_mailbox_path = ?2 THEN ?3 '
                'ELSE srv_mailbox_path END',
          )} '
          'WHERE account_id = ?1 AND (srv_mailbox_path = ?2 '
          'OR local_mailbox_path = ?2 OR snoozed_from_mailbox_path = ?2)',
          variables: [
            Variable.withString(accountId),
            Variable.withString(from),
            Variable.withString(to),
          ],
          updates: {_db.emails},
          updateKind: UpdateKind.update,
        );
        return released;
      });

  /// Folder [mailboxPath] of [accountId] is gone on the server (deleted, or
  /// its UIDVALIDITY changed): its rows are marked gone ([KeywordRead.markGone]
  /// with a fresh read sequence) and lose their UID, and the rows without a
  /// pending, in-flight, stuck or acked op left are deleted
  /// ([cleanUpGone]). A row the user still has a change queued for stays,
  /// hidden or shown where that change puts it, until the change settles.
  /// Returns the ids of the rows that stay.
  Future<Set<String>> markFolderGone(
    String accountId,
    String mailboxPath,
  ) async {
    final read = await beginRead(accountId);
    final ids = [
      for (final r in await _db.customSelect(
        'SELECT id FROM emails WHERE account_id = ?1 '
        'AND srv_mailbox_path = ?2 AND is_local = 0',
        variables: [
          Variable.withString(accountId),
          Variable.withString(mailboxPath),
        ],
      ).get())
        r.read<String>('id'),
    ];
    await read.markGone(ids);
    for (var i = 0; i < ids.length; i += 500) {
      final chunk = ids.sublist(i, min(i + 500, ids.length));
      await _db.customUpdate(
        'UPDATE emails SET srv_uid = NULL, srv_uid_validity = NULL '
        'WHERE id IN (${List.filled(chunk.length, '?').join(', ')})',
        variables: [for (final id in chunk) Variable.withString(id)],
        updates: {_db.emails},
        updateKind: UpdateKind.update,
      );
    }
    final deleted = (await cleanUpGone(accountId)).toSet();
    return {
      for (final id in ids)
        if (!deleted.contains(id)) id,
    };
  }

  // ── Other columns ──────────────────────────────────────────────────────
  // Writes of `emails` that touch no overlay column, kept here so that one
  // file holds the table's writers (scripts/check_email_writes.sh).

  /// Deletes row [emailId]; its body and downloaded attachments cascade.
  /// Sync no longer calls this for a mail the server dropped: that is
  /// [KeywordRead.markGone] and [cleanUpGone].
  Future<void> deleteRow(String emailId) =>
      (_db.delete(_db.emails)..where((t) => t.id.equals(emailId))).go();

  /// Deletes every row of [accountId] the server has in [mailboxPath], or
  /// every row of the account when [mailboxPath] is null (force resync).
  Future<void> deleteRowsOf(String accountId, {String? mailboxPath}) =>
      (_db.delete(_db.emails)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  (mailboxPath == null
                      ? const Constant(true)
                      : t.srvMailboxPath.equals(mailboxPath)),
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
  /// and the location with the stamps they were read under included, and
  /// the fold of [keepId]'s ops (the copy's point here by now) goes over it.
  Future<void> takeOverRow(String keepId, Email copy) async {
    await (_db.update(_db.emails)..where((t) => t.id.equals(keepId)))
        .write(copy.toCompanion(false).copyWith(id: const Value.absent()));
    await refold(keepId);
  }

  Future<_Effective?> _effective(String emailId) async {
    final row = await _db.customSelect(
      'SELECT is_seen, is_flagged, snoozed_until, mailbox_path '
      'FROM emails WHERE id = ?1',
      variables: [Variable.withString(emailId)],
    ).getSingleOrNull();
    if (row == null) return null;
    return _Effective(
      seen: row.read<bool>('is_seen'),
      flagged: row.read<bool>('is_flagged'),
      snoozedUntil: row.readNullable<int>('snoozed_until'),
      mailboxPath: row.read<String>('mailbox_path'),
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
    if (await read._hasAcked(emailId)) await _settleAcked(read, emailId);
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

  /// The location gate for one row: the server has row [emailId]'s mail in
  /// [mailboxPath], as a read or an ack at [seq] says. Written only if no
  /// read that started later wrote the row's location. Returns the folder
  /// the row showed before and shows now; null when not written.
  Future<Refold?> _writeLocationAt(
    int seq,
    String emailId,
    String mailboxPath,
  ) async {
    final before = await _effective(emailId);
    if (before == null) return null;
    final count = await _db.customUpdate(
      'UPDATE emails SET srv_mailbox_path = ?1, srv_gone = 0, '
      'srv_location_seq = ?2, '
      'mailbox_path = ${_shownPathSql(srv: '?1', gone: '0')} '
      'WHERE id = ?3 AND srv_location_seq <= ?2',
      variables: [
        Variable.withString(mailboxPath),
        Variable.withInt(seq),
        Variable.withString(emailId),
      ],
      updates: {_db.emails},
      updateKind: UpdateKind.update,
    );
    if (count == 0) return null;
    final after = await _effective(emailId);
    return Refold(
      changed: before != after,
      before: before.mailboxPath,
      after: after?.mailboxPath ?? before.mailboxPath,
    );
  }

  /// Marks [emailIds] gone on the server as a read (or ack) at [seq] says,
  /// each only if no read that started later wrote its location. Returns
  /// the ids marked.
  Future<Set<String>> _markGoneAt(int seq, List<String> emailIds) async {
    final marked = <String>{};
    for (var i = 0; i < emailIds.length; i += 500) {
      final chunk = emailIds.sublist(i, min(i + 500, emailIds.length));
      final rows = await _db.customWriteReturning(
        'UPDATE emails SET srv_gone = 1, srv_location_seq = ?1, '
        'mailbox_path = ${_shownPathSql(gone: '1')} '
        'WHERE srv_location_seq <= ?1 '
        'AND id IN (${List.filled(chunk.length, '?').join(', ')}) '
        'RETURNING id',
        variables: [
          Variable.withInt(seq),
          for (final id in chunk) Variable.withString(id),
        ],
        updates: {_db.emails},
        updateKind: UpdateKind.update,
      );
      marked.addAll(rows.map((r) => r.read<String>('id')));
    }
    return marked;
  }

  /// SYNC-REDESIGN.md §4.5 for the acked ops of [emailId] after [read]
  /// wrote a group of it. An op acked before the read started is settled
  /// once reads after its ack wrote every group it has columns in: dropped
  /// when what they wrote agrees with it, kept on the first contradicting
  /// read and dropped on a later one (App Log `op.contradicted`: the
  /// server's value replaces the user's). A mail the server no longer has
  /// (absence read after the ack) settles every acked op: nothing is left
  /// to confirm. Re-folds when one was dropped.
  Future<void> _settleAcked(KeywordRead read, String emailId) async {
    final row = await _db.customSelect(
      'SELECT srv_is_seen, srv_is_flagged, srv_snoozed_until, '
      'srv_keywords_seq, srv_mailbox_path, srv_gone, srv_location_seq '
      'FROM emails WHERE id = ?1',
      variables: [Variable.withString(emailId)],
    ).getSingleOrNull();
    if (row == null) return;
    final srvSnooze = row.readNullable<int>('srv_snoozed_until');
    final keywords = ServerKeywords(
      seen: row.read<bool>('srv_is_seen'),
      flagged: row.read<bool>('srv_is_flagged'),
      snoozedUntil: srvSnooze == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(srvSnooze * 1000, isUtc: true),
    );
    final keywordsSeq = row.read<int>('srv_keywords_seq');
    final srvPath = row.readNullable<String>('srv_mailbox_path');
    final gone = row.read<bool>('srv_gone');
    final locationSeq = row.read<int>('srv_location_seq');
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
      final ackSeq = op.ackSeq ?? 0;
      final payload = _payloadOf(op);
      // A newer change of the same fields shows instead of it: whatever the
      // server says, this one no longer matters (and is no contradiction).
      final columns = overlayColumnsOf(op.changeType, payload);
      final shadowed = ops.any(
        (o) =>
            o.id > op.id &&
            overlayColumnsOf(o.changeType, _payloadOf(o)).containsAll(columns),
      );
      if (shadowed) {
        await _dropOp(op);
        dropped = true;
        continue;
      }
      final hasLocation = locationColumnsOf(op.changeType, payload).isNotEmpty;
      if (gone && locationSeq > ackSeq) {
        // Gone on the server after the ack: a delete is confirmed, and a
        // move's mail is gone (or its destination copy is a new row).
        await _dropOp(op);
        dropped = true;
        if (hasLocation && op.changeType != 'delete') {
          _logGone(op, srvPath);
        }
        continue;
      }
      final hasKeywords = keywordColumnsOf(op.changeType, payload).isNotEmpty;
      // Not every group the op writes was read after its ack yet.
      if (hasKeywords && keywordsSeq <= ackSeq) continue;
      if (hasLocation && locationSeq <= ackSeq) continue;
      final fold = foldOpOf(op);
      final agrees = (!hasKeywords || readAgreesWith(fold, keywords)) &&
          (!hasLocation ||
              locationAgreesWith(
                fold,
                srvMailboxPath: srvPath,
                srvGone: gone,
              ));
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
      await _dropOp(op);
      dropped = true;
      if (!agrees) _logContradicted(op, keywords, srvPath);
    }
    if (dropped) await refold(emailId);
  }

  Future<void> _dropOp(PendingChangeRow op) =>
      (_db.delete(_db.pendingChanges)..where((t) => t.id.equals(op.id))).go();

  /// Makes the flag reconcile of the folder the server has row [emailId] in
  /// due (the `…ReconcileDue:<folder>` markers the sync reads), so its next
  /// sync reads the row's keywords (and on JMAP, which mails the folder
  /// has) again.
  Future<void> makeFlagReconcileDue(String emailId) => _db.customUpdate(
        'INSERT OR REPLACE INTO sync_states '
        '(account_id, resource_type, state, synced_at) '
        'SELECT e.account_id, '
        "CASE WHEN a.account_type = 'jmap' "
        "THEN 'JMAP:ReconcileDue:' || COALESCE(e.srv_mailbox_path, "
        'e.mailbox_path) '
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

  /// Runs [write] outside the transaction this runs in: the logger writes
  /// to the same database and would otherwise be tied to (and outlive) it.
  void _logOutside(Future<void>? Function(AppLogger logger) write) {
    final logger = _appLogger;
    if (logger == null) return;
    Zone.root.run(() => unawaited(write(logger)));
  }

  /// App Log line for an acked op that two reads after its ack
  /// contradicted: the row shows the server's value from now on.
  void _logContradicted(
    PendingChangeRow op,
    ServerKeywords keywords,
    String? srvMailboxPath,
  ) =>
      _logOutside(
        (logger) => logger.warn(
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
            'serverMailboxPath': srvMailboxPath,
          },
        ),
      );

  /// App Log line for an acked move, snooze or unsnooze whose mail a read
  /// after the ack no longer found where the server had it: the row stops
  /// showing it (another client deleted or moved it, or its new location
  /// was never learnt and the destination's copy is stored as a new row).
  void _logGone(PendingChangeRow op, String? srvMailboxPath) => _logOutside(
        (logger) => logger.warn(
          'op.gone',
          'A ${op.changeType} the server applied: the mail is no longer '
              'where the server had it${srvMailboxPath == null ? '' : ' '
                  '($srvMailboxPath)'}; hiding it here (if it was moved, '
              'its new folder shows it after that folder\'s sync)',
          accountId: op.accountId,
          emailId: op.resourceId,
          data: {
            'changeType': op.changeType,
            'payload': op.payload,
            'ackSeq': op.ackSeq,
          },
        ),
      );
}

/// Zone key of the start sequence of the sync run
/// ([EmailStateWriter.inSyncRun]) the code runs in.
final _syncRunKey = Object();

/// A server read ([EmailStateWriter.beginRead]): of the `keywords` group
/// ([write], [writeAll]) and of the `location` group ([writeLocation],
/// [confirmPresent], [markGone]).
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

  /// The location gate for one row: the server has row [emailId]'s mail in
  /// [mailboxPath] (and so still has it). Written unless a read that started
  /// later wrote the row's location; then settles the row's acked ops.
  /// Returns the folder the row showed before and shows now, for the thread
  /// aggregates; null when not written.
  Future<Refold?> writeLocation(String emailId, String mailboxPath) =>
      _writer._db.transaction(() async {
        final written =
            await _writer._writeLocationAt(seq, emailId, mailboxPath);
        if (written == null) return null;
        if (await _hasAcked(emailId)) {
          await _writer._settleAcked(this, emailId);
          final now = await _writer._effective(emailId);
          return Refold(
            changed: written.before != now?.mailboxPath,
            before: written.before,
            after: now?.mailboxPath ?? written.after,
          );
        }
        return written;
      });

  /// An enumeration of a folder (IMAP `UID SEARCH ALL`, JMAP `Email/query`)
  /// listed rows [emailIds], whose server folder it is: they are still
  /// there. A row marked gone shows again and a row with an acked op is
  /// stamped (its acked ops settle), unless a read that started later wrote
  /// its location; the others are left alone. Returns the rows whose shown
  /// folder changed (a gone row showing again).
  Future<Set<String>> confirmPresent(Iterable<String> emailIds) =>
      _writer._db.transaction(() async {
        final all = emailIds.toList();
        final changed = <String>{};
        final acked = <String>[
          for (final id in all)
            if (await _hasAcked(id)) id,
        ];
        for (var i = 0; i < all.length; i += 500) {
          final chunk = all.sublist(i, min(i + 500, all.length));
          changed.addAll({
            for (final r in await _writer._db.customSelect(
              'SELECT id FROM emails WHERE srv_gone = 1 '
              'AND srv_location_seq <= ?1 '
              'AND id IN (${List.filled(chunk.length, '?').join(', ')})',
              variables: [
                Variable.withInt(seq),
                for (final id in chunk) Variable.withString(id),
              ],
            ).get())
              r.read<String>('id'),
          });
        }
        // Only the rows this tells something new: a gone one shows again,
        // an acked change may settle. Stamping every listed row would
        // rewrite a whole folder on every sync.
        final ids = {...changed, ...acked}.toList();
        for (var i = 0; i < ids.length; i += 500) {
          final chunk = ids.sublist(i, min(i + 500, ids.length));
          final placeholders = List.filled(chunk.length, '?').join(', ');
          await _writer._db.customUpdate(
            'UPDATE emails SET srv_gone = 0, srv_location_seq = ?1, '
            'mailbox_path = ${_shownPathSql(gone: '0')} '
            'WHERE srv_location_seq <= ?1 AND id IN ($placeholders)',
            variables: [
              Variable.withInt(seq),
              for (final id in chunk) Variable.withString(id),
            ],
            updates: {_writer._db.emails},
            updateKind: UpdateKind.update,
          );
        }
        for (final id in acked) {
          await _writer._settleAcked(this, id);
        }
        return changed;
      });

  /// The server no longer has the mails of rows [emailIds] (absent from an
  /// enumeration of their folder, `notFound`, `destroyed`): each is marked
  /// `srv_gone` unless a read that started later wrote its location, and
  /// hidden unless a pending move shows it elsewhere; their acked ops
  /// settle. The row itself stays while it has an op
  /// ([EmailStateWriter.cleanUpGone] deletes it once it has none). Returns
  /// the ids marked.
  Future<Set<String>> markGone(Iterable<String> emailIds) =>
      _writer._db.transaction(() async {
        final marked = await _writer._markGoneAt(seq, emailIds.toList());
        for (final id in marked) {
          if (await _hasAcked(id)) await _writer._settleAcked(this, id);
        }
        return marked;
      });

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

/// The outcome of [EmailStateWriter.refoldRow] and
/// [KeywordRead.writeLocation]: whether an effective value changed, and the
/// folder the row showed [before] and shows [after] (`''`: hidden).
class Refold {
  const Refold({
    required this.changed,
    required this.before,
    required this.after,
  });

  final bool changed;
  final String before;
  final String after;
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
    required this.mailboxPath,
  });

  final bool seen;
  final bool flagged;
  final int? snoozedUntil;
  final String mailboxPath;

  @override
  bool operator ==(Object other) =>
      other is _Effective &&
      other.seen == seen &&
      other.flagged == flagged &&
      other.snoozedUntil == snoozedUntil &&
      other.mailboxPath == mailboxPath;

  @override
  int get hashCode => Object.hash(seen, flagged, snoozedUntil, mailboxPath);
}

/// A row that breaks the overlays' invariants
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
  /// `is_flagged`, `snoozed_until`, `mailbox_path`) that is not
  /// `COALESCE(local, srv)`, a `local_*` column that is not the fold of the
  /// row's ops, or a missing `srv_mailbox_path`.
  final List<String> fields;

  /// Whether the row has no foldable op (then every `local_*` must be
  /// NULL, and `local_hidden` false).
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
/// (SYNC-REDESIGN.md §8 phase 3b). The time of the last check is kept in
/// memory and in the database ([EmailStateWriter.recordSampleCheck]), so the
/// interval holds across restarts, isolates and repository rebuilds.
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
  /// skipped). [onRepaired] as in [EmailStateWriter.checkSample]. Never
  /// throws: a check must not fail a sync.
  Future<List<ConsistencyProblem>> afterSyncRun(
    EmailStateWriter writer,
    String accountId, {
    Future<void> Function(Set<String> emailIds)? onRepaired,
  }) async {
    try {
      final now = _now();
      final last =
          _lastRun[accountId] ?? await writer.lastSampleCheck(accountId);
      // A last check "in the future" (a clock set back) does not count.
      if (last != null &&
          !last.isAfter(now) &&
          now.difference(last) < interval) {
        _lastRun[accountId] = last;
        return const [];
      }
      _lastRun[accountId] = now;
      await writer.recordSampleCheck(accountId, now);
      return await writer.checkSample(
        accountId,
        sampleSize: sampleSize,
        random: _random,
        onRepaired: onRepaired,
      );
    } catch (e, st) {
      await writer._appLogger?.warn(
        'overlay.check_failed',
        'The sampled overlay consistency check failed',
        accountId: accountId,
        error: e,
        stack: st,
      );
      return const [];
    }
  }
}
