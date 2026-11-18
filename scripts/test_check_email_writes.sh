#!/usr/bin/env bash
# Tests for scripts/check_email_writes.sh: fixtures of violations, which
# must fail, and near-misses, which must pass.
# Run directly: bash scripts/test_check_email_writes.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SCRIPT_DIR/check_email_writes.sh"

PASS=0
FAIL=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# expect <pass|fail> <name> <path under lib/> [message]  (file on stdin)
# Puts the fixture alone into a fresh lib/ and runs the check on it; a
# failure must print [message].
expect() {
  local want=$1 name=$2 path=$3 message=${4:-}
  rm -rf "$tmp/lib"
  mkdir -p "$tmp/lib/$(dirname "$path")"
  cat >"$tmp/lib/$path"
  local out
  if out=$(bash "$CHECK" "$tmp/lib" 2>&1); then got=pass; else got=fail; fi
  if [ "$got" = "$want" ] && { [ -z "$message" ] || grep -qF "$message" <<<"$out"; }; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $name: expected $want${message:+ ($message)}, got $got"
    printf '%s\n' "$out" | sed 's/^/  /'
  fi
}

repo=data/repositories/email_repository_impl

# The real allow-list is empty since phase 6a. The fixtures below test the
# rules for allowed members with the three members that were on it last.
fixture_allowed='
lib/data/repositories/email_repository_impl/sync_imap.dart|_fetchAndUpsertImapGuarded|fixture
lib/data/repositories/email_repository_impl/sync_jmap.dart|_upsertJmapEmails|fixture
lib/data/repositories/email_repository_impl/user_actions.dart|_restoreEmail|fixture
'
export EMAIL_WRITES_ALLOWED="$fixture_allowed"

# ── Check 1: overlay columns, no allow-list ─────────────────────────────────
expect fail 'isSeen in an EmailsCompanion, even in an allowed member' \
  "$repo/sync_imap.dart" 'read/star/snooze' <<'EOF'
extension _SyncImap on EmailRepositoryImpl {
  Future<void> _fetchAndUpsertImapGuarded() async {
    final upsert = EmailsCompanion.insert(
      id: emailId,
      subject: Value(subject),
      isSeen: Value(seen),
    );
    await _db.into(_db.emails).insertOnConflictUpdate(upsert);
  }
}
EOF

expect fail 'snoozedUntil in a one-line EmailsCompanion' \
  "$repo/user_actions.dart" 'read/star/snooze' <<'EOF'
extension _UserActions on EmailRepositoryImpl {
  Future<void> _applyLocalSnooze(Email row) async {
    await (_db.update(_db.emails)..where((t) => t.id.equals(row.id)))
        .write(EmailsCompanion(mailboxPath: Value(p), snoozedUntil: Value(u)));
  }
}
EOF

expect fail 'srvIsFlagged given a Value outside a companion literal' \
  "$repo/sync_jmap.dart" 'read/star/snooze' <<'EOF'
extension _SyncJmap on EmailRepositoryImpl {
  Future<void> _upsertJmapEmails() async {
    final c = base.copyWith(srvIsFlagged: const Value(true));
    await _db.into(_db.emails).insertOnConflictUpdate(c);
  }
}
EOF

expect fail 'raw UPDATE emails SET is_seen' \
  "$repo/flush_imap.dart" 'read/star/snooze' <<'EOF'
extension _FlushImap on EmailRepositoryImpl {
  Future<void> _x() => _db.customUpdate(
        "UPDATE emails SET is_seen = 1 WHERE id = ?1",
      );
}
EOF

expect fail 'local_is_flagged in a SET list split over string literals' \
  "$repo/sync_imap.dart" 'read/star/snooze' <<'EOF'
extension _SyncImap on EmailRepositoryImpl {
  Future<void> _fetchAndUpsertImapGuarded() => _db.customUpdate(
        'UPDATE emails SET subject = ?1, '
        'local_is_flagged = NULL '
        'WHERE id = ?2',
      );
}
EOF

expect fail 'snoozed_until in the column list of an INSERT INTO emails' \
  "$repo/sync_jmap.dart" 'read/star/snooze' <<'EOF'
extension _SyncJmap on EmailRepositoryImpl {
  Future<void> _upsertJmapEmails() => _db.customStatement(
        'INSERT INTO emails (id, account_id, snoozed_until) VALUES (?, ?, ?)',
      );
}
EOF

