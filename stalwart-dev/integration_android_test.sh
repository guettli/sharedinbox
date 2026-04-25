#!/usr/bin/env bash
# Starts Stalwart on random ports, then runs Flutter UI integration tests on a
# connected Android emulator.  Boots the sharedinbox_test AVD automatically if
# no emulator is already running.  Uses adb reverse to forward the fixed default
# ports (IMAP 1430, SMTP 1025) on the emulator to the actual random host ports.
#
# Run inside nix develop:
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
    "${ADB:-adb}" -s "${EMULATOR_ID:-}" reverse --remove-all 2>/dev/null || true
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

# Detect a connected Android emulator; auto-start the sharedinbox_test AVD if none is running.
EMULATOR_ID=$("$ADB" devices | awk '/^emulator-[0-9]+[[:space:]]+device$/ {print $1; exit}')
if [ -z "$EMULATOR_ID" ]; then
    EMULATOR_BIN="${ANDROID_HOME:-$HOME/Android/Sdk}/emulator/emulator"
    ts "no emulator running — booting AVD sharedinbox_test"
    "$EMULATOR_BIN" -avd sharedinbox_test -no-window -no-audio -no-snapshot-save > /tmp/emulator.log 2>&1 &
    EMULATOR_BOOT_PID=$!
    # Extend cleanup to also kill the emulator we started.
    cleanup() {
        "${ADB:-adb}" -s "${EMULATOR_ID:-}" reverse --remove-all 2>/dev/null || true
        kill "${STALWART_PID:-}" 2>/dev/null || true
        wait "${STALWART_PID:-}" 2>/dev/null || true
        kill "${EMULATOR_BOOT_PID:-}" 2>/dev/null || true
    }
    trap cleanup EXIT
    # Wait up to 120 s for the emulator to appear as a fully booted device.
    for _i in $(seq 1 60); do
        EMULATOR_ID=$("$ADB" devices | awk '/^emulator-[0-9]+[[:space:]]+device$/ {print $1; exit}')
        [ -n "$EMULATOR_ID" ] && break
        sleep 2
    done
    [ -n "$EMULATOR_ID" ] || { echo "Emulator did not become ready within 120 s"; exit 1; }
    # Wait for the Android system to finish booting (sys.boot_completed=1).
    "$ADB" -s "$EMULATOR_ID" wait-for-device
    for _i in $(seq 1 30); do
        BOOT_DONE=$("$ADB" -s "$EMULATOR_ID" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
        [ "$BOOT_DONE" = "1" ] && break
        sleep 2
    done
    [ "${BOOT_DONE:-0}" = "1" ] || { echo "Android boot did not complete within 60 s"; exit 1; }
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

ts "stalwart ready — IMAP=:${STALWART_IMAP_PORT:-?}  SMTP=:${STALWART_SMTP_PORT:-?}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Platform.environment is empty inside the Android app process, so env vars set
# by this script never reach the test code.  Instead, use adb reverse to forward
# the fixed "template" ports that the test defaults to (1430 IMAP, 1025 SMTP)
# on the emulator through to the actual random Stalwart ports on the host.
"$ADB" -s "$EMULATOR_ID" reverse tcp:1430 tcp:"$STALWART_IMAP_PORT"
"$ADB" -s "$EMULATOR_ID" reverse tcp:1025 tcp:"$STALWART_SMTP_PORT"

ts "flutter test start"
fvm flutter test integration_test/ -d "$EMULATOR_ID" | grep -Ev "was tree-shaken|Tree-shaking can be disabled"
ts "flutter test done"
