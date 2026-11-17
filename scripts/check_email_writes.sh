#!/usr/bin/env bash
# Who may write the `emails` table (SYNC-REDESIGN.md §2 and §8
# "Enforcement", SYNC.md "Email state writer").
#
# Two checks over lib/ (generated *.g.dart files skipped):
#
# 1. The keyword overlay columns — is_seen, is_flagged, snoozed_until, their
#    srv_/local_ pairs and srv_keywords_seq — are written only by the email
#    state writer (lib/data/repositories/email_state_writer.dart) and the
#    schema migrations (lib/data/db/database.dart). No allow-list. It fails on
#      - one of them named in an `EmailsCompanion(…)` /
#        `EmailsCompanion.insert(…)` (also across lines), unless
#        `const Value.absent()`;
#      - srvIsSeen/srvIsFlagged/srvSnoozedUntil/srvKeywordsSeq/localIsSeen/
#        localIsFlagged/localSnoozedUntil given a `Value(…)` anywhere (only
#        emails rows have these names);
#      - SQL `UPDATE emails … SET <column> =` (the SET list up to WHERE, also
#        across string literals and lines) and `INSERT … INTO emails (…)`
#        with one of them in the column list;
#      - a whole-row `.toCompanion(` in a member on the allow-list of check 2
#        (elsewhere check 2 fails on it).
#
# 2. Every other write of `emails` — `EmailsCompanion`, `.toCompanion(` (a
#    whole row), Drift's update/into/delete/insert/replace on `emails` (also
#    in a batch, also across lines), the table manager's
#    `emails.insert…/update/delete…/replace`, and raw `UPDATE emails`,
#    `INSERT … INTO emails`, `DELETE FROM emails`, `REPLACE INTO emails` —
#    appears only in the email state writer, the migrations, or a member
#    on the allow-list below. A line that only looks like one (another
#    table's `toCompanion`, say) can opt out with `// not an emails write`;
#    check 1 has no opt-out.
#
# The allow-list names a file and the member (method or top-level function)
# holding the write, with the reason it is not in the state writer yet and
# the phase that moves it there. A new write in an allowed member passes
# check 2 (check 1 still applies); a write in any other member fails.
#
# Usage: scripts/check_email_writes.sh [dir]   (default: lib)
set -euo pipefail

dir="${1:-lib}"

# file (relative to the parent of [dir]'s lib/) | member | reason
allowed='
# Row inserts and upserts of server headers. The keyword columns come only
# from EmailStateWriter.withServerKeywords (check 1). Phase 4 gives the
# server-write gate an insert form for the location group too.
lib/data/repositories/email_repository_impl/sync_imap.dart|_fetchAndUpsertImapGuarded|IMAP new-mail upsert (phase 4)
lib/data/repositories/email_repository_impl/sync_jmap.dart|_upsertJmapEmails|JMAP upsert (phase 4)
lib/data/repositories/email_repository_impl/local_rows.dart|_storeSentCopyLocally|virtual Sent copy, create_local (phase 4)
lib/data/repositories/email_repository_impl/local_rows.dart|_createLocalSelfMessages|virtual self-send rows, create_local (phase 4)
lib/data/repositories/email_repository_impl/user_actions.dart|_restoreEmail|Undo brings a gone row back (phase 4: a hidden row is never gone)
# Optimistic location writes (mailbox_path) and the local-only
# snoozed_from_mailbox_path. Phase 4 overlays location: local_mailbox_path
# comes from the fold, and these become ops.
lib/data/repositories/email_repository_impl/user_actions.dart|_applyLocalMove|optimistic move (phase 4)
lib/data/repositories/email_repository_impl/user_actions.dart|_applyLocalSnooze|optimistic snooze (phase 4)
lib/data/repositories/email_repository_impl/user_actions.dart|_applyLocalUnsnooze|optimistic unsnooze (phase 4)
lib/data/repositories/email_repository_impl/user_actions.dart|_wakeUpEmails|snoozed_from_mailbox_path, local-only (phase 4)
lib/data/repositories/email_repository_impl/user_actions.dart|_restoreLocalSnooze|snoozed_from_mailbox_path, local-only (phase 4)
lib/data/repositories/email_repository_impl/change_failures.dart|_revertFailedLocation|a failed move/snooze shows the mail where it was (phase 4: the op stops folding)
lib/data/repositories/email_repository_impl/sieve.dart|_enqueueSieveMove|the local result of a Sieve fileinto (phase 4)
lib/data/repositories/email_repository_impl/flush_jmap.dart|_repointSnoozedPlaceholder|Snoozed placeholder gets its JMAP id (phase 5: rewrites op dests)
# Server location facts (srv_mailbox_path, srv_uid, srv_uid_validity,
# srv_jmap_id, uid). Phase 4 moves them behind the gate with the location
# group.
lib/data/repositories/email_repository_impl/row_identity.dart|_relocateEmailRow|a move remap or body healing learned the new UID (phase 4)
lib/data/repositories/email_repository_impl/row_identity.dart|_releaseImapLocation|another row holds the location now (phase 4)
lib/data/repositories/mailbox_repository_impl.dart|_applyImapPathRewrite|a folder rename moves shown and server paths (phase 5)
'

