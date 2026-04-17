#!/usr/bin/env bash
set -euo pipefail
START=$(date +%s)
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
if flutter test test/widget/ --no-pub --reporter expanded >"$tmp" 2>&1; then
  grep -E "^All [0-9]+ tests passed" "$tmp" || tail -1 "$tmp"
else
  cat "$tmp"
  exit 1
fi
END=$(date +%s)
echo "test-widget: $((END - START))s"