expect fail 'the opt-out comment does not cover check 1' \
  "$repo/sync_jmap.dart" 'read/star/snooze' <<'EOF'
extension _SyncJmap on EmailRepositoryImpl {
  Future<void> _upsertJmapEmails() => _db.customUpdate(
        'UPDATE emails SET is_flagged = 0', // not an emails write
      );
}
EOF

expect fail 'a whole-row toCompanion write in an allowed member' \
  "$repo/sync_jmap.dart" 'read/star/snooze' <<'EOF'
extension _SyncJmap on EmailRepositoryImpl {
  Future<void> _upsertJmapEmails(Email row) async {
    await (_db.update(_db.emails)..where((t) => t.id.equals(row.id)))
        .write(row.toCompanion(false)); // not an emails write
  }
}
EOF

# ── Check 2: any emails write outside the allow-list ───────────────────────
expect fail 'delete of emails in a member not on the allow-list' \
  "$repo/queries.dart" 'emails is written only' <<'EOF'
extension _Queries on EmailRepositoryImpl {
  Future<void> _purge(String id) async {
    await (_db.delete(_db.emails)..where((t) => t.id.equals(id))).go();
  }
}
EOF

expect fail 'a batch update split over two lines' "$repo/queries.dart" 'emails is written only' <<'EOF'
extension _Queries on EmailRepositoryImpl {
  Future<void> _sizes() => _db.batch((b) {
        b.update(
          _db.emails,
          const EmailsCompanion(),
        );
      });
}
EOF

expect fail 'a whole-row toCompanion write' "$repo/row_identity.dart" 'emails is written only' <<'EOF'
extension _RowIdentity on EmailRepositoryImpl {
  Future<void> _carryOverMovedRow(Email dup) async {
    await (_db.update(_db.emails)..where((t) => t.id.equals(keep)))
        .write(dup.toCompanion(false).copyWith(id: const Value.absent()));
  }
}
EOF

expect fail 'the table manager form' "$repo/queries.dart" 'emails is written only' <<'EOF'
extension _Queries on EmailRepositoryImpl {
  Future<void> _x() => _db.emails.deleteWhere((t) => t.id.equals(id));
}
EOF

expect fail 'raw DELETE FROM emails' "data/repositories/note_repository_impl.dart" 'emails is written only' <<'EOF'
class NoteRepositoryImpl {
  Future<void> purge() => _db.customStatement('DELETE FROM emails');
}
EOF

expect fail 'a top-level function not on the allow-list' \
  "data/repositories/mailbox_repository_impl.dart" 'emails is written only' <<'EOF'
Future<void> purgeFolder(AppDatabase db) async {
  await (db.delete(db.emails)..where((t) => t.mailboxPath.equals(p))).go();
}
EOF

expect fail 'a stale allow-list entry (the member lost its write)' \
  "$repo/sync_jmap.dart" 'match no' <<'EOF'
extension _SyncJmap on EmailRepositoryImpl {
  Future<void> _upsertJmapEmails() async {
    await _state.deleteRow(row.id);
  }
}
EOF

# ── Review round: SQL spellings, aliases, data rows, member tracking ───────
expect fail 'lower-case SQL: update emails set is_seen' \
  "$repo/flush_imap.dart" 'read/star/snooze' <<'EOF'
extension _FlushImap on EmailRepositoryImpl {
  Future<void> _x() => _db.customStatement(
        'update emails set is_seen = 1 where id = ?',
      );
}
EOF

expect fail 'UPDATE OR IGNORE emails SET is_flagged' \
  "$repo/flush_imap.dart" 'read/star/snooze' <<'EOF'
extension _FlushImap on EmailRepositoryImpl {
  Future<void> _x() => _db.customStatement(
        'UPDATE OR IGNORE emails SET is_flagged = 1 WHERE id = ?',
      );
}
EOF

expect fail 'an interpolated table name' \
  "$repo/flush_imap.dart" 'read/star/snooze' <<'EOF'
extension _FlushImap on EmailRepositoryImpl {
  Future<void> _x() => _db.customStatement(
        'UPDATE ${_db.emails.actualTableName} SET snoozed_until = NULL',
      );
}
EOF

