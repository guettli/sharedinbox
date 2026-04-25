#!/usr/bin/env bash
# Starts Stalwart in the background on fresh random ports, runs Flutter
# integration tests, then stops it.
set -Eeuo pipefail
trap 'echo "Warning: A command failed ($0:$LINENO)"; exit 3' ERR

export STALWART_USER_B="${STALWART_USER_B:-alice@example.com}"
export STALWART_PASS_B="${STALWART_PASS_B:-secret}"
export STALWART_USER_C="${STALWART_USER_C:-bob@example.com}"
export STALWART_PASS_C="${STALWART_PASS_C:-secret}"
export STALWART_RANDOM_PORTS=1
STALWART_TMPDIR="$(mktemp -d /tmp/stalwart-dev-XXXXXX)"
export STALWART_TMPDIR

command -v stalwart >/dev/null || {
    echo "stalwart not in PATH — run inside nix develop"
    exit 1
}

# Pre-seed spam-filter version so Stalwart does not fetch it on first boot.
mkdir -p "$STALWART_TMPDIR"
sqlite3 "${STALWART_TMPDIR}/data.sqlite" \
    "CREATE TABLE IF NOT EXISTS s (k BLOB PRIMARY KEY, v BLOB NOT NULL);
     INSERT OR REPLACE INTO s VALUES ('version.spam-filter', 'dev');" 2>/dev/null || true

LOGFILE="${STALWART_TMPDIR}/stalwart.log"
rm -f "$LOGFILE"

tmp=$(mktemp)
"$(dirname "$0")/start" >"$LOGFILE" 2>&1 &
STALWART_PID=$!
trap 'kill "$STALWART_PID" 2>/dev/null || true; wait "$STALWART_PID" 2>/dev/null || true; rm -f "$tmp"' EXIT

# Wait until Stalwart is accepting connections (up to 10 s).
for _i in $(seq 1 20); do
    # shellcheck source=/dev/null
    [ -f "${STALWART_TMPDIR}/ports.env" ] && . "${STALWART_TMPDIR}/ports.env"
    grep -E "already in use" "$LOGFILE" >/dev/null 2>&1 && {
        cat "$LOGFILE"; echo "Stalwart port already in use"; exit 1
    }
    kill -0 "$STALWART_PID" 2>/dev/null || {
        cat "$LOGFILE"; echo "Stalwart process died unexpectedly"; exit 1
    }
    if [ -n "${STALWART_URL:-}" ] && \
       curl -s --max-time 1 -o /dev/null "${STALWART_URL}/.well-known/jmap" 2>/dev/null; then
        break
    fi
    sleep 0.5
done

[ -n "${STALWART_URL:-}" ] || { cat "$LOGFILE"; echo "Stalwart did not publish its chosen ports"; exit 1; }
curl -s --max-time 1 -o /dev/null "${STALWART_URL}/.well-known/jmap" || {
    cat "$LOGFILE"; echo "Stalwart did not become ready"; exit 1
}

echo "Stalwart ready — IMAP=:${STALWART_IMAP_PORT:-?}  SMTP=:${STALWART_SMTP_PORT:-?}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Export vars so flutter test can read them.
export STALWART_IMAP_HOST="127.0.0.1"
export STALWART_SMTP_HOST="127.0.0.1"

START=$(date +%s)
run_tests() {
  # If unit tests already produced a coverage baseline, merge integration coverage
  # into it so the final gate reflects both suites.
  if [ -f coverage/lcov.info ]; then
    cp coverage/lcov.info coverage/lcov.base.info
    fvm flutter test --concurrency=1 --coverage --merge-coverage --reporter expanded test/integration/ >"$tmp" 2>&1
    rm -f coverage/lcov.base.info
  else
    fvm flutter test --concurrency=1 --reporter expanded test/integration/ >"$tmp" 2>&1
  fi
}
if run_tests; then
  grep -E "^All [0-9]+ tests passed" "$tmp" || tail -1 "$tmp"
else
  cat "$tmp"
  exit 1
fi
END=$(date +%s)
echo "integration: $((END - START))s"
