#!/usr/bin/env bash
# Bash Strict Mode: https://github.com/guettli/bash-strict-mode
trap 'echo -e "\n🤷 🚨 🔥 Warning: A command has failed. Exiting the script. Line was ($0:$LINENO): $(sed -n "${LINENO}p" "$0" 2>/dev/null || true) 🔥 🚨 🤷 "; exit 3' ERR
set -Eeuo pipefail

# Starts Stalwart in the background on fresh random ports, runs integration
# tests, then stops it.

# Provide defaults for vars added in later commits (avoid breakage before re-entering nix shell).
export STALWART_USER_C="${STALWART_USER_C:-bob}"
export STALWART_PASS_C="${STALWART_PASS_C:-secret}"
export STALWART_RANDOM_PORTS=1
export STALWART_TMPDIR="$(mktemp -d /tmp/stalwart-dev-XXXXXX)"
command -v stalwart >/dev/null || {
    echo "stalwart not in PATH — run inside nix develop"
    exit 1
}

# Pre-seed version.spam-filter in the SQLite store so Stalwart does not attempt
# to download spam-filter rules on first boot (no network needed for tests).
# The 's' table is Stalwart's key-value settings store; keys and values are UTF-8.
mkdir -p "$STALWART_TMPDIR"
sqlite3 "${STALWART_TMPDIR}/data.sqlite" \
    "CREATE TABLE IF NOT EXISTS s (k BLOB PRIMARY KEY, v BLOB NOT NULL);
     INSERT OR REPLACE INTO s VALUES ('version.spam-filter', 'dev');" 2>/dev/null || true

LOGFILE="${STALWART_TMPDIR}/stalwart.log"
rm -f "$LOGFILE"

"$(dirname "$0")/start" >"$LOGFILE" 2>&1 &
STALWART_PID=$!
trap 'kill "$STALWART_PID" 2>/dev/null || true; wait "$STALWART_PID" 2>/dev/null || true' EXIT

# Wait until Stalwart is accepting connections (up to 10 s).
# Use /.well-known/jmap (no -f so any HTTP response counts as up).
for _i in $(seq 1 20); do
    [ -f "${STALWART_TMPDIR}/ports.env" ] && . "${STALWART_TMPDIR}/ports.env"
    grep -E "Configuration build error|Build error for key|already in use" "$LOGFILE" >/dev/null 2>&1 && {
        cat "$LOGFILE"
        echo "Stalwart reported a startup error"
        exit 1
    }
    kill -0 "$STALWART_PID" 2>/dev/null || {
        cat "$LOGFILE"
        echo "Stalwart process died unexpectedly"
        exit 1
    }
    if [ -n "${STALWART_URL:-}" ] && curl -s --max-time 1 -o /dev/null "${STALWART_URL}/.well-known/jmap" 2>/dev/null; then
        kill -0 "$STALWART_PID" 2>/dev/null || {
            cat "$LOGFILE"
            echo "Stalwart process died unexpectedly"
            exit 1
        }
        break
    fi
    sleep 0.5
done

[ -n "${STALWART_URL:-}" ] || {
    cat "$LOGFILE"
    echo "Stalwart did not publish its chosen ports"
    exit 1
}

curl -s --max-time 1 -o /dev/null "${STALWART_URL}/.well-known/jmap" 2>/dev/null || {
    cat "$LOGFILE"
    echo "Stalwart did not become ready"
    exit 1
}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Regenerate SQLDelight code if any .sq file is newer than the generated DB class.
GENERATED_DB="$ROOT/data/src/generated/de/sharedinbox/data/db/SharedInboxDatabase.kt"
if find "$ROOT/data/src/sqldelight" -name "*.sq" -newer "$GENERATED_DB" 2>/dev/null | grep -q . || [ ! -f "$GENERATED_DB" ]; then
    echo "Schema changed — regenerating SQLDelight code..."
    "$ROOT/gradlew" --project-dir "$ROOT/codegen" generateAndCopy
fi

amper test -m data -p jvm
