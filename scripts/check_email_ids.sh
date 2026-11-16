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
echo "Email id check passed."
