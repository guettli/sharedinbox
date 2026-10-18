# Sourced by gui_test_entrypoint.sh (release GUI test) and
# explore_entrypoint.sh (interactive exploratory testing): bring up a virtual
# desktop the app can render to and an accessibility bus scripts/gui_driver.py
# can read. Not executable on its own.
#
# Every piece here exists for a reason that cost time to discover:
#
#   * gsettings screen-reader-enabled — Flutter builds no semantics tree at all
#     without it, so the app appears on the a11y bus with nothing inside it.
#   * one shared session bus — the app and the driver must be on the SAME bus,
#     or the driver sees an empty desktop.
#   * socat to localhost — the app permits plaintext IMAP/SMTP only for
#     localhost (isLocalhost in lib/core/utils/host_utils.dart), and the dev
#     Stalwart has no usable certificate. The forwards listen on every
#     interface, so a Dagger service built on this can expose them too.

export DISPLAY=:99
export LIBGL_ALWAYS_SOFTWARE=1
export GTK_MODULES=gail:atk-bridge
export NO_AT_BRIDGE=0
export XDG_RUNTIME_DIR=/tmp/xdg
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"

# Forward local ports to the Stalwart service binding. Sets STALWART_READY=1
# once IMAP answers on localhost. Extra "local:remote" pairs (e.g. JMAP) may
# be passed as arguments. All protocols are served by one Stalwart, so the
# extra pairs and a missing SMTP host fall back to the IMAP host.
gui_session_forward_stalwart() {
    [ -n "${STALWART_IMAP_HOST:-}" ] || return 0
    local host="$STALWART_IMAP_HOST"
    socat TCP-LISTEN:1430,fork,reuseaddr "TCP:${host}:${STALWART_IMAP_PORT:-1430}" &
    socat TCP-LISTEN:1025,fork,reuseaddr "TCP:${STALWART_SMTP_HOST:-$host}:${STALWART_SMTP_PORT:-1025}" &
    local pair
    for pair in "$@"; do
        socat "TCP-LISTEN:${pair%%:*},fork,reuseaddr" "TCP:${host}:${pair#*:}" &
    done
    sleep 2
    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/localhost/1430" 2>/dev/null; then
        echo "Stalwart reachable on localhost:1430"
        export STALWART_READY=1
        return 0
    fi
    echo "WARNING: Stalwart is not reachable on localhost:1430"
}

# Xvfb, a session bus, accessibility switched on, and the AT-SPI bus.
gui_session_start_desktop() {
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
}
