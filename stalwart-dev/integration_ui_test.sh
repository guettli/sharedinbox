#!/usr/bin/env bash
# Starts Stalwart on random ports, then runs Flutter UI integration tests inside
# a virtual X server (Xvfb).  Works on a local desktop and in headless CI.
# No D-Bus or keyring daemon is required — tests inject an in-memory SecureStorage.
#
# Run inside nix develop: stalwart-dev/integration_ui_test.sh
set -Eeuo pipefail

# Timing helper: prints elapsed seconds since script start with a label.
_SCRIPT_START=$(date +%s%3N)
ts() { echo "[$(( $(date +%s%3N) - _SCRIPT_START ))ms] $*"; }

export STALWART_USER_B="${STALWART_USER_B:-alice@example.com}"
export STALWART_PASS_B="${STALWART_PASS_B:-secret}"
export STALWART_USER_C="${STALWART_USER_C:-bob@example.com}"
export STALWART_PASS_C="${STALWART_PASS_C:-secret}"
export STALWART_RANDOM_PORTS=1
STALWART_TMPDIR="$(mktemp -d /tmp/stalwart-dev-XXXXXX)"
export STALWART_TMPDIR

# Isolate path_provider app data from the developer's real data directory.
TEST_HOME="$(mktemp -d /tmp/sharedinbox-test-home-XXXXXX)"

cleanup() {
    kill "${STALWART_PID:-}" "${XVFB_PID:-}" 2>/dev/null || true
    wait "${STALWART_PID:-}" "${XVFB_PID:-}" 2>/dev/null || true
    rm -rf "$TEST_HOME"
}
trap cleanup EXIT

command -v stalwart >/dev/null || {
    echo "stalwart not in PATH."
    echo "Run inside the nix dev shell:"
    echo "  nix develop --command stalwart-dev/integration_ui_test.sh"
    exit 1
}
command -v xvfb-run >/dev/null || {
    echo "xvfb-run not in PATH."
    echo "Run inside the nix dev shell:"
    echo "  nix develop --command stalwart-dev/integration_ui_test.sh"
    exit 1
}

# Reap orphan Xvfb processes from previous sessions that were killed mid-flight.
# Without this, xvfb-run's wrapper may pick a fresh display via --auto-servernum
# but the leftover Xvfb's stale /tmp/.X11-unix/X<N> socket and lock file confuse
# its cleanup, producing "kill: No such process" on exit and a non-zero status
# even when the test itself passed.
for _xvfb_pid in $(pgrep -u "$USER" -x Xvfb 2>/dev/null); do
    _xvfb_display=$(tr '\0' ' ' < "/proc/${_xvfb_pid}/cmdline" 2>/dev/null \
        | grep -oE ':[0-9]+' | head -1)
    kill "$_xvfb_pid" 2>/dev/null || true
    [ -n "$_xvfb_display" ] && {
        rm -f "/tmp/.X11-unix/X${_xvfb_display#:}" "/tmp/.X${_xvfb_display#:}-lock" 2>/dev/null || true
    }
done

ts "script start"

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

export STALWART_IMAP_HOST="127.0.0.1"
export STALWART_SMTP_HOST="127.0.0.1"
# Isolate app data (path_provider uses XDG_DATA_HOME on Linux) without
# overriding HOME — keeping the real HOME lets FVM reuse its cached SDK.
export XDG_DATA_HOME="$TEST_HOME"

ts "flutter test start"

# Kill any orphan sharedinbox/flutter processes left by previous CI runs.
# Stale processes can hold onto the Xvfb display, causing the new Flutter app
# to hang indefinitely during GTK initialisation without ever connecting back
# to the flutter test runner.
pkill -u "$USER" -f "sharedinbox" 2>/dev/null || true
pkill -u "$USER" -f "flutter.*integration" 2>/dev/null || true
sleep 1

# Find an unused display number.
_display=99
while [ -e "/tmp/.X${_display}-lock" ]; do _display=$((_display + 1)); done

# Manage Xvfb directly instead of via xvfb-run.  xvfb-run catches SIGTERM,
# kills its children, and exits 0 — so `timeout 240 xvfb-run ...` exits 0 on
# timeout, making a stuck/timed-out test indistinguishable from a pass.
# Running Xvfb ourselves lets us capture fvm flutter test's real exit code.
# +iglx: indirect GLX so Flutter/GTK3 gets an OpenGL context via mesa software
# renderer (LIBGL_ALWAYS_SOFTWARE=1 is set in flake.nix).
Xvfb ":${_display}" -screen 0 1280x720x24 +iglx &
XVFB_PID=$!
export DISPLAY=":${_display}"

# Wait for the Xvfb Unix socket to appear (up to 5 s).
for _xi in $(seq 1 10); do
    [ -S "/tmp/.X11-unix/X${_display}" ] && break
    sleep 0.5
done
[ -S "/tmp/.X11-unix/X${_display}" ] || { echo "Xvfb :${_display} did not start"; exit 1; }

# Retry once: if the first attempt gets stuck in GTK/display init,
# a fresh Xvfb on a new display number usually succeeds on the second try.
_e2e_exit=0
for _attempt in 1 2; do
    ts "E2E attempt $_attempt (DISPLAY=$DISPLAY)"
    timeout 240 fvm flutter test integration_test/ -d linux
    _e2e_exit=$?
    [ $_e2e_exit -eq 0 ] && break
    if [ $_attempt -lt 2 ]; then
        ts "E2E attempt $_attempt failed (exit $_e2e_exit), restarting Xvfb and retrying..."
        pkill -u "$USER" -f "sharedinbox" 2>/dev/null || true
        # Kill the old Xvfb and start a fresh one on a new display number.
        kill "${XVFB_PID:-}" 2>/dev/null || true
        wait "${XVFB_PID:-}" 2>/dev/null || true
        rm -f "/tmp/.X${_display}-lock" "/tmp/.X11-unix/X${_display}" 2>/dev/null || true
        _display=$((_display + 1))
        while [ -e "/tmp/.X${_display}-lock" ]; do _display=$((_display + 1)); done
        Xvfb ":${_display}" -screen 0 1280x720x24 +iglx &
        XVFB_PID=$!
        export DISPLAY=":${_display}"
        for _xi in $(seq 1 10); do
            [ -S "/tmp/.X11-unix/X${_display}" ] && break
            sleep 0.5
        done
        sleep 2
    fi
done
[ $_e2e_exit -eq 0 ] || exit $_e2e_exit

ts "flutter test done"
