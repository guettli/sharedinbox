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
  "$repo/local_rows.dart" 'read/star/snooze' <<'EOF'
extension _LocalRows on EmailRepositoryImpl {
  Future<void> _storeSentCopyLocally() => _db.customStatement(
        'INSERT INTO emails (id, account_id, snoozed_until) VALUES (?, ?, ?)',
      );
}
EOF

expect fail 'the opt-out comment does not cover check 1' \
  "$repo/sieve.dart" 'read/star/snooze' <<'EOF'
extension _Sieve on EmailRepositoryImpl {
  Future<void> _enqueueSieveMove() => _db.customUpdate(
        'UPDATE emails SET is_flagged = 0', // not an emails write
      );
}
EOF

expect fail 'a whole-row toCompanion write in an allowed member' \
  "$repo/sieve.dart" 'read/star/snooze' <<'EOF'
extension _Sieve on EmailRepositoryImpl {
  Future<void> _enqueueSieveMove(Email row) async {
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
  "$repo/sieve.dart" 'match no' <<'EOF'
extension _Sieve on EmailRepositoryImpl {
  Future<void> _enqueueSieveMove() async {
    await _state.deleteRow(row.id);
  }
}
EOF

# ── Near-misses that must pass ──────────────────────────────────────────────
expect pass 'allowed member writing a location column' \
  "$repo/sieve.dart" <<'EOF'
extension _Sieve on EmailRepositoryImpl {
  Future<void> _enqueueSieveMove() async {
    await (_db.update(_db.emails)..where((t) => t.id.equals(row.id))).write(
      EmailsCompanion(mailboxPath: Value(destPath)),
    );
  }
}
EOF

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
    final upsert = EmailsCompanion.insert(
      id: emailId,
      isSeen: const Value.absent(),
    );
    await _db.into(_db.emails).insertOnConflictUpdate(upsert);
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

echo "check_email_writes.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
