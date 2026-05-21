#!/usr/bin/env bash
# Verify that all *.mocks.dart files are up to date.
# Re-runs build_runner and fails if any generated mock differs from what is committed.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

echo "check-mocks: regenerating..."
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
if fvm flutter pub run build_runner build --delete-conflicting-outputs >"$tmp" 2>&1; then
  grep -vE '^\[' "$tmp" || true
else
  cat "$tmp"
  exit 1
fi

CHANGED=$(git diff --name-only -- '*.mocks.dart')
if [ -n "$CHANGED" ]; then
    echo "ERROR: The following mock files are out of date:"
    echo "$CHANGED"
    echo "Run 'task codegen' and commit the regenerated mocks."
    exit 1
fi
echo "check-mocks: all mock files are up to date."
