#!/usr/bin/env bash
# Starts Stalwart on random ports, then runs Flutter UI integration tests on a
# connected Android emulator.  The emulator reaches the host via 10.0.2.2.
#
# Run inside nix develop with an emulator already booted:
#   stalwart-dev/integration_android_test.sh
set -Eeuo pipefail

_SCRIPT_START=$(date +%s%3N)
ts() { echo "[$(( $(date +%s%3N) - _SCRIPT_START ))ms] $*"; }

export STALWART_USER_B="${STALWART_USER_B:-alice@example.com}"
export STALWART_PASS_B="${STALWART_PASS_B:-secret}"
export STALWART_USER_C="${STALWART_USER_C:-bob@example.com}"
export STALWART_PASS_C="${STALWART_PASS_C:-secret}"
export STALWART_RANDOM_PORTS=1
STALWART_TMPDIR="$(mktemp -d /tmp/stalwart-dev-XXXXXX)"
export STALWART_TMPDIR

cleanup() {
    kill "${STALWART_PID:-}" 2>/dev/null || true
    wait "${STALWART_PID:-}" 2>/dev/null || true
}
trap cleanup EXIT

command -v stalwart >/dev/null || {
    echo "stalwart not in PATH — run inside nix develop"
    exit 1
}

# Resolve adb: prefer PATH, fall back to ANDROID_HOME.
ADB=$(command -v adb 2>/dev/null || echo "${ANDROID_HOME:-$HOME/Android/Sdk}/platform-tools/adb")
"$ADB" version >/dev/null 2>&1 || {
    echo "adb not found — set ANDROID_HOME or add platform-tools to PATH"
    exit 1
}

# Detect a connected Android emulator.
EMULATOR_ID=$("$ADB" devices | awk '/^emulator-[0-9]+[[:space:]]+device$/ {print $1; exit}')
if [ -z "$EMULATOR_ID" ]; then
    echo "No Android emulator found. Boot one first, e.g.:"
    echo "  \${ANDROID_HOME:-\$HOME/Android/Sdk}/emulator/emulator -avd <avd-name> -no-window -no-audio &"
    exit 1
fi
ts "using emulator: $EMULATOR_ID"

# Pre-seed spam-filter version so Stalwart does not fetch it on first boot.
mkdir -p "$STALWART_TMPDIR"
sqlite3 "${STALWART_TMPDIR}/data.sqlite" \
    "CREATE TABLE IF NOT EXISTS s (k BLOB PRIMARY KEY, v BLOB NOT NULL);
     INSERT OR REPLACE INTO s VALUES ('version.spam-filter', 'dev');" 2>/dev/null || true

LOGFILE="${STALWART_TMPDIR}/stalwart.log"
rm -f "$LOGFILE"

ts "stalwart start"
"$(dirname "$0")/start" >"$LOGFILE" 2>&1 &
STALWART_PID=$!

# Wait until Stalwart is accepting connections (up to 10 s).
for _i in $(seq 1 20); do
    # shellcheck source=/dev/null
    [ -f "${STALWART_TMPDIR}/ports.env" ] && . "${STALWART_TMPDIR}/ports.env"
    grep -E "Configuration build error|Build error for key|already in use" "$LOGFILE" >/dev/null 2>&1 && {
        cat "$LOGFILE"; echo "Stalwart reported a startup error"; exit 1
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

ts "stalwart ready — IMAP=:${STALWART_IMAP_PORT:-?}  SMTP=:${STALWART_SMTP_PORT:-?}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Android emulator reaches the host machine via 10.0.2.2, not 127.0.0.1.
export STALWART_IMAP_HOST="10.0.2.2"
export STALWART_SMTP_HOST="10.0.2.2"

ts "flutter test start"
fvm flutter test integration_test/ -d "$EMULATOR_ID"
ts "flutter test done"