expect fail 'a quoted column name' "$repo/flush_imap.dart" 'read/star/snooze' <<'EOF'
extension _FlushImap on EmailRepositoryImpl {
  Future<void> _x() => _db.customStatement(
        'UPDATE emails SET "is_seen" = 1',
      );
}
EOF

expect fail 'INSERT INTO emails SELECT without a column list' \
  "$repo/flush_imap.dart" 'read/star/snooze' <<'EOF'
extension _FlushImap on EmailRepositoryImpl {
  Future<void> _x() => _db.customStatement(
        'INSERT INTO emails SELECT * FROM old_emails',
      );
}
EOF

expect fail 'EmailsCompanion.custom naming an overlay column' \
  "$repo/sync_jmap.dart" 'read/star/snooze' <<'EOF'
extension _SyncJmap on EmailRepositoryImpl {
  Future<void> _upsertJmapEmails() async {
    await (_db.update(_db.emails)..where((t) => t.id.equals(row.id))).write(
      EmailsCompanion.custom(isSeen: const Constant(true)),
    );
  }
}
EOF

expect fail 'copyWith naming an overlay column in an allowed member' \
  "$repo/sync_imap.dart" 'read/star/snooze' <<'EOF'
extension _SyncImap on EmailRepositoryImpl {
  Future<void> _fetchAndUpsertImapGuarded() async {
    final upsert = EmailsCompanion.insert(id: emailId);
    final again = upsert.copyWith(isFlagged: Value(true));
    await _db.into(_db.emails).insertOnConflictUpdate(again);
  }
}
EOF

expect fail 'an Email data row inserted in an allowed member' \
  "$repo/sync_imap.dart" 'read/star/snooze' <<'EOF'
extension _SyncImap on EmailRepositoryImpl {
  Future<void> _fetchAndUpsertImapGuarded(Email row) async {
    await _db.into(_db.emails).insertOnConflictUpdate(
          row,
        );
  }
}
EOF

expect fail 'an Email data row written by update(…).write' \
  "$repo/sync_jmap.dart" 'read/star/snooze' <<'EOF'
extension _SyncJmap on EmailRepositoryImpl {
  Future<void> _upsertJmapEmails(Email row) async {
    await (_db.update(_db.emails)..where((t) => t.id.equals(row.id)))
        .write(row.copyWith(subject: s));
  }
}
EOF

expect fail 'lower-case delete from emails' \
  "$repo/queries.dart" 'emails is written only' <<'EOF'
extension _Queries on EmailRepositoryImpl {
  Future<void> _x() => _db.customStatement('delete from emails where id = ?');
}
EOF

expect fail 'an interpolated DELETE FROM' \
  "$repo/queries.dart" 'emails is written only' <<'EOF'
extension _Queries on EmailRepositoryImpl {
  Future<void> _x() =>
      _db.customStatement('DELETE FROM ${_db.emails.actualTableName}');
}
EOF

expect fail 'the managers table manager' \
  "$repo/queries.dart" 'emails is written only' <<'EOF'
extension _Queries on EmailRepositoryImpl {
  Future<void> _x() => _db.managers.emails
      .filter((f) => f.id(id))
      .update((o) => o(subject: const Value('x')));
}
EOF

expect fail 'updates: naming emails' \
  "$repo/queries.dart" 'emails is written only' <<'EOF'
extension _Queries on EmailRepositoryImpl {
  Future<void> _x() => _db.customUpdate(sql, updates: {_db.emails});
}
EOF

expect fail 'an alias of the table' \
  "$repo/queries.dart" 'emails is written only' <<'EOF'
extension _Queries on EmailRepositoryImpl {
  Future<void> _x() async {
    final t = _db.emails;
    await (_db.delete(t)..where((r) => r.id.equals(id))).go();
  }
}
EOF

expect fail 'a getter after an allowed member does not borrow its name' \
  "$repo/sync_jmap.dart" 'emails is written only' <<'EOF'
extension _SyncJmap on EmailRepositoryImpl {
  Future<void> _upsertJmapEmails() async {
    await (_db.update(_db.emails)..where((t) => t.id.equals(row.id))).write(
      EmailsCompanion(subject: Value(s)),
    );
  }

  Future<int> get _purge => (_db.delete(_db.emails)).go();
}
EOF

expect fail 'a field after an allowed member does not borrow its name' \
  "$repo/sync_jmap.dart" 'emails is written only' <<'EOF'