lines=$(grep -rlE --include='*.dart' \
  'emails|EmailsCompanion|toCompanion\(|srvIsSeen|srvIsFlagged|srvSnoozedUntil|srvKeywordsSeq|localIsSeen|localIsFlagged|localSnoozedUntil' \
  "$dir" | grep -v '\.g\.dart$' \
  | grep -v 'lib/data/db/database\.dart$' \
  | grep -v 'lib/data/repositories/email_state_writer\.dart$' || true)

overlay=""
other=""
used=""
for f in $lines; do
  out=$(awk -v allowed="$allowed" '
    BEGIN {
      n = split(allowed, rows, "\n")
      for (i = 1; i <= n; i++) {
        if (rows[i] ~ /^#/ || rows[i] == "") continue
        split(rows[i], parts, "|")
        ok[parts[1] "|" parts[2]] = 1
      }
      cols = "(srv_|local_)?(is_seen|is_flagged|snoozed_until)|srv_keywords_seq"
      names = "(isSeen|isFlagged|snoozedUntil|srvIsSeen|srvIsFlagged|srvSnoozedUntil|srvKeywordsSeq|localIsSeen|localIsFlagged|localSnoozedUntil)"
      srvLocal = "(srvIsSeen|srvIsFlagged|srvSnoozedUntil|srvKeywordsSeq|localIsSeen|localIsFlagged|localSnoozedUntil)"
    }
    function rel(path,   p) {
      p = index(path, "lib/")
      return p > 0 ? substr(path, p) : path
    }
    function report(kind, text) {
      print kind "\t" FILENAME ":" FNR ": [" (member == "" ? "-" : member) "] " text
    }
    # The member a line belongs to: a declaration at indent 0 outside a
    # type, at indent 2 inside a class/extension/mixin.
    /^(abstract |base |final |sealed |interface )*(class|extension|mixin|enum)[[:space:]]/ {
      inType = 1
    }
    /^}/ { inType = 0 }
    {
      decl = 0
      if (!inType && $0 ~ /^[A-Za-z_]/) decl = 1
      if (inType && $0 ~ /^  [A-Za-z_]/) decl = 1
      if (decl && $0 !~ /^[[:space:]]*(return|await|if|for|while|switch|throw|final|var|const|late|static final|else|case|assert|yield|@)/ \
          && match($0, /[A-Za-z_][A-Za-z0-9_]*(<[^()]*>)?\(/)) {
        name = substr($0, RSTART, RLENGTH)
        sub(/<.*$/, "", name); sub(/\($/, "", name)
        if (name != "") member = name
      }
    }
    # Drift write calls split over two lines: `b.update(` / `_db.emails,`.
    {
      line = $0
      if (prev ~ /\([[:space:]]*$/ && $0 ~ /^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*\.)?emails[[:space:]]*[,)]/) line = prev $0
      prev = $0
      optout = ($0 ~ /\/\/ not an emails write/)
    }

    # ── Check 1: the overlay columns ──────────────────────────────────────
    # Inside EmailsCompanion(…) / EmailsCompanion.insert(…).
    {
      rest = $0
      if (!inComp) {
        p = match(rest, /(^|[^A-Za-z0-9_])EmailsCompanion(\.insert)?\(/)
        if (p) {
          inComp = 1; depth = 0
          rest = substr(rest, RSTART + RLENGTH - 1)
        }
      }
      if (inComp) {
        probe = rest
        gsub(names ":[[:space:]]*const[[:space:]]+Value\\.absent\\(\\)", "", probe)
        if (probe ~ ("(^|[^A-Za-z0-9_.])" names ":")) report("overlay", $0)
        m = length(rest)
        for (i = 1; i <= m; i++) {
          c = substr(rest, i, 1)
          if (c == "(") depth++
          if (c == ")") { depth--; if (depth == 0) { inComp = 0; break } }
        }
      }
    }
    # A whole row (`row.toCompanion(…)`) written by a member allowed to
    # write emails carries every overlay column along. (Elsewhere check 2
    # fails on it.)
    $0 ~ /\.toCompanion\(/ && ((rel(FILENAME) "|" member) in ok) {
      report("overlay", $0)
    }
    # The srv_/local_ names exist only on emails rows.
    $0 ~ ("(^|[^A-Za-z0-9_.])" srvLocal ":[[:space:]]*(const[[:space:]]+)?Value(<[^>]*>)?\\(") {
      report("overlay", $0)
    }
    # SQL: the SET list of an UPDATE emails, the column list of an INSERT.
    {
      sql = $0
      # String literals split over lines read as one.
      gsub(/'"'"'[[:space:]]*$/, "", sql); gsub(/^[[:space:]]*'"'"'/, " ", sql)
      if (!inSet && !inIns) {
        if (match(sql, /UPDATE[[:space:]]+emails([^A-Za-z0-9_]|$)/)) {
          inSet = 1; setText = ""; setStart = FNR; setLine = $0
          sql = substr(sql, RSTART + RLENGTH)
        } else if (match(sql, /INTO[[:space:]]+emails([^A-Za-z0-9_]|$)/)) {
          inIns = 1; setText = ""; setStart = FNR; setLine = $0
          sql = substr(sql, RSTART + RLENGTH)
        }
      }
      if (inSet || inIns) {
        stop = 0
        if (inSet && match(sql, /WHERE|RETURNING|;/)) { sql = substr(sql, 1, RSTART - 1); stop = 1 }
        if (inIns && match(sql, /\)|VALUES|SELECT/)) { sql = substr(sql, 1, RSTART - 1); stop = 1 }
        setText = setText " " sql
        if (FNR - setStart >= 12) stop = 1
        if (stop) {
          hit = inSet ? (setText ~ ("(^|[^A-Za-z0-9_])(" cols ")[[:space:]]*=")) \
                      : (setText ~ ("(^|[^A-Za-z0-9_])(" cols ")([^A-Za-z0-9_]|$)"))
          if (hit) print "overlay\t" FILENAME ":" setStart ": [" (member == "" ? "-" : member) "] " setLine
          inSet = 0; inIns = 0
        }
      }
    }

    # ── Check 2: any write of emails ──────────────────────────────────────
    {
      w = 0
      if (line ~ /(^|[^A-Za-z0-9_])EmailsCompanion([^A-Za-z0-9_]|$)/) w = 1
      if (line ~ /\.toCompanion\(/) w = 1
      if (line ~ /(update|into|delete|insert|insertAll|insertOnConflictUpdate|insertAllOnConflictUpdate|replace|replaceAll|deleteWhere|deleteAll)\([[:space:]]*([A-Za-z_][A-Za-z0-9_]*\.)?emails[[:space:]]*[,)]/) w = 1
      if (line ~ /(^|[^A-Za-z0-9_])emails\.(insert|insertOne|insertOnConflictUpdate|insertAll|insertReturning|update|delete|deleteWhere|deleteAll|replace)\(/) w = 1
      if (line ~ /(UPDATE|INTO|DELETE[[:space:]]+FROM)[[:space:]]+emails([^A-Za-z0-9_]|$)/) w = 1
      if (!w || optout) next
      if ((rel(FILENAME) "|" member) in ok) { print "used\t" rel(FILENAME) "|" member; next }
      report("other", $0)
    }
  ' "$f")
  overlay+=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "overlay" { print $2 }')
  overlay+=$'\n'
  other+=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "other" { print $2 }')
  other+=$'\n'
  used+=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "used" { print $2 }')
  used+=$'\n'
done

# An allow-list entry that no longer matches a write is stale: the write
# moved, or the member was renamed (then the write would fail check 2).
stale=""
while IFS='|' read -r file member _; do
  case "$file" in ''|'#'*) continue ;; esac
  [ "${dir%/}" = lib ] || [ -e "${dir%/}/${file#lib/}" ] || continue
  if ! printf '%s\n' "$used" | grep -qxF "$file|$member"; then
    stale+="$file|$member"$'\n'
  fi
done <<< "$allowed"

overlay=$(printf '%s' "$overlay" | grep -v '^$' | sort -u || true)
other=$(printf '%s' "$other" | grep -v '^$' | sort -u || true)
status=0
if [ -n "$overlay" ]; then
  echo "ERROR: the read/star/snooze columns (is_seen, is_flagged, snoozed_until,"
  echo "their srv_/local_ pairs, srv_keywords_seq) are written only by the email"
  echo "state writer and migrations (see SYNC.md \"Email state writer\"):"
  printf '%s\n' "$overlay"
  status=1
fi
if [ -n "$other" ]; then
  echo "ERROR: emails is written only by the email state writer, migrations and"
  echo "the allow-list in scripts/check_email_writes.sh (see SYNC.md"
  echo "\"Email state writer\"):"
  printf '%s\n' "$other"
  status=1
fi
if [ -n "$stale" ]; then
  echo "ERROR: allow-list entries in scripts/check_email_writes.sh that match no"
  echo "write any more (remove them):"
  printf '%s' "$stale"
  status=1
fi
[ "$status" -eq 0 ] && echo "Email write check passed."
exit "$status"
