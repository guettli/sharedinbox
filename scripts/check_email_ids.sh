#!/usr/bin/env bash
# Email row ids are opaque (SYNC-REDESIGN.md §6, SYNC.md "Row identity"): a
# new row's id comes from newEmailId() and nothing else, and no code reads
# a server location (folder, UID, JMAP id) out of an id. Where the server
# has a mail is in the srv_* columns.
#
# This check fails on the shapes the old ids had in lib/:
#   - a string ending in `:$uid` / `:${x.uid}`        ('acc:$path:$uid')
#   - `$accountId:$jmapId`                            ('acc:jmapId')
#   - the virtual-row markers `__local__` / `__local_sent__`
#   - splitting or searching an id at ':'             (id.split(':'), …)
#   - an id checked for an account prefix             (id.startsWith('$accountId:'),
#                                                      prefix = '$accountId:')
#   - an account prefix cut off an id                 (id.substring(accountId.length + 1))
#   - parts joined with ':'                           (parts.join(':'))
#   - `$accountId:$anything`                          ('acc:$x'); not checked in
#     lib/data/repositories/mailbox_repository_impl.dart, which builds
#     mailbox ids (`account:path`) of that shape
#
# Allowed: the schema migrations in lib/data/db/database.dart (they convert
# what old ids said into columns, once) and lib/data/repositories/email_ids.dart.
# A line that builds some other id of that shape (e.g. a mailbox id) can opt
# out with the comment `// not an email id`.
#
# Row ids are also frozen (phase 2c): a row keeps the id it was inserted
# with. The check also fails on
#   - a raw `UPDATE emails SET … id = …`
#   - `id:` in an `EmailsCompanion(…)` (an update; `EmailsCompanion.insert`
#     is an insert) unless it is `id: const Value.absent()`, and
#     `.copyWith(id: Value(…))`
#   - references re-pointed from one email row to another (`SET email_id =`,
#     `SET latest_email_id =`, `SET reply_to_email_id =`, `REPLACE(` over
#     `email_ids_json` / `data_json`, `resourceId: Value(`) outside
#     `_mergeDuplicateRow`, the one place that merges a duplicate row into
#     the kept one before deleting it.
#
# Usage: scripts/check_email_ids.sh [dir]   (default: lib)
set -euo pipefail

dir="${1:-lib}"
patterns=(
  ":\\\$\\{?[A-Za-z_.]*[Uu]id\\}?['\"]"
  "\\\$\\{?[A-Za-z_.]*[Aa]ccount[A-Za-z_.]*\\}?:\\\$\\{?[A-Za-z_.]*[Jj]map[A-Za-z]*\\}?['\"]"
  "__local(_sent)?__"
  "[Ii]ds?\\??\\.(split|indexOf|lastIndexOf)\\(\\s*':'"
  "[Ii]d\\??\\.startsWith\\(\\s*'\\\$\\{?[A-Za-z_.]*[Aa]ccount"
  "'\\\$\\{?[A-Za-z_.]*[Aa]ccount[A-Za-z_.]*\\}?:'"
  "substring\\([^)]*[Aa]ccount(Id|\\.id)\\.length"
  "join\\(\\s*':'\\s*\\)"
)
# Checked everywhere but in the mailbox repository (see above).
outside_mailboxes="\\\$\\{?([A-Za-z_]+\\.)?[Aa]ccount(Id|\\.id)\\}?:\\\$"

found=""
for pattern in "${patterns[@]}"; do
  hits=$(grep -rnE --include='*.dart' "$pattern" "$dir" \
    | grep -v '\.g\.dart:' \
    | grep -v '^[^:]*lib/data/db/database\.dart:' \
    | grep -v '^[^:]*lib/data/repositories/email_ids\.dart:' \
    | grep -v '// not an email id' || true)
  if [ -n "$hits" ]; then
    found+="$hits"$'\n'
  fi
done
hits=$(grep -rnE --include='*.dart' "$outside_mailboxes" "$dir" \
  | grep -v '\.g\.dart:' \
  | grep -v '^[^:]*lib/data/db/database\.dart:' \
  | grep -v '^[^:]*lib/data/repositories/mailbox_repository_impl\.dart:' \
  | grep -v '// not an email id' || true)
if [ -n "$hits" ]; then
  found+="$hits"$'\n'
fi

if [ -n "$found" ]; then
  echo "ERROR: email ids must not be built from or parsed for a server location"
  echo "(use newEmailId() and the srv_* columns; see SYNC.md \"Row identity\"):"
  printf '%s' "$found" | sort -u
  exit 1
fi
# ── Frozen ids ──────────────────────────────────────────────────────────────
frozen=""
dart_files=$(grep -rlE --include='*.dart' \
  "UPDATE emails|EmailsCompanion\(|copyWith\(|email_id|email_ids_json|data_json|resourceId: Value\(" \
  "$dir" | grep -v '\.g\.dart$' | grep -v 'lib/data/db/database\.dart$' || true)
for f in $dart_files; do
  hits=$(awk '
    # Raw SQL that sets the id of an email row.
    /UPDATE emails SET ([a-z_]+ = [^,]*, )*id =/ { print FILENAME ":" FNR ":" $0 }
    # Drift: `id:` given to a non-insert EmailsCompanion(...).
    {
      line = $0
      if (!inside) {
        p = index(line, "EmailsCompanion(")
        if (p == 0) next
        inside = 1; depth = 0
        line = substr(line, p + length("EmailsCompanion"))
      }
      if (line ~ /(^|[^A-Za-z0-9_.])id: / && line !~ /id: const Value\.absent\(\)/) {
        print FILENAME ":" FNR ":" $0
      }
      n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (c == "(") depth++
        if (c == ")") { depth--; if (depth == 0) { inside = 0; break } }
      }
    }
  ' "$f")
  hits+=$'\n'$(grep -nE "copyWith\(\s*id: Value\(" "$f" | sed "s|^|$f:|" || true)
  # Re-pointing references between email rows: only in _mergeDuplicateRow.
  hits+=$'\n'$(awk '
    /Future<void> _mergeDuplicateRow\(/ { merge = 1 }
    merge && /^  }$/ { merge = 0; next }
    merge { next }
    /SET (latest_|reply_to_)?email_id = \?|REPLACE\((email_ids_json|data_json)|resourceId: Value\(/ {
      print FILENAME ":" FNR ":" $0
    }
  ' "$f")
  hits=$(printf '%s' "$hits" | grep -v '^$' | grep -v '// not an email id' || true)
  if [ -n "$hits" ]; then
    frozen+="$hits"$'\n'
  fi
done

if [ -n "$frozen" ]; then
  echo "ERROR: email row ids are frozen: nothing may change a row's id after"
  echo "insert, and only _mergeDuplicateRow re-points references between rows"
  echo "(see SYNC.md \"Row identity\"):"
  printf '%s' "$frozen" | sort -u
  exit 1
fi
echo "Email id check passed."
