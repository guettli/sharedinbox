#!/usr/bin/env bash
# Who may write the `emails` table (SYNC-REDESIGN.md §2 and §8
# "Enforcement", SYNC.md "Email state writer").
#
# Two checks over lib/ (generated *.g.dart files skipped). The email state
# writer (lib/data/repositories/email_state_writer.dart) and the schema
# migrations (the members of lib/data/db/database.dart listed in
# `migrations` below) are exempt from both.
#
# 1. The overlay columns — keywords: is_seen, is_flagged, snoozed_until,
#    their srv_/local_ pairs and srv_keywords_seq; location (phase 4a):
#    mailbox_path, srv_mailbox_path, local_mailbox_path, local_hidden,
#    srv_gone and srv_location_seq — are written nowhere else. No
#    allow-list, no opt-out. It fails on
#      - one of them named in an `EmailsCompanion(…)`, `.insert(…)` or
#        `.custom(…)` (also across lines), unless `const Value.absent()`
#        (`mailboxPath` excepted in `.insert(…)`, where it is required: a
#        new row has no pending move, and an insert trigger records it as
#        the server's folder);
#      - srvIsSeen/srvIsFlagged/srvSnoozedUntil/srvKeywordsSeq/localIsSeen/
#        localIsFlagged/localSnoozedUntil/srvMailboxPath/localMailboxPath/
#        localHidden/srvGone/srvLocationSeq given a `Value(…)` anywhere
#        (only emails rows have these names);
#      - SQL, in any letter case: `UPDATE [OR …] emails … SET <column> =`
#        (the SET list up to WHERE, also across string literals and lines,
#        also with the column quoted), `INSERT … INTO emails (…)` with one in
#        the column list, and `INSERT … INTO emails` without a column list
#        (`SELECT …`, `VALUES …`: every column). The table may also be
#        interpolated (`${_db.emails.actualTableName}`);
#      - in a member on the allow-list of check 2: a whole-row
#        `.toCompanion(`, a `copyWith(…)` naming one (not on a thread
#        companion, which has an `isFlagged` and a `mailboxPath` of its
#        own), and a Drift insert/write/replace into emails whose argument
#        is not an `EmailsCompanion(…)` / `EmailsCompanion.custom(…)`
#        literal, `newRow(…)` / `withServerLocation(…)` or a local variable
#        initialised with one of these (an `Email` data row carries every
#        column, and an `EmailsCompanion.insert(…)` the shown folder, which
#        an upsert would write over a pending move). `newRow` and
#        `withServerLocation` only as the argument of a plain `.insert(…)`
#        without `mode:` / `onConflict:` (an upsert or replace would reset
#        the overlay of a row that exists); no `replace` at all.
#    SQL split into adjacent string literals ("UPDATE " + "emails …", also
#    across a line break) is read joined.
#
# 2. Every other write of `emails` — `EmailsCompanion`, `.toCompanion(`,
#    Drift's update/into/delete/insert/replace on `emails` (also in a batch,
#    also across lines), the table manager (`emails.insert…/update/
#    delete…/replace`, `managers.emails`), a `customUpdate`/
#    `customInsert` naming emails in `updates: {…}`, raw SQL in any letter
#    case (`UPDATE [OR …] emails`, `INSERT … INTO emails`, `DELETE FROM
#    emails`, `REPLACE INTO emails`, the table also interpolated), and as a
#    backstop against aliases any other bare reference to the table
#    (`_db.emails`, `db.emails`, … not followed by a column) outside
#    `select(`, `selectOnly(`, joins, `readTable…(` and `readsFrom:` —
#    appears only in a member on the allow-list below. A line that only
#    looks like one can opt out with `// not an emails write`; check 1
#    has no opt-out.
#
# The allow-list names a file and the member (method, getter, top-level
# function) holding the write, with the reason it is not in the state writer
# yet and the phase that moves it there. Members are found by indentation:
# a declaration at indent 0 outside a type, at indent 2 inside one. Fields,
# getters, annotations and signatures spread over lines start a member of
# their own, so a write cannot borrow the name of an allowed member above
# it. An entry that matches no write fails too.
#
# 3. The `mailboxes` table (phase 5a, SYNC-REDESIGN.md §7: the mailbox
#    overlay `srv_name`, `local_name`, `name`, `is_local`, `srv_seq`, and
#    `display_path` derived from it) is written only by the mailbox state
#    writer (lib/data/repositories/mailbox_state_writer.dart) and the
#    migrations (`_upgradeSteps`, `_overlayMailboxes` of database.dart). No
#    allow-list, no opt-out. It fails on a `MailboxesCompanion`, Drift's
#    into/update/delete on `mailboxes` (also in a batch, also behind
#    `this._db.`), the table's own write methods (`mailboxes.deleteWhere(`,
#    `.insertOne(`, ...), the table manager,
#    `updates: {…}` naming it, and raw SQL in any letter case (`UPDATE [OR …]
#    mailboxes`, `INSERT … INTO mailboxes`, `REPLACE INTO mailboxes`,
#    `DELETE FROM mailboxes`, also split over adjacent string literals).
#    `sync_log_mailboxes` is another table.
#
# Usage: scripts/check_email_writes.sh [dir]   (default: lib)
set -euo pipefail

