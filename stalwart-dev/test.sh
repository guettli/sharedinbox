#!/usr/bin/env bash
# Bash Strict Mode: https://github.com/guettli/bash-strict-mode
trap 'echo -e "\n🤷 🚨 🔥 Warning: A command has failed. Exiting the script. Line was ($0:$LINENO): $(sed -n "${LINENO}p" "$0" 2>/dev/null || true) 🔥 🚨 🤷 "; exit 3' ERR
set -Eeuo pipefail

# Starts Stalwart in the background, runs integration tests, then stops it.

: "${STALWART_PORT:?STALWART_PORT is not set — run this inside nix develop}"
# Provide defaults for vars added in later commits (avoid breakage before re-entering nix shell).
export STALWART_USER_C="${STALWART_USER_C:-bob}"
export STALWART_PASS_C="${STALWART_PASS_C:-secret}"
command -v stalwart >/dev/null || { echo "stalwart not in PATH — run inside nix develop"; exit 1; }

STALWART_URL="http://127.0.0.1:${STALWART_PORT}"

"$(dirname "$0")/start" &
STALWART_PID=$!
trap 'kill "$STALWART_PID" 2>/dev/null; wait "$STALWART_PID" 2>/dev/null' EXIT

# Wait until Stalwart is accepting connections (up to 10 s).
# Use /.well-known/jmap (no -f so any HTTP response counts as up).
for i in $(seq 1 20); do
    kill -0 "$STALWART_PID" 2>/dev/null || { echo "Stalwart process died unexpectedly"; exit 1; }
    curl -s --max-time 1 -o /dev/null "${STALWART_URL}/.well-known/jmap" 2>/dev/null && break
    sleep 0.5
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Regenerate SQLDelight code if any .sq file is newer than the generated DB class.
GENERATED_DB="$ROOT/data/src/generated/de/sharedinbox/data/db/SharedInboxDatabase.kt"
if find "$ROOT/data/src/sqldelight" -name "*.sq" -newer "$GENERATED_DB" 2>/dev/null | grep -q . || [ ! -f "$GENERATED_DB" ]; then
    echo "Schema changed — regenerating SQLDelight code..."
    "$ROOT/gradlew" --project-dir "$ROOT/codegen" generateAndCopy
fi

amper test -m data -p jvm