class SyncJmap {
  Future<void> _upsertJmapEmails() async {
    await (_db.update(_db.emails)..where((t) => t.id.equals(row.id))).write(
      EmailsCompanion(subject: Value(s)),
    );
  }

  late final _purge = _db.delete(_db.emails);
}
EOF

expect fail 'a signature over two lines after an allowed member' \
  "$repo/sync_jmap.dart" 'emails is written only' <<'EOF'
extension _SyncJmap on EmailRepositoryImpl {
  Future<void> _upsertJmapEmails() async {
    await (_db.update(_db.emails)..where((t) => t.id.equals(row.id))).write(
      EmailsCompanion(subject: Value(s)),
    );
  }

  Future<Map<String, int>>
      _purge(String id) async {
    await (_db.delete(_db.emails)..where((t) => t.id.equals(id))).go();
    return {};
  }
}
EOF

expect fail 'an annotated member after an allowed member' \
  "$repo/sync_jmap.dart" 'emails is written only' <<'EOF'
class SyncJmap {
  Future<void> _upsertJmapEmails() async {
    await (_db.update(_db.emails)..where((t) => t.id.equals(row.id))).write(
      EmailsCompanion(subject: Value(s)),
    );
  }

  @visibleForTesting
  Future<void> purge() => _db.customStatement('DELETE FROM emails');
}
EOF

expect fail 'a write in database.dart outside the migrations' \
  "data/db/database.dart" 'emails is written only' <<'EOF'
class AppDatabase {
  Future<void> _upgradeSteps(Migrator m, int from) async {
    await customStatement('UPDATE emails SET is_seen = 0');
  }

  Future<void> wipe() => customStatement('DELETE FROM emails');
}
EOF

expect pass 'migrations in database.dart' "data/db/database.dart" <<'EOF'
class AppDatabase {
  Future<void> _overlayKeywords() async {
    await customStatement('UPDATE emails SET srv_is_seen = is_seen');
  }
}
EOF

expect pass 'reads through the table, prose in comments' \
  "$repo/queries.dart" <<'EOF'