dir="${1:-lib}"

# Schema migrations (the members of database.dart that write emails while
# upgrading): exempt from both checks. The rest of database.dart is checked.
migrations='
lib/data/db/database.dart|_upgradeSteps
lib/data/db/database.dart|_backfillSrvLocation
lib/data/db/database.dart|_overlayKeywords
lib/data/db/database.dart|_overlayLocation
lib/data/db/database.dart|_createLocationOverlaySchema
'

# file | member | reason
allowed='
# Row inserts of new rows and the header columns of existing ones. The
# overlay columns come only from EmailStateWriter.newRow /
# withServerLocation (check 1); an existing row is written with an
# EmailsCompanion naming no overlay column. The local rows (virtual rows,
# the Sent copy) moved into the writer in phase 4b (insertLocalRow,
# writeLocalRowHeaders). These three build a header companion
# from a server answer or an Undo snapshot, which phase 6 may move too.
lib/data/repositories/email_repository_impl/sync_imap.dart|_fetchAndUpsertImapGuarded|IMAP new-mail fetch: new rows and headers (phase 6)
lib/data/repositories/email_repository_impl/sync_jmap.dart|_upsertJmapEmails|JMAP Email/get: new rows and headers (phase 6)
lib/data/repositories/email_repository_impl/user_actions.dart|_restoreEmail|Undo brings a row back that sync cleaned up (phase 6)
'

files=$(grep -rlE --include='*.dart' \
  'emails|EMAILS|Emails|srvIsSeen|srvIsFlagged|srvSnoozedUntil|srvKeywordsSeq|localIsSeen|localIsFlagged|localSnoozedUntil|srvMailboxPath|localMailboxPath|localHidden|srvGone|srvLocationSeq|toCompanion\(' \
  "$dir" | grep -v '\.g\.dart$' \
  | grep -v 'lib/data/repositories/email_state_writer\.dart$' || true)

