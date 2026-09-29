#!/bin/bash
# Bring up a virtual desktop with accessibility enabled, launch the
# mise-installed release, and run scripts/gui_release_test.py against it.
#
# Run inside the container built by GuiTestRelease in ci/main.go. Every piece
# here exists for a reason that cost time to discover:
#
#   * gsettings screen-reader-enabled — Flutter builds no semantics tree at all
#     without it, so the app appears on the a11y bus with nothing inside it.
#   * one shared session bus — the app and the test must be on the SAME bus, or
#     the test sees an empty desktop.
#   * socat to localhost — the app permits plaintext IMAP/SMTP only for
#     localhost (isLocalhost in lib/core/utils/host_utils.dart), and the dev
#     Stalwart has no usable certificate.
set -euo pipefail

export DISPLAY=:99
export LIBGL_ALWAYS_SOFTWARE=1
export GTK_MODULES=gail:atk-bridge
export NO_AT_BRIDGE=0
export XDG_RUNTIME_DIR=/tmp/xdg
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
mkdir -p "${GUI_SHOT_DIR:-/shots}"

if [ -n "${STALWART_IMAP_HOST:-}" ]; then
    socat TCP-LISTEN:1430,fork,reuseaddr "TCP:${STALWART_IMAP_HOST}:${STALWART_IMAP_PORT:-1430}" &
    socat TCP-LISTEN:1025,fork,reuseaddr "TCP:${STALWART_SMTP_HOST}:${STALWART_SMTP_PORT:-1025}" &
    sleep 2
    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/localhost/1430" 2>/dev/null; then
        echo "Stalwart reachable on localhost:1430"
        export STALWART_READY=1
    else
        echo "WARNING: Stalwart is not reachable; the IMAP test will be skipped"
    fi
fi

Xvfb :99 -screen 0 1280x900x24 -ac >/tmp/xvfb.log 2>&1 &
sleep 3

dbus-daemon --session --address=unix:path=/tmp/session_bus --nofork &
sleep 2
export DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/session_bus

# Without this Flutter never enables semantics and the tree stays empty.
gsettings set org.gnome.desktop.a11y.applications screen-reader-enabled true
gsettings set org.gnome.desktop.interface toolkit-accessibility true 2>/dev/null || true

/usr/libexec/at-spi-bus-launcher --launch-immediately >/tmp/atspi.log 2>&1 &
sleep 3

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
python3 "$(dirname "$0")/gui_release_test.py"
