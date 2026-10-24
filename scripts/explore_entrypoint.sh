#!/bin/bash
# Entrypoint of the ExploreLinux Dagger service (ci/main.go): bring up the
# virtual desktop, then hand over to scripts/explore_server.py, which launches
# the debug build of the app and exposes an HTTP API to drive it. See
# EXPLORATORY-TESTING.md.
set -euo pipefail

# shellcheck source=scripts/gui_session.sh
. "$(dirname "$0")/gui_session.sh"

# The app's own ports (localhost:1430/1025/8080/4190) are not plain forwards
# here: explore_server.py serves them through scripts/fault_proxy.py, so
# POST /net can break the app's network. These forwards are the tester's
# bypass, straight to Stalwart and exposed by ci/main.go, so seeding and
# inspecting the mailbox keep working while the app is offline.
for pair in 11430:1430 11025:1025 18080:8080; do
    socat "TCP-LISTEN:${pair%%:*},fork,reuseaddr" "TCP:${STALWART_IMAP_HOST}:${pair#*:}" &
done
gui_session_start_desktop

# explore_server.py starts the fault proxy, the keyring (and restarts it on a
# wipe) and the app.
exec python3 "$(dirname "$0")/explore_server.py"