overlay=""
other=""
used=""
for f in $files; do
  out=$(awk -v allowed="$allowed" -v migrations="$migrations" '
    BEGIN {
      n = split(allowed, rows, "\n")
      for (i = 1; i <= n; i++) {
        if (rows[i] ~ /^#/ || rows[i] == "") continue
        split(rows[i], parts, "|")
        ok[parts[1] "|" parts[2]] = 1
      }
      n = split(migrations, rows, "\n")
      for (i = 1; i <= n; i++) {
        if (rows[i] == "") continue
        mig[rows[i]] = 1
      }
      cols = "(srv_|local_)?(is_seen|is_flagged|snoozed_until|mailbox_path)|srv_keywords_seq|local_hidden|srv_gone|srv_location_seq"
      srvLocal = "(srvIsSeen|srvIsFlagged|srvSnoozedUntil|srvKeywordsSeq|localIsSeen|localIsFlagged|localSnoozedUntil|srvMailboxPath|localMailboxPath|localHidden|srvGone|srvLocationSeq)"
      # In an EmailsCompanion.insert(…) the shown folder is required.
      namesInsert = "(isSeen|isFlagged|snoozedUntil|srvIsSeen|srvIsFlagged|srvSnoozedUntil|srvKeywordsSeq|localIsSeen|localIsFlagged|localSnoozedUntil|srvMailboxPath|localMailboxPath|localHidden|srvGone|srvLocationSeq)"
      names = "(mailboxPath|isSeen|isFlagged|snoozedUntil|srvIsSeen|srvIsFlagged|srvSnoozedUntil|srvKeywordsSeq|localIsSeen|localIsFlagged|localSnoozedUntil|srvMailboxPath|localMailboxPath|localHidden|srvGone|srvLocationSeq)"
      # The table in lower-cased SQL: emails, "emails", or interpolated.
      table = "(\"?emails\"?|`emails`|\\$\\{[^}]*emails[^}]*\\})([^a-z0-9_]|$)"
      updSql = "update[[:space:]]+(or[[:space:]]+[a-z]+[[:space:]]+)?" table
      insSql = "into[[:space:]]+" table
      delSql = "delete[[:space:]]+from[[:space:]]+" table
      dbRef = "(^|[^A-Za-z0-9_.])(_db|db|_database|database|attachedDatabase)\\.emails"
    }
    function rel(path,   p) {
      p = index(path, "lib/")
      return p > 0 ? substr(path, p) : path
    }
    function key() { return rel(FILENAME) "|" member }
    function report(kind, text) {
      print kind "\t" FILENAME ":" FNR ": [" (member == "" ? "-" : member) "] " text
    }
    # The value expressions of a call argument [a]: inner parentheses
    # emptied, named arguments dropped, a conditional split into its two
    # branches. Each must be an EmailsCompanion(…) / .custom(…) literal,
    # newRow(…) / withServerLocation(…) or a variable holding one.
    function rowArgOk(a, method,   flat, i, c, d, parts, n, k, v, q, branches, m, j, plain) {
      flat = ""; d = 0
      for (i = 1; i <= length(a); i++) {
        c = substr(a, i, 1)
        if (c == "(") { if (d == 0) flat = flat "("; d++; continue }
        if (c == ")") { d--; if (d == 0) flat = flat ")"; continue }
        if (d == 0) flat = flat c
      }
      n = split(flat, parts, ",")
      # A new row (newRow / withServerLocation) only through a plain
      # insert: an upsert or a replace would reset the overlay columns of
      # a row that exists (and a replace deletes it, its body cascading).
      plain = (method == "insert")
      for (k = 1; k <= n; k++) {
        v = parts[k]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
        if (v ~ /^(mode|onConflict):/) plain = 0
      }
      if (method == "replace") return 0
      for (k = 1; k <= n; k++) {
        v = parts[k]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
        if (v == "" || v ~ /^[A-Za-z_][A-Za-z0-9_]*:/) continue
        q = index(v, "?")
        if (q > 0) v = substr(v, q + 1)
        m = split(v, branches, ":")
        for (j = 1; j <= m; j++) {
          v = branches[j]
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
          if (v ~ /^(const[[:space:]]+)?EmailsCompanion(\.custom)?\(\)$/) continue
          if (plain && v ~ /^(EmailStateWriter\.)?(newRow|withServerLocation)\(\)$/) continue
          if (v ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && (v in compVar)) continue
          if (plain && v ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && (v in rowVar)) continue
          return 0
        }
      }
      return 1
    }

    # ── Members ───────────────────────────────────────────────────────────
    /^(abstract |base |final |sealed |interface )*(class|extension|mixin|enum)[[:space:]]/ {
      inType = 1
    }
    # A closing brace at indent 0 ends the type or top-level function (not
    # the `}) async {` of a signature).
    /^};?[[:space:]]*$/ { inType = 0; member = ""; split("", compVar); split("", rowVar) }
    {
      decl = 0
      if (!inType && $0 ~ /^[A-Za-z_@]/) decl = 1
      if (inType && $0 ~ /^  [A-Za-z_@]/) decl = 1
      if (decl) {
        before = member
        if ($0 ~ /^[[:space:]]*@/) {
          member = "(annotation)"
        } else if ($0 ~ /^[[:space:]]*(static[[:space:]]+)?(late[[:space:]]+)?(final|const|var)([[:space:]]|$)/ \
            || $0 ~ /^[^(]*[^=!<>]=[^=>]/) {
          member = "(field)"
        } else if (match($0, /[[:space:]]get[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/)) {
          member = substr($0, RSTART, RLENGTH)
          sub(/^[[:space:]]*get[[:space:]]+/, "", member)
        } else if (match($0, /[A-Za-z_][A-Za-z0-9_]*(<[^()]*>)?\(/)) {
          member = substr($0, RSTART, RLENGTH)
          sub(/<.*$/, "", member); sub(/\($/, "", member)
        } else {
          # A signature continued on the next line.
          member = "(signature)"; sigNext = 1
        }
        if (member != before) { split("", compVar); split("", rowVar) }
      } else if (sigNext && match($0, /[A-Za-z_][A-Za-z0-9_]*(<[^()]*>)?\(/)) {
        member = substr($0, RSTART, RLENGTH)
        sub(/<.*$/, "", member); sub(/\($/, "", member)
        sigNext = 0
      }
      if (decl && member != "(signature)") sigNext = 0
    }
    (key() in mig) { next }
    {
      line = $0
      if (prev ~ /\([[:space:]]*$/) joined = prev $0; else joined = $0
      if (prev ~ /\([[:space:]]*$/ && $0 ~ /^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*\.)?emails[[:space:]]*[,)]/) line = prev $0
      prev = $0
      optout = ($0 ~ /\/\/ not an emails write/)
      allowedHere = (key() in ok)
      # Code without comments, lower-cased, for SQL.
      code = $0
      sub(/^[[:space:]]*\/\/.*$/, "", code); sub(/[[:space:]]\/\/.*$/, "", code)
      sql = tolower(code)
      gsub(/\[|\]/, "", sql)
      # Adjacent string literals (an UPDATE split as "UPDATE " + "emails",
      # also without the +) read as one, also across a line break (sqlJ:
      # the last literal of the line above joined with the first one of this line).
      gsub(/['"'"'"][[:space:]]*\+?[[:space:]]*['"'"'"]/, "", sql)
      cur = sql
      startsLit = sub(/^[[:space:]]*\+?[[:space:]]*['"'"'"]/, "", cur)
      sqlJ = (prevLitEnd && startsLit) ? prevLit cur : sql
      t = sql
      prevLitEnd = sub(/['"'"'"][[:space:]]*,?[[:space:]]*\+?[[:space:]]*$/, "", t)
      if (match(t, /['"'"'"][^'"'"'"]*$/)) t = substr(t, RSTART + 1)
      prevLit = t
    }

    # ── Check 1: the overlay columns ──────────────────────────────────────
    # Inside EmailsCompanion(…) / .insert(…) / .custom(…).
    {
      rest = $0
      if (!inComp) {
        if (match(rest, /(^|[^A-Za-z0-9_])EmailsCompanion(\.insert|\.custom)?\(/)) {
          inComp = 1; depth = 0
          compNames = (substr(rest, RSTART, RLENGTH) ~ /\.insert\($/) ? namesInsert : names
          rest = substr(rest, RSTART + RLENGTH - 1)
        }
      }
      if (inComp) {
        probe = rest
        gsub(compNames ":[[:space:]]*const[[:space:]]+Value\\.absent\\(\\)", "", probe)
        if (probe ~ ("(^|[^A-Za-z0-9_.])" compNames ":")) report("overlay", $0)
        m = length(rest)
        for (i = 1; i <= m; i++) {
          c = substr(rest, i, 1)
          if (c == "(") depth++
          if (c == ")") { depth--; if (depth == 0) { inComp = 0; break } }
        }
      }
    }
    # copyWith(…) naming an overlay column, in a member that writes emails.
    {
      rest = $0
      if (!inCopy && allowedHere && match(rest, /copyWith\(/)) {
        head = substr(rest, 1, RSTART - 1)
        inCopy = 1; cdepth = 0; copyThread = (head ~ /[Tt]hread/)
        rest = substr(rest, RSTART + RLENGTH - 1)
      }
      if (inCopy) {
        probe = rest
        gsub(names ":[[:space:]]*const[[:space:]]+Value\\.absent\\(\\)", "", probe)
        if (!copyThread && probe ~ ("(^|[^A-Za-z0-9_.])" names ":")) report("overlay", $0)
        m = length(rest)
        for (i = 1; i <= m; i++) {
          c = substr(rest, i, 1)
          if (c == "(") cdepth++
          if (c == ")") { cdepth--; if (cdepth == 0) { inCopy = 0; break } }
        }
      }
    }
    # A whole row (`row.toCompanion(…)`) written by a member allowed to
    # write emails carries every overlay column along. (Elsewhere check 2
    # fails on it.)
    $0 ~ /\.toCompanion\(/ && allowedHere { report("overlay", $0) }
    # The srv_/local_ names exist only on emails rows.
    $0 ~ ("(^|[^A-Za-z0-9_.])" srvLocal ":[[:space:]]*(const[[:space:]]+)?Value(<[^>]*>)?\\(") {
      report("overlay", $0)
    }
    # Companion variables of an allowed member, for the argument check.
    allowedHere && match($0, /(final|var)[[:space:]]+([A-Za-z_][A-Za-z0-9_<>?]*[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*(const[[:space:]]+)?(EmailsCompanion(\.custom)?\(|(EmailStateWriter\.)?(newRow|withServerLocation)\()/) {
      v = substr($0, RSTART, RLENGTH)
      isRow = (v ~ /(newRow|withServerLocation)\($/)
      sub(/[[:space:]]*=.*$/, "", v); sub(/^.*[[:space:]]/, "", v)
      if (isRow) rowVar[v] = 1; else compVar[v] = 1
    }
    # The argument of a Drift insert/write/replace into emails, in an
    # allowed member: no data row.
    allowedHere {
      rest = code
      if (!inArg && !pendArg && line ~ /(into|update)\([[:space:]]*([A-Za-z_][A-Za-z0-9_]*\.)?emails[[:space:]]*\)/) {
        pendArg = 1; pendStart = FNR
        p = index(rest, "emails)")
        rest = substr(rest, p + 7)
      }
      if (!inArg && match(line, /(insert|update|replace|insertAllOnConflictUpdate)\([[:space:]]*([A-Za-z_][A-Za-z0-9_]*\.)?emails[[:space:]]*,/)) {
        argMethod = substr(line, RSTART, RLENGTH); sub(/\(.*$/, "", argMethod)
        p = index(rest, "emails,")
        if (p == 0) p = index(rest, "emails ,")
        if (p > 0) { inArg = 1; adepth = 1; argText = ""; argStart = FNR; argLine = $0; rest = substr(rest, p + 7) }
      }
      if (pendArg && !inArg) {
        if (match(rest, /\.(insert|insertOnConflictUpdate|insertOne|insertReturning|replace|write)\(/)) {
          argMethod = substr(rest, RSTART + 1, RLENGTH - 2)
          pendArg = 0; inArg = 1; adepth = 1; argText = ""; argStart = FNR; argLine = $0
          rest = substr(rest, RSTART + RLENGTH)
        } else if (FNR - pendStart > 8) pendArg = 0
      }
      if (inArg) {
        m = length(rest)
        for (i = 1; i <= m; i++) {
          c = substr(rest, i, 1)
          if (c == "(") adepth++
          if (c == ")") {
            adepth--
            if (adepth == 0) {
              inArg = 0
              if (!rowArgOk(argText, argMethod)) print "overlay\t" FILENAME ":" argStart ": [" member "] " argLine
              break
            }
          }
          argText = argText c
        }
        if (inArg) argText = argText " "
      }
    }
    # SQL: the SET list of an UPDATE emails, the column list of an INSERT.
    {
      s = sql
      if (!inSet && !inIns && s !~ updSql && s !~ insSql \
          && (sqlJ ~ updSql || sqlJ ~ insSql)) s = sqlJ
      # String literals split over lines read as one; quoted names unquoted.
      gsub(/['"'"'"][[:space:]]*,?[[:space:]]*$/, "", s); gsub(/^[[:space:]]*['"'"'"]/, " ", s)
      if (!inSet && !inIns) {
        if (match(s, updSql)) {
          inSet = 1; setText = ""; setStart = FNR; setLine = $0
          s = substr(s, RSTART + RLENGTH - 1)
        } else if (match(s, insSql)) {
          inIns = 1; setText = ""; setStart = FNR; setLine = $0; insHead = 1
          s = substr(s, RSTART + RLENGTH - 1)
        }
      }
      if (inSet || inIns) {
        gsub(/["`]/, "", s)
        stop = 0
        if (inIns && insHead) {
          t = s; sub(/^[^a-z0-9_(]*/, "", t)
          if (t != "") {
            insHead = 0
            if (substr(t, 1, 1) != "(") {
              print "overlay\t" FILENAME ":" setStart ": [" (member == "" ? "-" : member) "] " setLine
              inIns = 0
            }
          }
        }
        if (inSet && match(s, /where|returning|;/)) { s = substr(s, 1, RSTART - 1); stop = 1 }
        if (inIns && match(s, /\)|values|select/)) { s = substr(s, 1, RSTART - 1); stop = 1 }
        setText = setText " " s
        if (FNR - setStart >= 12) stop = 1
        if (stop && (inSet || inIns)) {
          hit = inSet ? (setText ~ ("(^|[^a-z0-9_])(" cols ")[[:space:]]*=")) \
                      : (setText ~ ("(^|[^a-z0-9_])(" cols ")([^a-z0-9_]|$)"))
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
      if (line ~ /managers\.emails/) w = 1
      if (line ~ /updates:[[:space:]]*\{[^}]*emails/) w = 1
      if (sql ~ updSql || sql ~ insSql || sql ~ delSql) w = 1
      if (sqlJ ~ updSql || sqlJ ~ insSql || sqlJ ~ delSql) w = 1
      # Backstop: a bare reference to the table that is not a read.
      if (!w && match(joined, dbRef "([^A-Za-z0-9_.]|$)")) {
        headText = substr(joined, 1, RSTART)
        if (headText !~ /(select|selectOnly|Join|readTable|readTableOrNull)\([[:space:]]*$/ \
            && headText !~ /readsFrom:[[:space:]]*\{[^}]*$/) w = 1
      }
      if (!w || optout) next
      if (allowedHere) { print "used\t" key(); next }
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

# ── Check 3: mailboxes ─────────────────────────────────────────────────────
mailbox_files=$(grep -rlE --include='*.dart' \
  'MailboxesCompanion|mailboxes|MAILBOXES|Mailboxes' "$dir" \
  | grep -v '\.g\.dart$' \
  | grep -v 'lib/data/repositories/mailbox_state_writer\.dart$' || true)
mailbox_writes=""
for f in $mailbox_files; do
  rel="lib/${f#"${dir%/}/"}"
  mailbox_writes+=$(awk -v rel="$rel" '
    BEGIN { mig["_upgradeSteps"] = 1; mig["_overlayMailboxes"] = 1 }
    # The member a line belongs to: the last declaration at indent 0 or 2.
    /^(  )?[A-Za-z_][A-Za-z0-9_<>?, .]*[[:space:]][A-Za-z_][A-Za-z0-9_]*\(/ {
      if (match($0, /[A-Za-z_][A-Za-z0-9_]*\(/)) {
        member = substr($0, RSTART, RLENGTH - 1)
      }
    }
    {
      code = $0
      sub(/^[[:space:]]*\/\/.*$/, "", code)
      sub(/[[:space:]]\/\/ .*$/, "", code)
      # SQL split over adjacent string literals reads as one.
      joined = code
      if (prev ~ /'"'"'[[:space:]]*$/ && code ~ /^[[:space:]]*'"'"'/) {
        joined = prev code
        gsub(/'"'"'[[:space:]]*'"'"'/, "", joined)
      }
      prev = code
      hit = 0
      if (code ~ /(^|[^A-Za-z0-9_])MailboxesCompanion/) hit = 1
      if (code ~ /(into|update|delete)\(([A-Za-z_]+\.)*mailboxes[),]/) hit = 1
      if (code ~ /\.(insert|insertAll|insertAllOnConflictUpdate|insertOnConflictUpdate|update|replace|replaceAll|delete|deleteWhere|deleteAll)\(([A-Za-z_]+\.)*mailboxes[),]/) hit = 1
      # Write methods of the table itself (_db.mailboxes.deleteWhere and co).
      if (code ~ /(^|[^A-Za-z0-9_])mailboxes\.(insert[A-Za-z]*|replace[A-Za-z]*|update[A-Za-z]*|delete[A-Za-z]*)\(/) hit = 1
      if (code ~ /managers\.mailboxes/) hit = 1
      if (code ~ /updates:[^}]*(^|[^A-Za-z0-9_])mailboxes([^A-Za-z0-9_]|$)/) hit = 1
      # A bare table reference on its own line: the argument of a Drift
      # write whose call starts on the line before.
      if (code ~ /^[[:space:]]*([A-Za-z_]+\.)*mailboxes,?[[:space:]]*$/ && prevcode ~ /(into|update|delete)\($/) hit = 1
      prevcode = code
      u = toupper(joined)
      if (u ~ /(UPDATE([[:space:]]+OR[[:space:]]+[A-Z]+)?|INTO|DELETE[[:space:]]+FROM)[[:space:]]+"?MAILBOXES"?([^A-Z0-9_]|$)/) hit = 1
      if (!hit) next
      if (rel == "lib/data/db/database.dart" && (member in mig)) next
      print rel ":" FNR ": " $0
    }
  ' "$f")
  mailbox_writes+=$'\n'
done
mailbox_writes=$(printf '%s' "$mailbox_writes" | grep -v '^$' | sort -u || true)

overlay=$(printf '%s' "$overlay" | grep -v '^$' | sort -u || true)
other=$(printf '%s' "$other" | grep -v '^$' | sort -u || true)
status=0
if [ -n "$overlay" ]; then
  echo "ERROR: the overlay columns (read/star/snooze: is_seen, is_flagged,"
  echo "snoozed_until, their srv_/local_ pairs, srv_keywords_seq; location:"
  echo "mailbox_path, srv_mailbox_path, local_mailbox_path, local_hidden,"
  echo "srv_gone, srv_location_seq) are written only by the email state writer"
  echo "and migrations (see SYNC.md \"Email state writer\"):"
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
if [ -n "$mailbox_writes" ]; then
  echo "ERROR: mailboxes is written only by the mailbox state writer and"
  echo "migrations (see SYNC.md \"Mailbox ops\"):"
  printf '%s\n' "$mailbox_writes"
  status=1
fi
[ "$status" -eq 0 ] && echo "Email write check passed."
exit "$status"
