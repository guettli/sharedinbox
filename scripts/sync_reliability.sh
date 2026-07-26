#!/usr/bin/env bash
# Starts an isolated Stalwart instance, runs the Dart sync reliability runner,
# then stops Stalwart.
#
# Fuzz mode (issue #584): pass --fuzz (optionally with --fuzz-seed=N and
# --fuzz-prob=0..1) to inject randomised network and server-edge faults around
# the IMAP/SMTP/JMAP clients. The sync engine is expected to recover and all
# DB snapshots must still converge.
#
# Example:
#   scripts/sync_reliability.sh --fuzz --fuzz-seed=42 --cycles=5
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

command -v stalwart >/dev/null || {
    echo "stalwart not in PATH — run inside nix develop"
    exit 1
}

export STALWART_USER_B="${STALWART_USER_B:-alice@example.com}"
export STALWART_PASS_B="${STALWART_PASS_B:-secret}"
export STALWART_RANDOM_PORTS=1
STALWART_TMPDIR="$(mktemp -d /tmp/stalwart-dev-sync-reliability-XXXXXX)"
export STALWART_TMPDIR

# Pre-seed spam-filter version so Stalwart does not fetch it on first boot.
mkdir -p "$STALWART_TMPDIR"
sqlite3 "${STALWART_TMPDIR}/data.sqlite" \
    "CREATE TABLE IF NOT EXISTS s (k BLOB PRIMARY KEY, v BLOB NOT NULL);
   INSERT OR REPLACE INTO s VALUES ('version.spam-filter', 'dev');" 2>/dev/null || true

LOGFILE="${STALWART_TMPDIR}/stalwart.log"
rm -f "$LOGFILE"

"$ROOT/stalwart-dev/start" >"$LOGFILE" 2>&1 &
STALWART_PID=$!

cleanup() {
    kill "$STALWART_PID" 2>/dev/null || true
    wait "$STALWART_PID" 2>/dev/null || true
}
trap cleanup EXIT

# start writes ports.env before it execs the container, but runs in the
# background — wait for the file to appear so the readiness loop below can
# source it unconditionally. A missing ports.env after the wait means start
# failed to produce it; source without a guard so set -e fails loudly rather
# than silently skipping every readiness check.
for _i in $(seq 1 40); do
    [ -s "${STALWART_TMPDIR}/ports.env" ] && break
    kill -0 "$STALWART_PID" 2>/dev/null || {
        cat "$LOGFILE"
        echo "Stalwart process died before writing ports.env"
        exit 1
    }
    sleep 0.25
done
# shellcheck source=/dev/null
. "${STALWART_TMPDIR}/ports.env"

for _i in $(seq 1 20); do
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
    if curl -s --max-time 1 -o /dev/null "${STALWART_URL}/.well-known/jmap" 2>/dev/null; then
        break
    fi
    sleep 0.5
done

curl -s --max-time 1 -o /dev/null "${STALWART_URL}/.well-known/jmap" || {
    cat "$LOGFILE"
    echo "Stalwart did not become ready"
    exit 1
}

export STALWART_IMAP_HOST="127.0.0.1"
export STALWART_SMTP_HOST="127.0.0.1"

echo "Stalwart ready — URL=${STALWART_URL} IMAP=:${STALWART_IMAP_PORT} SMTP=:${STALWART_SMTP_PORT}"

if [ "$#" -gt 0 ]; then
    SYNC_RELIABILITY_ARGS="$(printf '%s\n' "$@")"
    export SYNC_RELIABILITY_ARGS
else
    unset SYNC_RELIABILITY_ARGS || true
fi

fvm flutter pub get --suppress-analytics
fvm flutter test test/integration/sync_reliability_runner_test.dart --reporter expanded --concurrency=1 --no-pub