extension _Queries on EmailRepositoryImpl {
  // We never delete from emails here; update emails set is_seen is the
  // writer's business.
  Future<void> _reads() async {
    final row = await (_db.select(
      _db.emails,
    )..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    final q = _db.select(_db.threads).join([
      leftOuterJoin(
        _db.emails,
        _db.emails.id.equalsExp(_db.threads.latestEmailId),
      ),
    ]);
    await _db.customSelect('SELECT 1', readsFrom: {_db.emails}).get();
    final e = q.readTableOrNull(_db.emails);
  }
}
EOF

expect pass 'companion variables, conditional rows, a thread copyWith' \
  "$repo/sync_imap.dart" <<'EOF'
extension _SyncImap on EmailRepositoryImpl {
  Future<void> _fetchAndUpsertImapGuarded() async {
    final headers = EmailsCompanion(
      uid: Value(uid),
      subject: Value(subject),
      snoozedFromMailboxPath: Value(p),
    );
    await _db.into(_db.emails).insert(
          isNew
              ? EmailStateWriter.newRow(
                  headers,
                  id: emailId,
                  mailboxPath: mailboxPath,
                  keywords: keywords,
                  seq: read.seq,
                )
              : EmailStateWriter.withServerLocation(headers, p, seq: 0),
        );
    await (_db.update(_db.emails)..where((t) => t.id.equals(emailId)))
        .write(headers);
    final t = ThreadsCompanion(id: Value(id)).copyWith(isFlagged: Value(f));
    final u = ThreadsCompanion(mailboxPath: Value(p));
  }
}
EOF

expect pass 'the shown folder of a new row, in an EmailsCompanion.insert' \
  "$repo/sync_jmap.dart" <<'EOF'
extension _SyncJmap on EmailRepositoryImpl {
  Future<void> _upsertJmapEmails() async {
    final row = EmailStateWriter.withServerLocation(
      EmailsCompanion.insert(
        id: emailId,
        accountId: accountId,
        mailboxPath: mailboxPath,
        uid: 0,
        receivedAt: now,
      ),
      mailboxPath,
      seq: 0,
    );
    await _db.into(_db.emails).insert(row);
  }
}
EOF

# ── Phase 4b: local rows are written by the state writer ───────────────────
expect fail 'an emails insert in local_rows.dart (no longer allowed)' \
  "$repo/local_rows.dart" 'emails is written only' <<'EOF'
extension _LocalRows on EmailRepositoryImpl {
  Future<void> _createLocalSelfMessages() async {
    await _db.into(_db.emails).insert(EmailStateWriter.newRow(c));
  }
}
EOF

expect fail 'an EmailsCompanion for a Sent copy in local_rows.dart' \
  "$repo/local_rows.dart" 'emails is written only' <<'EOF'
extension _LocalRows on EmailRepositoryImpl {
  Future<void> _storeSentCopyLocally() async {
    final copy = EmailsCompanion(subject: Value(draft.subject));
    await _state.writeLocalRowHeaders(emailId, copy);
  }
}
EOF

expect pass 'local rows through insertLocalRow and LocalRowHeaders' \
  "$repo/local_rows.dart" <<'EOF'
extension _LocalRows on EmailRepositoryImpl {
  Future<void> _storeSentCopyLocally() async {
    final copy = LocalRowHeaders(subject: draft.subject, isLocal: isLocal);
    if (known == null) {
      await _state.insertLocalRow(
        copy,
        id: emailId,
        accountId: accountId,
        mailboxPath: mailboxPath,
        keywords: _ownMailKeywords,
      );
    } else {
      await _state.writeLocalRowHeaders(emailId, copy);
    }
    final rows = await (_db.select(_db.emails)
          ..where((t) => t.isLocal.equals(true)))
        .get();
  }
}
EOF

# ── Check 1 for the location overlay (phase 4a) ─────────────────────────────
expect fail 'mailboxPath in an EmailsCompanion, even in an allowed member' \
  "$repo/sync_jmap.dart" 'read/star/snooze' <<'EOF'
extension _SyncJmap on EmailRepositoryImpl {
  Future<void> _upsertJmapEmails() async {
    await (_db.update(_db.emails)..where((t) => t.id.equals(row.id))).write(
      EmailsCompanion(mailboxPath: Value(destPath)),
    );
  }
}
EOF

expect fail 'srvMailboxPath given a Value' \
  "$repo/row_identity.dart" 'read/star/snooze' <<'EOF'
extension _RowIdentity on EmailRepositoryImpl {
  Future<void> _x() async {
    final c = EmailsCompanion.insert(
      id: id,
      mailboxPath: p,
      srvMailboxPath: Value(p),
    );
  }
}
EOF

expect fail 'localHidden in a copyWith of an allowed member' \
  "$repo/sync_jmap.dart" 'read/star/snooze' <<'EOF'
extension _SyncJmap on EmailRepositoryImpl {
  Future<void> _upsertJmapEmails() async {
    final c = headers.copyWith(localHidden: const Value(false));
    await _db.into(_db.emails).insert(EmailStateWriter.newRow(c));
  }
}
EOF

expect fail 'raw UPDATE emails SET mailbox_path' \
  "$repo/flush_jmap.dart" 'read/star/snooze' <<'EOF'
extension _FlushJmap on EmailRepositoryImpl {
  Future<void> _x() => _db.customUpdate(
        'UPDATE emails SET mailbox_path = ?1 WHERE mailbox_path = ?2',
      );
}
EOF

expect fail 'srv_gone in a SET list over string literals' \
  "$repo/sync_imap.dart" 'read/star/snooze' <<'EOF'
extension _SyncImap on EmailRepositoryImpl {
  Future<void> _x() => _db.customUpdate(
        'UPDATE emails SET preview = ?1, '
        'srv_gone = 1 WHERE id = ?2',
      );
}
EOF

expect fail 'an upsert of an EmailsCompanion.insert in an allowed member' \
  "$repo/sync_imap.dart" 'read/star/snooze' <<'EOF'
extension _SyncImap on EmailRepositoryImpl {
  Future<void> _fetchAndUpsertImapGuarded() async {
    final upsert = EmailsCompanion.insert(
      id: emailId,
      mailboxPath: mailboxPath,
    );
    await _db.into(_db.emails).insertOnConflictUpdate(upsert);
  }
}
EOF

expect fail 'withServerKeywords alone does not place a new row' \
  "$repo/sync_jmap.dart" 'read/star/snooze' <<'EOF'
extension _SyncJmap on EmailRepositoryImpl {
  Future<void> _upsertJmapEmails() async {
    await _db.into(_db.emails).insert(
          EmailStateWriter.withServerKeywords(row, keywords, seq: 0),
        );
  }
}
EOF

# ── Review round 2: upserts of new rows, split SQL, the pre-filter ─────────
expect fail 'an upsert of newRow in an allowed member' \
  "$repo/sync_imap.dart" 'read/star/snooze' <<'EOF'
extension _SyncImap on EmailRepositoryImpl {
  Future<void> _fetchAndUpsertImapGuarded() async {
    await _db.into(_db.emails).insertOnConflictUpdate(
          EmailStateWriter.newRow(headers, id: id, seq: read.seq),
        );
  }
}
EOF

expect fail 'newRow inserted with mode: insertOrReplace' \
  "$repo/sync_imap.dart" 'read/star/snooze' <<'EOF'
extension _SyncImap on EmailRepositoryImpl {
  Future<void> _fetchAndUpsertImapGuarded() async {
    await _db.into(_db.emails).insert(
          EmailStateWriter.newRow(headers, id: id, seq: read.seq),
          mode: InsertMode.insertOrReplace,
        );
  }
}
EOF

expect fail 'a newRow variable written over an existing row' \
  "$repo/sync_imap.dart" 'read/star/snooze' <<'EOF'
extension _SyncImap on EmailRepositoryImpl {
  Future<void> _fetchAndUpsertImapGuarded() async {
    final row = EmailStateWriter.newRow(headers, id: id, seq: read.seq);
    await (_db.update(_db.emails)..where((t) => t.id.equals(id))).write(row);
  }
}
EOF

expect fail 'UPDATE emails split over adjacent literals on one line' \
  "$repo/sync_imap.dart" 'read/star/snooze' <<'EOF'
extension _SyncImap on EmailRepositoryImpl {
  Future<void> _fetchAndUpsertImapGuarded() => _db.customUpdate(
        'UPDATE ' + 'emails SET mailbox_path = ?1 WHERE id = ?2',
      );
}
EOF

expect fail 'UPDATE emails split over literals on two lines' \
  "$repo/sync_imap.dart" 'read/star/snooze' <<'EOF'
extension _SyncImap on EmailRepositoryImpl {
  Future<void> _fetchAndUpsertImapGuarded() => _db.customUpdate(
        'UPDATE '
        'emails SET local_hidden = 1 WHERE id = ?2',
      );
}
EOF

expect fail 'a location column given a Value in a file not naming the table' \
  "core/models/thing.dart" 'read/star/snooze' <<'EOF'
final c = SomeCompanion(srvGone: const Value(true));
EOF

# ── Near-misses that must pass ──────────────────────────────────────────────

expect pass 'reads, other tables and models' "$repo/queries.dart" <<'EOF'
extension _Queries on EmailRepositoryImpl {
  Future<void> _reads() async {
    final rows = await (_db.select(_db.emails)
          ..where((t) => t.isSeen.equals(false)))
        .get();
    await _db.customSelect(
      'SELECT id FROM emails WHERE is_seen = 0 AND snoozed_until IS NULL',
    ).get();
    await (_db.update(_db.threads)..where((t) => t.id.equals(id))).write(
      ThreadsCompanion(isFlagged: Value(true), hasUnread: Value(false)),
    );
    await _db.customUpdate(
      'UPDATE threads SET is_flagged = 1, snoozed_until = NULL',
    );
    await _db.into(_db.notifiedEmails).insert(NotifiedEmailsCompanion.insert(
          emailId: id,
        ));
    final email = model.Email(isSeen: true, isFlagged: false);
    final copy = email.copyWith(isSeen: false, snoozedUntil: null);
    await _db.customUpdate(
      'UPDATE emails_fts SET subject = ?1',
    );
  }
}
EOF

expect pass 'Value.absent() for an overlay column' \
  "$repo/sync_imap.dart" <<'EOF'
extension _SyncImap on EmailRepositoryImpl {
  Future<void> _fetchAndUpsertImapGuarded() async {
    final headers = EmailsCompanion(
      subject: Value(subject),
      isSeen: const Value.absent(),
      mailboxPath: const Value.absent(),
    );
    await (_db.update(_db.emails)..where((t) => t.id.equals(id)))
        .write(headers);
  }
}
EOF

expect pass "another table's toCompanion, opted out" "$repo/queries.dart" <<'EOF'
extension _Queries on EmailRepositoryImpl {
  Future<void> _x() async {
    final m = mailbox.toCompanion(false); // not an emails write
  }
}
EOF

expect pass 'an UPDATE emails SET list that only reads overlay columns' \
  "$repo/sync_imap.dart" <<'EOF'
extension _SyncImap on EmailRepositoryImpl {
  Future<void> _fetchAndUpsertImapGuarded() => _db.customUpdate(
        'UPDATE emails SET preview = ?1 '
        'WHERE id = ?2 AND is_seen = 0 AND local_is_flagged IS NULL',
      );
}
EOF

expect pass 'the email state writer and migrations' \
  "data/repositories/email_state_writer.dart" <<'EOF'
class EmailStateWriter {
  Future<void> x() => _db.customUpdate('UPDATE emails SET is_seen = 1');
}
EOF

# ── Check 3: mailboxes ──────────────────────────────────────────────────────
expect fail 'a MailboxesCompanion outside the mailbox state writer' \
  data/repositories/mailbox_repository_impl.dart 'mailboxes is written' <<'EOF'
class MailboxRepositoryImpl {
  Future<void> _x() => _db.into(_db.mailboxes).insert(
        MailboxesCompanion.insert(id: id, accountId: a, path: p, name: n),
      );
}
EOF

expect fail 'a Drift delete of mailboxes, the table on the next line' \
  data/repositories/mailbox_repository_impl.dart 'mailboxes is written' <<'EOF'
class MailboxRepositoryImpl {
  Future<void> clearForResync(String accountId) async {
    await (_db.delete(
      _db.mailboxes,
    )..where((t) => t.accountId.equals(accountId)))
        .go();
  }
}
EOF

expect fail 'raw SQL split over string literals, any case' \
  "$repo/flush_jmap.dart" 'mailboxes is written' <<'EOF'
extension _FlushJmap on EmailRepositoryImpl {
  Future<void> _x() => _db.customUpdate(
        'update '
        'mailboxes set name = ?1 WHERE id = ?2',
      );
}
EOF

expect fail 'a mailboxes write in database.dart outside the migrations' \
  data/db/database.dart 'mailboxes is written' <<'EOF'
class AppDatabase {
  Future<void> _overlayMailboxes() async {
    await customStatement('UPDATE mailboxes SET srv_name = name');
  }

