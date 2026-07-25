#!/usr/bin/env bash
set -euo pipefail
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
if fvm flutter test test/unit/ test/widget/ --coverage --no-pub --reporter expanded >"$tmp" 2>&1; then
  # Success: show only the summary line
  grep -E "^All [0-9]+ tests passed" "$tmp" || tail -1 "$tmp"
else
  # Failure: show the full output so the developer sees what broke
  cat "$tmp"
  exit 1
fi
