#!/usr/bin/env bash
# Fail if binary files (other than images and fonts) are staged for commit.
# Prevents accidental inclusion of build artifacts, databases, compiled binaries.
set -euo pipefail

ALLOWED_EXTENSIONS='(png|jpg|jpeg|gif|webp|svg|ico|ttf|otf|woff|woff2)'

# git diff --numstat shows "-  -  path" for binary files
BINARY=$(git diff --cached --numstat | awk '$1=="-" && $2=="-" {print $3}')

if [ -z "$BINARY" ]; then
  exit 0
fi

BLOCKED=''
while IFS= read -r f; do
  if ! echo "$f" | grep -qiE "\.$ALLOWED_EXTENSIONS$"; then
    BLOCKED="$BLOCKED\n  $f"
  fi
done <<< "$BINARY"

if [ -n "$BLOCKED" ]; then
  echo "Binary files staged for commit (not allowed):"
  echo -e "$BLOCKED"
  echo ""
  echo "If this is intentional, add the extension to ALLOWED_EXTENSIONS in scripts/check_no_binary.sh"
  exit 1
fi