  Future<void> renameEverything() async {
    await customStatement('UPDATE mailboxes SET name = path');
  }
}
EOF

expect fail "the table's own deleteWhere" \
  data/repositories/mailbox_repository_impl.dart 'mailboxes is written' <<'EOF'
class MailboxRepositoryImpl {
  Future<void> x() => _db.mailboxes.deleteWhere((t) => t.id.equals(id));
}
EOF

expect fail "the table's own insertOne" \
  data/repositories/mailbox_repository_impl.dart 'mailboxes is written' <<'EOF'
class MailboxRepositoryImpl {
  Future<void> x() => _db.mailboxes.insertOne(row);
}
EOF

expect fail 'an update behind this._db.' \
  data/repositories/mailbox_repository_impl.dart 'mailboxes is written' <<'EOF'
class MailboxRepositoryImpl {
  Future<void> x() => (update(this._db.mailboxes)..where((t) => t.id.equals(i)))
      .write(row);
}
EOF

expect pass 'a read through the table getter' \
  data/repositories/mailbox_repository_impl.dart <<'EOF'
class MailboxRepositoryImpl {
  MailboxRow x(QueryRow r) => _db.mailboxes.map(r.data);
}
EOF

expect pass 'mailbox writes in the mailbox state writer' \
  data/repositories/mailbox_state_writer.dart <<'EOF'
class MailboxStateWriter {
  Future<void> x() => _db.customUpdate('UPDATE mailboxes SET name = ?1');
  Future<void> y() => _db.into(_db.mailboxes).insert(MailboxesCompanion());
}
EOF

expect pass 'the migrations of database.dart' data/db/database.dart <<'EOF'
class AppDatabase {
  Future<void> _upgradeSteps(Migrator m, int from) async {
    await customStatement('UPDATE mailboxes SET display_path = path');
  }

