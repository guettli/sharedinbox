#!/bin/bash
# Bring up a virtual desktop with accessibility enabled, launch the
# mise-installed release, and run scripts/gui_release_test.py against it.
#
# Run inside the container built by GuiTestRelease in ci/main.go. The desktop
# and accessibility setup is shared with exploratory testing and documented in
# scripts/gui_session.sh.
# -E: the ERR trap must also fire inside the gui_session.sh functions.
set -Eeuo pipefail

# Exit-code contract, so the caller can tell "this release is broken" from
# "we could not test it". Only the first should ever withdraw a release.
#
#   0   every assertion passed
#   1   an assertion failed, or the app died on launch — a release defect
#   75  the harness never got far enough to assert anything (EX_TEMPFAIL):
#       apt, the mise download, Xvfb, dbus or the a11y bus failed. That is an
#       environment problem; gating a release on it would withdraw good
#       builds whenever the engine has a bad day.
EX_TEMPFAIL=75
PHASE=setup
on_err() {
    rc=$?
    if [ "$PHASE" = setup ]; then
        echo "ERROR: GUI harness setup failed (rc=$rc) before any assertion ran —"
        echo "       reporting this as a harness problem, not a release defect."
        exit "$EX_TEMPFAIL"
    fi
    exit "$rc"
}
trap on_err ERR

# shellcheck source=scripts/gui_session.sh
. "$(dirname "$0")/gui_session.sh"
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
mkdir -p "${GUI_SHOT_DIR:-/shots}"

gui_session_forward_stalwart
[ -n "${STALWART_READY:-}" ] || echo "         (the IMAP test will be skipped)"
gui_session_start_desktop

sharedinbox >/tmp/app.log 2>&1 &
APP_PID=$!

# Wait for the app to publish a populated accessibility tree rather than
# sleeping a fixed amount: startup time varies with the engine's cache state.
for _ in $(seq 1 40); do
    if python3 -c "
import sys
sys.path.insert(0, '$(dirname "$0")')
import gui_driver
sys.exit(0 if gui_driver.find_containing('Welcome to sharedinbox.de') else 1)
" 2>/dev/null; then
        break
    fi
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        echo "ERROR: the app exited during startup"
        cat /tmp/app.log
        exit 1
    fi
    sleep 1
done

echo "--- app log ---"
tail -5 /tmp/app.log || true
echo "--- running GUI tests ---"
# Everything from here is a verdict about the release itself, so failures
# propagate unchanged rather than being softened to EX_TEMPFAIL.
PHASE=test
python3 "$(dirname "$0")/gui_release_test.py"