  Future<void> _overlayMailboxes() async {
    await customStatement('UPDATE mailboxes SET srv_name = name');
    await customStatement('INSERT OR IGNORE INTO mailboxes (id) VALUES (1)');
  }
}
EOF

expect pass 'the v76 Snoozed create of the migrations' data/db/database.dart <<'EOF'
class AppDatabase {
  Future<void> _queueSnoozedCreates(String accountType) async {
    await customStatement(
      'INSERT INTO mailboxes (id, account_id, path, name, '
      "role, display_path, local_name, is_local) VALUES (?1, ?2, 'Snoozed', "
      "'Snoozed', 'snoozed', 'Snoozed', 'Snoozed', 1)",
      [id, accountId],
    );
  }
}
EOF

expect fail 'the folder overlay (local_hidden) written outside the writer' \
  data/repositories/mailbox_repository_impl.dart 'mailboxes is written' <<'EOF'
class MailboxRepositoryImpl {
  Future<void> hide(String id) => _db.customUpdate(
        'UPDATE mailboxes SET local_hidden = 1 WHERE id = ?1',
      );
}
EOF

expect fail 'a parent overlay written by the flush' \
  "$repo/flush_mailbox.dart" 'mailboxes is written' <<'EOF'
extension _FlushMailbox on EmailRepositoryImpl {
  Future<void> x() => (_db.update(_db.mailboxes)..where((t) => t.id.equals(i)))
      .write(MailboxesCompanion(parentId: Value(p)));
}
EOF

expect pass 'reads of mailboxes and the sync_log_mailboxes table' \
  data/repositories/sync_log_repository_impl.dart <<'EOF'
class SyncLogRepositoryImpl {
  Stream<void> x() => _db.customSelect(
        'SELECT * FROM mailboxes m',
        readsFrom: {_db.mailboxes, _db.pendingChanges},
      ).watch();
  Future<void> y() => _db.into(_db.syncLogMailboxes).insert(
        SyncLogMailboxesCompanion.insert(syncLogId: 1, mailboxPath: 'x'),
      );
  Future<void> z() => _db.customStatement(
        'DELETE FROM sync_log_mailboxes WHERE sync_log_id = 1',
      );
  // UPDATE mailboxes in a comment is prose.
}
EOF

# ── The real allow-list (empty since phase 6a) ─────────────────────────────
unset EMAIL_WRITES_ALLOWED

expect fail 'an emails insert in the IMAP fetch (no longer allowed)' \
  "$repo/sync_imap.dart" 'emails is written only' <<'EOF'
extension _SyncImap on EmailRepositoryImpl {
  Future<void> _fetchAndUpsertImapGuarded() async {
    await _db.into(_db.emails).insert(
          EmailStateWriter.newRow(headers, id: id, seq: read.seq),
        );
  }
}
EOF

expect fail 'a header update in the JMAP upsert (no longer allowed)' \
  "$repo/sync_jmap.dart" 'emails is written only' <<'EOF'
extension _SyncJmap on EmailRepositoryImpl {
  Future<void> _upsertJmapEmails() async {
    await (_db.update(_db.emails)..where((t) => t.id.equals(dbId)))
        .write(EmailsCompanion(subject: Value(subject)));
  }
}
EOF

expect fail "an EmailsCompanion in Undo's restore (no longer allowed)" \
  "$repo/user_actions.dart" 'emails is written only' <<'EOF'
extension _UserActions on EmailRepositoryImpl {
  Future<void> _restoreEmail(model.Email e) async {
    final restored = EmailsCompanion(subject: Value(e.subject));
    await _state.insertServerRow(restored, id: e.id, seq: 0);
  }
}
EOF

expect pass 'the three members writing through the writer' \
  "$repo/sync_jmap.dart" <<'EOF'
extension _SyncJmap on EmailRepositoryImpl {
  Future<void> _upsertJmapEmails() async {
    final existing = await (_db.select(_db.emails)
          ..where((t) => t.srvJmapId.equals(jmapId)))
        .getSingleOrNull();
    final headers = ServerRowHeaders(uid: 0, subject: subject);
    if (existing == null) {
      await _state.insertServerRow(headers, id: dbId, seq: read.seq);
      return;
    }
    await _state.writeServerHeaders(dbId, headers);
  }
}
EOF

echo "check_email_writes.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
